# ThinkPad T14 Gen 1 Fan Curve

> A small fan daemon for the ThinkPad T14 Gen 1 (Intel / AMD).  
> It fixes the Linux-specific problem where the EC fan starts far too late and the CPU is already at 90°C+.  
> AMD sensors are supported (`k10temp`), but the level mapping and thresholds are untested; verify them yourself.

> [!WARNING]
> **Do not trust forks.** Use only the code in this repository (`S3608362/thinkpad-t14-gen1-fan-curve`). Forks can be modified to include malicious code; review the script line by line before installing. This project has no `curl | bash` installer.

## The problem

- The EC controls the fan from its own sensor, which lags the core temperature by 6–10 seconds during load transients.
- Linux exposes no Fan cooling device; on Intel models, `thermald` refuses to run because of `dytc_lapmode`.
- Result: under an 8-thread load, the fan stays at 0 RPM until the package reaches 93–97°C.

The script reads `coretemp` plus the dGPU sensor and writes fan levels to `/proc/acpi/ibm/fan`, filling that control gap.

## Results

| Metric | Stock EC | This script |
|---|---|---|
| Spin-up temperature | 93–97°C | ~48°C |
| Peak | 97°C | 90°C |
| Steady state under load | 80–85°C | 78–79°C |

Measured on a T14 Gen 1 with an 8-thread synthetic load; for reference only.

## Control logic

- Control temperature = `max(CPU package, dGPU)`; the iGPU shares the CPU die and is already covered by the package sensor.
- Small fluctuations: fast-attack/slow-decay EMA (50% on rise, 25% on fall), so 1–2°C jitter does not change the level.
- Large steps: a 2 s rise of ≥10°C or a 4 s rise of ≥15°C upshifts immediately from the raw temperature.
- Downshifts: require 5 consecutive samples (10 s) below the hysteresis threshold, one level at a time.
- Protection: `watchdog 10`, systemd restart, 90°C fail-safe, and `level auto` on exit.
- After suspend/resume the filter is reset and the watchdog is re-armed.

> Reading note: during `auto` spin-down the tach passes through ~2300 RPM; that is a transient, not level 1. Some tools briefly report 65535 RPM when the fan starts — a tach overflow, ignore it.

## Compared to thinkfan

- **Writes EC levels directly**: uses `/proc/acpi/ibm/fan` level 1–7; thinkfan commonly goes through hwmon PWM 0–255, and on ThinkPads you still have to verify that the EC accepts PWM.
- **Better for temperature spikes**: fast-attack/slow-decay EMA plus a 2 s / 4 s large-step fast path; thinkfan uses static bands.
- **Zero dependencies**: one bash script and one systemd unit; no package or YAML.
- **Explicit safety**: watchdog, 90°C fail-safe, and `auto` on exit are all in the script and easy to audit.
- **Automatic sensor discovery**: finds `coretemp` / `k10temp` / the `GPU` label.

## Run check-compat.sh first

**On any ThinkPad, run this before installing the service:**

```bash
sudo ./check-compat.sh
```

It checks:

- model / BIOS / `fan_control`;
- whether `/proc/acpi/ibm/fan` exists;
- CPU/GPU sensor labels;
- whether writing `level 1` and `level 5` actually changes the RPM.

If `level 5` is clearly higher than `level 1`, manual levels work and you can continue. Otherwise, do not use this. The script restores `level auto` automatically.

### If manual levels do not work

If `level 1` and `level 5` produce the same RPM, the EC ignores manual levels — **do not install this script**. That does not mean the fan is uncontrollable. Try, in order:

1. **Platform performance profile** (coarse, three modes only, no temperature curve)
   ```bash
   cat /sys/firmware/acpi/platform_profile_choices
   echo performance | sudo tee /sys/firmware/acpi/platform_profile
   ```
   Switching to `performance` forces the EC to re-evaluate its fan policy and often starts the fan earlier when hot. This only works if `/sys/firmware/acpi/platform_profile` exists.
2. **Full-speed level** (emergency only, model-dependent, very loud): `echo "level full-speed" | sudo tee /proc/acpi/ibm/fan`. The daemon never uses this level.
3. If neither helps, note that `thinkfan` also goes through `/proc/acpi/ibm/fan` on ThinkPads and will not help when levels are ignored; consider `nbfc-linux` or a model-specific EC tool.

## Installation

### 1. Enable fan_control

```bash
echo 'options thinkpad_acpi fan_control=1' | sudo tee /etc/modprobe.d/thinkpad_acpi.conf
sudo update-initramfs -u
sudo reboot
```

### 2. Measure the levels

```bash
sudo ./measure-levels.sh
```

The level-to-RPM mapping is completely different across models/BIOS/EC. If your values differ a lot from the default curve, edit `ON` / `OFF` at the top of the script.

### 3. Install the service

```bash
sudo install -m 755 thinkfan-lite.sh /usr/local/sbin/thinkfan-lite.sh
sudo install -m 644 thinkfan-lite.service /etc/systemd/system/thinkfan-lite.service
sudo systemctl daemon-reload
sudo systemctl enable --now thinkfan-lite.service
systemctl status thinkfan-lite.service --no-pager
journalctl -t thinkfan-lite -f
```

## Other ThinkPads

| Model | Status |
|---|---|
| T14 Gen 1 (Intel) | Tested |
| P14s Gen 1 (Intel/AMD) | Same platform, expected to work; run `check-compat.sh` first |
| T14s Gen 1 / X13 Gen 1 | Expected to work; thinner chassis may need tuning |
| T14 Gen 2 / P14s Gen 2 | Untested; newer EC may ignore manual levels |
| T490 / T495 / P43s | Untested; level mapping differs |
| AMD | `k10temp` sensor support is included; levels still need verification |

**Do not copy the T14 Gen 1 RPM/threshold values to another model.** Run `check-compat.sh`, then `measure-levels.sh`.

## Notes

- **The dGPU 57°C cap is not a cooling problem**: on some models (e.g. the MX330 in
  the T14 Gen 1) the firmware sets `GPU Target Temperature` to 57°C; the GPU drops to
  139 MHz as soon as it reaches that, and no fan speed will help. Check it with
  `nvidia-smi -q -d TEMPERATURE`; lifting it requires the ACPI `_Q6D` call and is out
  of scope for this script. If your dGPU sits at 57°C under load, verify this before
  blaming the cooling. Note: once unlocked, the EC may keep the setting persistently;
  no reliable rollback method has been verified.
- **Slow despite low temperatures**: it may be the EC lap mode (`dytc_lapmode=1`). The optional `extras/lapmode-notify/` component sends a desktop notification on state changes.
- Do not use `level 0`, `disengaged`, or `full-speed`; the script never does.
- Manual mode bypasses the EC auto curve. The script has watchdog/fail-safe, but read it before installing.
- After a BIOS/EC update, re-run `measure-levels.sh`; kernel/NVIDIA driver updates normally do not matter.

## Rollback

```bash
sudo systemctl disable --now thinkfan-lite.service
echo 'level auto' | sudo tee /proc/acpi/ibm/fan
```

Full revert to EC automatic control:

```bash
sudo rm /etc/modprobe.d/thinkpad_acpi.conf
sudo update-initramfs -u
sudo reboot
```

## Files

- `thinkfan-lite.sh` — the daemon.
- `thinkfan-lite.service` — systemd unit.
- `measure-levels.sh` — measure level-to-RPM.
- `check-compat.sh` — compatibility check.
- `NOTICE` — GPL-2.0-or-later notice.
- `README.md` — Chinese version.

## License

GPL-2.0-or-later. See `LICENSE` and `NOTICE`.
