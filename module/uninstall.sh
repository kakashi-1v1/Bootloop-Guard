#!/system/bin/sh
pkill -f "bootloop-guard.sh watch" 2>/dev/null
rm -f /data/adb/post-fs-data.d/00-bootloop-guard.sh
rm -rf /data/adb/bootloop_guard
