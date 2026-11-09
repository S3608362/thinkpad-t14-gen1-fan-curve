# ThinkPad T14 Gen 1 Fan Lag: Diagnosis and Manual Fan Curve

> [!WARNING]
> **Do not trust forks.** Use only the code in this repository (`S3608362/thinkpad-t14-gen1-fan-curve`). Forks can be modified to include malicious code. If you install from a fork, review the script line by line first; never `sudo` run code you have not inspected. This project has no `curl | bash` installer.

> **TL;DR** — On a ThinkPad T14 Gen 1 (Intel), the EC fan curve is driven by a slow sensor and stays at 0 RPM until the CPU package reaches ~95°C. Linux exposes no Fan cooling device, and `thermald` refuses to run on this platform (`dytc_lapmode`). This repo contains a small systemd daemon that drives `/proc/acpi/ibm/fan` from `coretemp`, with hysteresis, a 10s watchdog and a 90°C fail-safe. **Tested on T14 Gen 1 only.** Manual fan control bypasses the EC curve — read the warnings before use.

> 中文版: [README.md](README.md)

## Symptoms

- After a light load raises the temperature, the fan stays at 0 RPM for a long time.
- Under an 8-thread load, the package temperature climbs from ~50°C to 93–97°C in 28–37 seconds before the fan starts.
- Once spinning, the fan reaches ~4600–5000 RPM, so the fan and heatsink themselves are not broken.
- `thermald` exits immediately with `dytc_lapmode present: Thermald can't run on this platform`.

## Measurements (before)

| Item | Result |
|---|---|
| Cold-start full load to fan spin-up | 28–37 s |
| Package temperature at spin-up | 93–97°C |
| Peak package temperature | 97°C |
| CPU frequency late in the load | 3.4GHz → 2.6–2.8GHz |
| `package_throttle_count` | 1054 |

After spin-up the fan reaches 4600 RPM and brings 97°C down to 82°C, so the problem is not the fan itself but **when it starts**.

## Root cause

1. **EC sensor lag** — the EC controls the fan from its own sensor, which lags the core temperature by 6–10 seconds during load transients. At second 7 of the load, the package was already 80°C while the EC sensor read 48°C.
2. **High spin-up threshold** — on a cold start the EC waits for its sensor to reach a high temperature; by then the package is already 93–97°C.
3. **Linux cannot control the fan directly** — the thermal cooling-device list has no Fan, only Processor/powerclamp; `thinkpad_acpi` defaults to `fan_control=N` and `pwm1_enable=2`.
4. **`thermald` is unusable** — the platform exposes `dytc_lapmode`, so `thermald` exits immediately.
5. **High PL amplifies the transient** — this unit allows PL1/PL2 up to 51W; the package can rise 38°C in 2 seconds, making the sensor lag worse.

## Approach

Enable manual fan control in `thinkpad_acpi` and use a small systemd daemon to write fan levels to `/proc/acpi/ibm/fan` based on **the higher of the CPU package and dGPU temperatures**.

### Dual GPU handling

- **iGPU**: shares the CPU die, so `coretemp/temp1_input` already covers it.
- **dGPU**: uses the EC sensor at `thinkpad/temp2_input` (measured to match `nvidia-smi` exactly).
- The script uses `max(cpu, gpu)`, so the fan ramps for whichever is hotter.
- On machines without a dGPU, or when the dGPU is off, `temp2` reads 0/invalid and is ignored.

Under a light `glxgears` load this low-power dGPU only reached 49°C and did not trigger a ramp; the sensor still matched `nvidia-smi`, so a heavier load will be covered.

### Measured levels (T14 Gen 1 only; measure your own machine first)

| level | Measured RPM |
|---|---|
| 1 | ~2868–2900 RPM |
| 2 | ~3293 RPM |
| 3 | ~3405 RPM |
| 4 | ~3512 RPM |
| 5 | ~4518 RPM |
| 6 | ~4987 RPM |
| 7 | ~4970 RPM |

Levels 2/3/4 are nearly identical, and 6/7 are saturated, so the script only uses **1 / 2 / 5 / 6 / 7**.

> Reading note: during `auto` spin-down the tach passes through ~2300 RPM; that is a transient, not level 1. Some tools briefly report 65535 RPM when the fan starts — a tach overflow, ignore it. Level 1 steady state is ~2868–2900 RPM.

### Control curve

| coretemp package temperature | Level |
|---|---|
| < 48°C | auto |
| 48–55°C | level 1 |
| 56–67°C | level 2 |
| 68–79°C | level 5 |
| 80–87°C | level 6 |
| ≥ 88°C | level 7 (90°C fail-safe) |

- Small fluctuations: fast-attack/slow-decay EMA (50% on rise, 25% on fall, 2 s sampling) so 1–2°C jitter does not change the level.
- Large steps: a 2 s rise of ≥10°C or a 4 s rise of ≥15°C bypasses the average and upshifts immediately from the raw temperature.
- Downshifts: require 5 consecutive samples (10 s) below the hysteresis threshold, one level at a time.
- Hysteresis: 4°C for level 1, 6°C for the other levels.

### Before / after

| Metric | Before | After |
|---|---|---|
| Fan spin-up temperature | 93–97°C | ~48°C (gradual); fast ramp on large steps |
| Spin-up delay | 28–37 s | 2 s sampling; 2 s fast path; physical ramp 8–12 s |
| Peak package temperature | 97°C | 90°C |
| Steady state under load | 80–85°C | 78–79°C @ level 5 (~4550 RPM) |

## Files

- `README.md` — Chinese version.
- `README.en.md` — English version.
- `thinkfan-lite.sh` — the daemon.
- `thinkfan-lite.service` — systemd unit.
- `measure-levels.sh` — measure level 1–7 RPM.

## Installation

### 1. Enable fan_control

```bash
echo 'options thinkpad_acpi fan_control=1' | sudo tee /etc/modprobe.d/thinkpad_acpi.conf
sudo update-initramfs -u
sudo reboot
```

After reboot:

```bash
cat /sys/module/thinkpad_acpi/parameters/fan_control   # should be Y
cat /proc/acpi/ibm/fan
```

### 2. Measure levels

```bash
sudo ./measure-levels.sh
```

If some levels do not change the RPM, your model/EC only accepts a subset; adjust the `ON` / `OFF` tables in `thinkfan-lite.sh` accordingly.

### 3. Install the service

```bash
sudo install -m 755 thinkfan-lite.sh /usr/local/sbin/thinkfan-lite.sh
sudo install -m 644 thinkfan-lite.service /etc/systemd/system/thinkfan-lite.service
sudo systemctl daemon-reload
sudo systemctl enable --now thinkfan-lite.service
systemctl status thinkfan-lite.service --no-pager
journalctl -t thinkfan-lite -f
```

## Safety

Manual mode bypasses the EC's automatic fan curve. The script includes:

- `watchdog 10` — the EC takes over within 10 s if the script hangs or is `kill -9`ed.
- systemd `Restart=always` — restarts 2 s after a crash.
- `trap ... EXIT INT TERM` — writes `level auto` on normal exit / `Ctrl+C`.
- Sensor read failure — writes `level auto` immediately.
- Temperature ≥ 90°C — forces level 7.
- Never uses `level 0` (stop), `disengaged`, or `full-speed`.

Verify the watchdog before installing:

```bash
sudo sh -c "echo 'watchdog 10' > /proc/acpi/ibm/fan"
sudo sh -c "echo 'level 1' > /proc/acpi/ibm/fan"
sleep 15
cat /proc/acpi/ibm/fan    # level should no longer be 1; it should be auto or a safe level
sudo sh -c "echo 'level auto' > /proc/acpi/ibm/fan"
sudo sh -c "echo 'watchdog 0' > /proc/acpi/ibm/fan"
```

If `level` writes do not change the RPM at all, the EC on your model ignores manual levels — stop using this.

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

## After system or driver upgrades

- **Kernel upgrade**: `/etc/modprobe.d/thinkpad_acpi.conf` and the systemd unit persist. After reboot, verify `fan_control=Y` and check the sensor paths in `journalctl -t thinkfan-lite`.
- **BIOS/EC update**: the level-to-RPM mapping may change. Re-run `sudo ./measure-levels.sh`; if the RPM table changed, update `ON` / `OFF` accordingly.
- **NVIDIA driver update**: the script reads the EC `thinkpad/temp2_input`, not `nvidia-smi`, so driver updates normally do not affect it. Just confirm the sensor still exists.
- **Sensor rename/move**: the script finds hwmon devices by name (`coretemp`, `thinkpad`) and temperatures by label (`Package id 0`, `GPU`); the startup log prints the actual paths.
- **If something breaks**: `echo 'level auto' | sudo tee /proc/acpi/ibm/fan`, then check `journalctl -t thinkfan-lite`.

## Will it work on other ThinkPads?

**The control framework is reusable, but the parameters and sensor assumptions are not.**

Portable parts:

- `thinkpad_acpi` with `fan_control=1` and the `/proc/acpi/ibm/fan` interface;
- temperature-based level switching, watchdog, systemd service;
- hwmon lookup by name (`coretemp` / `thinkpad`).

Must be verified per machine:

- **level-to-RPM mapping**: completely different across models/BIOS/EC; run `measure-levels.sh` first;
- **whether the EC accepts manual levels**: on some models the RPM does not change at all;
- **CPU sensor**: Intel uses `coretemp` / `Package id 0`; AMD uses `k10temp` (supported; prefers `Tdie`, then `Tctl`; `Tctl` may include an offset);
- **GPU sensor**: the `GPU` label on `thinkpad/temp2_input` only exists on dGPU models; without it the script falls back to CPU;
- **number of fans**: dual-fan models (P series, X1 Extreme, etc.) may need `fan1` / `fan2` handling;
- **temperature thresholds**: 48/56/68/80/88 are only a starting point for this T14 Gen 1.

Minimum checks before use:

1. `cat /sys/module/thinkpad_acpi/parameters/fan_control` → must be `Y`;
2. `cat /proc/acpi/ibm/fan` → must expose `level` / `watchdog`;
3. `sudo ./measure-levels.sh` → level 1–7 must actually change the RPM;
4. inspect `temp*_label` and confirm the CPU/GPU sensors;
5. test under a small load before using it long-term.

## Tested on

**ThinkPad T14 Gen 1 (Intel) only.** Fan-level mapping may differ across BIOS/EC versions; after changing models or updating firmware, run `measure-levels.sh` first and do not copy the thresholds blindly.

## License

MIT
