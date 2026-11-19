#!/system/bin/sh
MODDIR=${0%/*}
G=$MODDIR/bootloop-guard.sh
sh "$G" status
ST=/data/adb/bootloop_guard
if [ ! -s "$ST/disabled.list" ] && [ ! -s "$ST/scripts.list" ]; then
  echo; echo "Nothing to re-enable."; exit 0
fi
echo
echo "Vol+  re-enable everything Bootloop Guard disabled"
echo "Vol-  do nothing"
echo "(10 s)"
k=$(timeout 10 getevent -ql 2>/dev/null | grep -m1 -E 'KEY_VOLUME(UP|DOWN) +DOWN')
case "$k" in
  *KEY_VOLUMEUP*) echo; sh "$G" restore; echo "Done. Reboot to load them." ;;
  *) echo; echo "Nothing changed." ;;
esac
