# Bootloop Guard

Magisk / KernelSU / APatch module that gets you out of a bootloop caused by a module, **including loops that never get past the splash logo**, and disables **only the module that caused it**.

Most bootloop protectors wait for zygote or the boot animation, so a device stuck on the splash screen never reaches them. Bootloop Guard runs from `/data/adb/post-fs-data.d/00-bootloop-guard.sh`: the root manager runs that folder while the splash logo is still on screen, **before** it loads module sepolicy rules or mounts any module. A module disabled there is already gone on the same boot, with no extra reboot.

## How it works

**Last good boot.** When a boot finishes and the framework stays up for 60 s, the guard saves the list of enabled modules with a fingerprint of each one: versionCode plus the sizes and modified times of `module.prop`, its boot scripts, `sepolicy.rule`, `system.prop`, `system/`, `vendor/`, `product/`, `system_ext/`, `odm/` and `zygisk/`.

A module counts as **changed** if it is new, updated, edited in place (even with the same versionCode), re-enabled, or a pending update.

**Bootloop.** Every boot start counts as a try. After 3 boots in a row that never finished, the next boot steps up:

| Step | Action |
|---|---|
| 1 | Disable the **newest** changed module |
| 2 | Still looping: disable every changed module |
| 3 | Still looping: disable every module and make the general scripts (`post-fs-data.d`, `service.d`, ...) non-executable |
| 4 | Still looping: give up. The cause isn't a module, so it stops rebooting |

If nothing changed since the last good boot, it goes straight to step 3.

**Hangs.** A watcher starts in the early stage and exits once the boot is good. It reboots the device and steps up on the next boot, without waiting for 3 tries, when:

- it's stuck on the splash screen (no boot animation / system_server) for 180 s
- boot hasn't completed after 600 s
- zygote restarts 4 times before boot completes, or 3 times right after it

So a splash hang doesn't need any force reboots from you. It costs one timeout plus one automatic reboot.

After a rescue you get a notification listing what was disabled. The module description shows the last rescue.

## Usage

Flash the zip in Magisk / KernelSU / APatch and reboot once. On install, the modules you have enabled right now are saved as the last good state. Modules flashed in the same session are still checked on the first boot.

**Action button:** shows status and the log. Vol+ re-enables everything the guard disabled.

Shell commands (as root): `sh /data/adb/modules/bootloop_guard/bootloop-guard.sh <command>`

| Command | |
|---|---|
| `status` | count, step, disabled modules, log |
| `restore` | re-enable everything the guard disabled |
| `reset` | save the current modules as the last good state, clear the counter |

## Settings

`/data/adb/bootloop_guard/config.sh`, read on every boot:

| Key | Default | |
|---|---|---|
| `THRESHOLD` | 3 | boots in a row that never finished before it acts |
| `SPLASH_TIMEOUT` | 180 | seconds on the splash screen before reboot |
| `BOOT_TIMEOUT` | 600 | seconds without boot completed before reboot |
| `STABLE_SECS` | 60 | framework must stay up this long to count as a good boot |
| `ZYGOTE_LOOPS` | 4 | zygote restarts before boot completed = loop |
| `WATCHDOG` | 1 | 0 = never reboot a hung boot, only count it |
| `NOTIFY` | 1 | notification after a rescue |
| `WHITELIST` | "" | module ids never disabled |

Log: `/data/adb/bootloop_guard/log.txt`

## Limits

- Nothing from a module can run before post-fs-data. Kernel panics, a broken boot/vbmeta image, and (on Magisk) a bad `sepolicy.rule`, which magiskinit loads in the first stage, can't be caught. Use the root manager's safe mode for those: KernelSU press Vol- 3 times during boot, Magisk hold Vol-.
- If several modules changed and the newest one isn't the culprit, step 2 also disables the innocent ones. Re-enable them by hand.
- A first boot after an OTA that takes longer than `BOOT_TIMEOUT` would be rebooted. Raise it or set `WATCHDOG=0` before updating if your device is slow.
