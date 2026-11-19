#!/system/bin/sh
# Bootloop Guard
#
# A copy of this file lives in /data/adb/post-fs-data.d/00-bootloop-guard.sh (00- = runs before any other general script). Magisk, KernelSU and APatch run that
# folder at post-fs-data, while the splash logo is still on screen and BEFORE they load module
# sepolicy rules or mount any module. So a module disabled here is already gone on this boot.
#
# Every boot start counts as a try. A boot that reaches boot_completed and stays up
# (zygote unchanged for STABLE_SECS) resets the count and saves the module list as "last good".
# After THRESHOLD tries in a row that never finished, the next boot steps up:
#   step 1: disable the newest changed module (new / updated / edited / re-enabled since last good boot)
#   step 2: disable every changed module
#   step 3: disable every module + chmod -x the general scripts (post-fs-data.d, service.d, ...)
#   step 4: give up (not a module problem), stop rebooting
# No change since the last good boot -> straight to step 3.
# A watcher reboots a boot that hangs (splash / boot animation) or whose zygote keeps restarting,
# and marks it so the next boot steps up at once.
#
# Commands: (none) = early boot stage | watch | status | restore | baseline | reset

ADB=${BLG_ADB:-/data/adb}
MODS=$ADB/modules
UPD=$ADB/modules_update
SELF=bootloop_guard
ST=$ADB/bootloop_guard
LOG=$ST/log.txt
GEN=$ADB/post-fs-data.d/00-bootloop-guard.sh

THRESHOLD=3        # boots in a row that never finished before acting
SPLASH_TIMEOUT=180 # seconds without boot animation / system_server = stuck on splash
BOOT_TIMEOUT=600   # seconds without boot_completed
STABLE_SECS=60     # zygote must stay the same this long after boot_completed
ZYGOTE_LOOPS=4     # zygote restarts before boot_completed = loop
WATCHDOG=1         # 0 = never reboot a hung boot, only count
NOTIFY=1
WHITELIST=""       # module ids never disabled, space separated
[ -f "$ST/config.sh" ] && . "$ST/config.sh"

BB=""
for b in "$BLG_BB" /data/adb/magisk/busybox /data/adb/ksu/bin/busybox /data/adb/ap/bin/busybox; do
  [ -n "$b" ] && [ -x "$b" ] && { BB=$b; break; }
done

now() { date +%s; }
log() { echo "$(date '+%m-%d %H:%M:%S') $*" >> "$LOG"; }
trim_log() {
  [ "$(wc -l < "$LOG" 2>/dev/null || echo 0)" -gt 500 ] && { tail -n 300 "$LOG" > "$LOG.t" && mv -f "$LOG.t" "$LOG"; }
}
num() { v=$(cat "$1" 2>/dev/null); case "$v" in ''|*[!0-9]*) echo "${2:-0}" ;; *) echo "$v" ;; esac; }
wr() { echo "$2" > "$1.t" && mv -f "$1.t" "$1"; }
flush() { [ -n "$BLG_TEST" ] || sync; }
in_list() { case " $2 " in *" $1 "*) return 0 ;; esac; return 1; }

# ------------------------------------------------------------------ module list

# the dir that will load this boot (a pending update replaces the installed one)
eff_dir() { if [ -z "$NO_UPD" ] && [ -f "$UPD/$1/module.prop" ]; then echo "$UPD/$1"; else echo "$MODS/$1"; fi; }

loads() {
  d=$(eff_dir "$1")
  [ -f "$d/module.prop" ] || return 1
  [ -e "$MODS/$1/disable" ] || [ -e "$d/disable" ] || [ -e "$MODS/$1/remove" ] || [ -e "$d/remove" ] && return 1
  return 0
}

all_ids() {
  { ls "$MODS" 2>/dev/null; [ -z "$NO_UPD" ] && ls "$UPD" 2>/dev/null; } | sort -u
}

# fingerprint the parts that can affect boot: "hash maxctime"
# hash = names + sizes + mtimes, ctime only orders changes (it is set at extract/edit time)
fp() {
  out=$(cd "$1" 2>/dev/null || exit 0
    set --
    for f in module.prop post-fs-data.sh post-mount.sh service.sh boot-completed.sh sepolicy.rule system.prop \
             skip_mount system vendor product system_ext odm zygisk; do
      [ -e "$f" ] && set -- "$@" "$f"
    done
    [ $# -gt 0 ] && $BB find "$@" \( -type f -o -type l \) -exec $BB stat -c '%s %Y %Z %n' {} + 2>/dev/null | $BB sort)
  h=$(printf '%s\n' "$out" | $BB awk '{$3=""; print}' | $BB md5sum | cut -c1-12)
  c=$(printf '%s\n' "$out" | $BB awk 'BEGIN{m=0} $3+0>m{m=$3+0} END{print m}')
  echo "$h $c"
}

# id|versionCode|hash|maxctime  for every module that loads this boot (not us)
snapshot() {
  for id in $(all_ids); do
    [ "$id" = "$SELF" ] && continue
    loads "$id" || continue
    d=$(eff_dir "$id")
    vc=$(sed -n 's/^versionCode=//p' "$d/module.prop" | head -n1 | tr -d '\r |')
    set -- $(fp "$d")
    echo "$id|$vc|$1|$2"
  done
}

# id|hash|first_seen|ctime : remember when each version was first seen (orders the suspects)
update_seen() {
  t=$(now)
  touch "$ST/seen.list"
  while IFS='|' read -r id vc h c; do
    grep -q "^$id|$h|" "$ST/seen.list" || echo "$id|$h|$t|$c" >> "$ST/seen.list"
  done < "$ST/cur.list"
}

# changed vs last good boot, newest first
suspects() {
  [ -f "$ST/good.list" ] || : > "$ST/good.list"
  $BB awk -F'|' 'NR==FNR{g[$1"|"$3]=1; next} !(($1"|"$3) in g){print $1"|"$3}' "$ST/good.list" "$ST/cur.list" |
  while IFS='|' read -r id h; do
    in_list "$id" "$WHITELIST" && continue
    line=$(grep "^$id|$h|" "$ST/seen.list" | head -n1)
    echo "${line:-$id|$h|0|0}"
  done | sort -t'|' -k3,3nr -k4,4nr | cut -d'|' -f1
}

disable_mod() {
  for base in "$MODS" "$UPD"; do [ -d "$base/$1" ] && touch "$base/$1/disable"; done
  grep -qx "$1" "$ST/disabled.list" 2>/dev/null || echo "$1" >> "$ST/disabled.list"
  echo "$1" >> "$ST/round.list"
  log "disabled module $1 ($2)"
}

disable_all() {
  log "disabling every module: $1"
  while IFS='|' read -r id rest; do
    in_list "$id" "$WHITELIST" || disable_mod "$id" "$1"
  done < "$ST/cur.list"
  for dir in post-fs-data.d post-mount.d service.d boot-completed.d; do
    for f in "$ADB/$dir"/*; do
      [ -f "$f" ] && [ -x "$f" ] || continue
      [ "$f" = "$GEN" ] && continue
      chmod 0644 "$f" && echo "$f" >> "$ST/scripts.list" && log "disabled script $f"
    done
  done
}

act() {
  lvl=$(num "$ST/level")
  sus=$(suspects)
  log "bootloop detected, step $((lvl + 1)), changed since last good boot: $(echo $sus)"
  case $lvl in
    0) if [ -n "$sus" ]; then
         disable_mod "$(echo "$sus" | head -n1)" "newest change since last good boot"; lvl=1
       else
         disable_all "nothing changed since last good boot"; lvl=3
       fi ;;
    1) if [ -n "$sus" ]; then
         for id in $sus; do disable_mod "$id" "changed since last good boot"; done; lvl=2
       else
         disable_all "still looping"; lvl=3
       fi ;;
    2) disable_all "still looping with every change disabled"; lvl=3 ;;
    *) log "still looping with every module disabled: not a module problem, giving up"
       echo 1 > "$ST/gave_up"; lvl=4 ;;
  esac
  wr "$ST/level" "$lvl"
}

# ------------------------------------------------------------------ early stage

early() {
  if [ ! -d "$MODS/$SELF" ] && [ ! -d "$UPD/$SELF" ]; then rm -f "$GEN"; exit 0; fi
  if [ -e "$MODS/$SELF/remove" ]; then rm -f "$GEN"; rm -rf "$ST"; exit 0; fi
  [ -e "$MODS/$SELF/disable" ] && exit 0
  mkdir -p "$ST"
  cnt=$(num "$ST/count")
  snapshot > "$ST/cur.list"
  update_seen
  log "boot start, unfinished boots before this one: $cnt, step $(num "$ST/level")"
  if [ "$cnt" -ge "$THRESHOLD" ] && [ "$(num "$ST/level")" -lt 4 ]; then
    act
    snapshot > "$ST/cur.list"   # what really loads now
    cnt=0
  fi
  wr "$ST/count" $((cnt + 1))
  flush
  [ -n "$BLG_TEST" ] && return 0
  if command -v setsid >/dev/null 2>&1 || [ -n "$BB" ]; then
    ${BB:+$BB }setsid sh "$0" watch < /dev/null > /dev/null 2>&1 &
  else
    nohup sh "$0" watch < /dev/null > /dev/null 2>&1 &
  fi
}

# ------------------------------------------------------------------ watcher

zpid() { { pidof zygote64 || pidof zygote; } 2>/dev/null | awk '{print $1}'; }

hard_fail() {
  log "FAIL: $1"
  [ "$(num "$ST/count")" -lt "$THRESHOLD" ] && wr "$ST/count" "$THRESHOLD"   # next boot steps up at once
  flush
  if [ "$WATCHDOG" = 1 ] && [ "$(num "$ST/level")" -lt 4 ]; then
    log "rebooting"
    setprop sys.powerctl reboot,bootloop_guard 2>/dev/null || reboot
  fi
  exit 0
}

notify() {
  [ "$NOTIFY" = 1 ] || return 0
  cmd notification post -S bigtext -t "Bootloop Guard" bootloop_guard "$1" > /dev/null 2>&1
}

set_desc() {
  p=$MODS/$SELF/module.prop
  [ -f "$p" ] || return 0
  { grep -v '^description=' "$p"
    echo "description=Stops bootloops (splash screen included) by disabling only the module that caused them. $1"
  } > "$p.t" && mv -f "$p.t" "$p"
}

success() {
  wr "$ST/count" 0
  cp -f "$ST/cur.list" "$ST/good.list"
  # forget versions that are gone
  cut -d'|' -f1,3 "$ST/cur.list" > "$ST/keep.t"
  grep -F -f "$ST/keep.t" "$ST/seen.list" > "$ST/seen.t" 2>/dev/null; mv -f "$ST/seen.t" "$ST/seen.list"; rm -f "$ST/keep.t"
  lvl=$(num "$ST/level")
  if [ -s "$ST/round.list" ]; then
    mods=$(sort -u "$ST/round.list" | tr '\n' ' ')
    n=$(( $(num "$ST/rescues") + 1 )); wr "$ST/rescues" $n
    wr "$ST/last" "$(date '+%Y-%m-%d %H:%M') disabled: $mods"
    notify "Bootloop stopped. Disabled: $mods
Re-enable in your root manager, or use the module's Action button to re-enable all of them."
    log "boot ok after rescue, disabled: $mods"
    rm -f "$ST/round.list"
  else
    log "boot ok"
  fi
  [ "$lvl" -ge 4 ] && notify "Bootloop Guard gave up: the device kept looping with every module disabled, so the cause is not a module."
  rm -f "$ST/gave_up"
  wr "$ST/level" 0
  last=$(cat "$ST/last" 2>/dev/null)
  set_desc "Last boot OK. Rescues: $(num "$ST/rescues")${last:+ | last: $last}"
  flush
  trim_log
}

watch() {
  start=$(now); z=$(zpid); zc=0; progress=0
  while [ "$(getprop sys.boot_completed)" != 1 ]; do
    sleep 2
    t=$(( $(now) - start ))
    p=$(zpid)
    if [ -n "$p" ]; then
      [ -n "$z" ] && [ "$p" != "$z" ] && { zc=$((zc + 1)); log "zygote restarted ($zc) at ${t}s"; }
      z=$p
    fi
    [ "$progress" = 0 ] && { [ "$(getprop init.svc.bootanim)" = running ] || pidof system_server > /dev/null 2>&1; } && {
      progress=1; log "past splash at ${t}s"; }
    [ "$zc" -ge "$ZYGOTE_LOOPS" ] && hard_fail "zygote restarted $zc times before boot completed"
    [ "$progress" = 0 ] && [ "$t" -ge "$SPLASH_TIMEOUT" ] && hard_fail "stuck on splash for ${t}s"
    [ "$t" -ge "$BOOT_TIMEOUT" ] && hard_fail "boot not completed after ${t}s"
  done
  log "boot_completed at $(( $(now) - start ))s"
  # stay up for STABLE_SECS with the same zygote
  since=$(now); rc=0; z=$(zpid)
  while [ $(( $(now) - since )) -lt "$STABLE_SECS" ]; do
    sleep 3
    p=$(zpid)
    if [ -z "$p" ] || [ "$p" != "$z" ]; then
      rc=$((rc + 1)); z=$p; since=$(now)
      log "framework restarted after boot ($rc)"
      [ "$rc" -ge 3 ] && hard_fail "framework keeps restarting after boot"
    fi
  done
  success
}

# ------------------------------------------------------------------ manual

status() {
  echo "Bootloop Guard"
  echo "  unfinished boots in a row: $(num "$ST/count") (acts at $THRESHOLD)"
  echo "  step: $(num "$ST/level")   rescues: $(num "$ST/rescues")"
  [ -f "$ST/last" ] && echo "  last rescue: $(cat "$ST/last")"
  [ -s "$ST/disabled.list" ] && echo "  disabled by guard: $(tr '\n' ' ' < "$ST/disabled.list")"
  [ -s "$ST/scripts.list" ] && echo "  scripts made non-executable: $(wc -l < "$ST/scripts.list")"
  echo "  modules in last good boot: $(grep -c . "$ST/good.list" 2>/dev/null || echo 0)"
  echo
  echo "Log (last 15):"
  tail -n 15 "$LOG" 2>/dev/null | sed 's/^/  /'
}

restore() {
  if [ -s "$ST/disabled.list" ]; then
    while read -r id; do
      [ -n "$id" ] || continue
      rm -f "$MODS/$id/disable" "$UPD/$id/disable"
      echo "  re-enabled $id"; log "restore: re-enabled $id"
    done < "$ST/disabled.list"
  fi
  if [ -s "$ST/scripts.list" ]; then
    while read -r f; do [ -f "$f" ] && chmod 0755 "$f" && echo "  re-enabled $f" && log "restore: re-enabled $f"; done < "$ST/scripts.list"
  fi
  rm -f "$ST/disabled.list" "$ST/scripts.list" "$ST/round.list"
}

case "$1" in
  watch) watch ;;
  ok) success ;;   # mark this boot good by hand
  status) status ;;
  restore) restore ;;
  baseline) # at install: installed+enabled modules = good, pending installs/updates stay suspects
    mkdir -p "$ST"
    [ -s "$ST/good.list" ] || { NO_UPD=1; snapshot > "$ST/good.list"; cp -f "$ST/good.list" "$ST/cur.list"; update_seen; NO_UPD=; } ;;
  reset) mkdir -p "$ST"; snapshot > "$ST/cur.list"; cp -f "$ST/cur.list" "$ST/good.list"; update_seen
         wr "$ST/count" 0; wr "$ST/level" 0; rm -f "$ST/gave_up" ;;
  *) early ;;
esac
exit 0
