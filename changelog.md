## v1.0 (1)

First release.

- Runs from post-fs-data.d (before modules are mounted), so splash-screen loops are caught
- Disables only the newest changed module, then all changed, then all
- Reboots splash/boot hangs and zygote loops by itself
- Action button: status + re-enable

Flash in Magisk / KernelSU / APatch, reboot once.

