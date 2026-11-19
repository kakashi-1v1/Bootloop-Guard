# Bootloop Guard settings (/data/adb/bootloop_guard/config.sh). Read on every boot.
THRESHOLD=3        # boots in a row that never finished before it acts
SPLASH_TIMEOUT=180 # seconds stuck on splash (no boot animation / system_server) -> reboot
BOOT_TIMEOUT=600   # seconds without boot completed -> reboot
STABLE_SECS=60     # framework must stay up this long after boot to count as good
ZYGOTE_LOOPS=4     # zygote restarts before boot completed = bootloop
WATCHDOG=1         # 0 = never reboot a hung boot, only count it
NOTIFY=1           # notification after a rescue
WHITELIST=""       # module ids never disabled, e.g. "zygisksu lsposed"
