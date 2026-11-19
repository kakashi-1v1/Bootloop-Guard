#!/system/bin/sh
# keep the early-stage copy in post-fs-data.d up to date (used from the next boot)
MODDIR=${0%/*}
GEN=/data/adb/post-fs-data.d/00-bootloop-guard.sh
if ! cmp -s "$MODDIR/bootloop-guard.sh" "$GEN"; then
  mkdir -p /data/adb/post-fs-data.d
  cp -f "$MODDIR/bootloop-guard.sh" "$GEN" && chmod 0755 "$GEN"
fi
