SKIPUNZIP=0
ST=/data/adb/bootloop_guard
GEN=/data/adb/post-fs-data.d/00-bootloop-guard.sh
set_perm "$MODPATH/bootloop-guard.sh" 0 0 0755
set_perm "$MODPATH/post-fs-data.sh" 0 0 0755
set_perm "$MODPATH/action.sh" 0 0 0755
# the early stage runs from the general post-fs-data.d folder: before modules are mounted
mkdir -p /data/adb/post-fs-data.d "$ST"
cp -f "$MODPATH/bootloop-guard.sh" "$GEN"
set_perm "$GEN" 0 0 0755
[ -f "$ST/config.sh" ] || cp -f "$MODPATH/config.sh" "$ST/config.sh"
# modules installed and enabled right now = last good state (pending installs stay suspects)
sh "$MODPATH/bootloop-guard.sh" baseline
ui_print "- Bootloop Guard installed"
ui_print "  early stage: $GEN"
ui_print "  state, log, config: $ST"
ui_print "  Action button: status + re-enable what it disabled"
