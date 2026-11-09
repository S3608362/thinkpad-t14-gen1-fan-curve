# ThinkPad T14 Gen 1 风扇曲线

> 一个给 ThinkPad T14 Gen 1（Intel）用的轻量风扇守护脚本。  
> 解决 Linux 下 EC 风扇起转太晚、CPU 已经 90°C+ 风扇还不转的问题。

> [!WARNING]
> **不要轻信 fork 仓库。** 只以本仓库（`S3608362/thinkpad-t14-gen1-fan-curve`）的代码为准。fork 可能被修改并加入恶意代码；如果你从 fork 安装，请先逐行审查脚本。本项目没有 `curl | bash` 安装方式。

## 问题

- EC 用自身传感器控制风扇，负载突变时比核心温度慢 6–10 秒；
- Linux 没有 Fan cooling device，`thermald` 又因 `dytc_lapmode` 拒绝运行；
- 结果：8 线程满载时风扇 0 RPM 撑到 93–97°C 才起转。

脚本直接读 `coretemp` + 独显传感器，按温度写 `/proc/acpi/ibm/fan`，把这段控制补回来。

## 实测效果

| 指标 | 原厂 EC | 本脚本 |
|---|---|---|
| 起转温度 | 93–97°C | ~48°C |
| 峰值 | 97°C | 90°C |
| 满载稳态 | 80–85°C | 78–79°C |

数据来自 T14 Gen 1 的 8 线程合成负载，仅作参考。

## 控制逻辑

- 控制温度 = `max(CPU 封装, 独显)`；核显与 CPU 同 die，已被 CPU 封装覆盖。
- 小波动：EMA 快升慢降（升温 50%，降温 25%），不因 1–2°C 抖动换档。
- 大跃变：2 秒升温 ≥10°C 或 4 秒 ≥15°C，立即按原始温度升档。
- 降档：连续 5 个周期（10 秒）低于回差，每次只降一级。
- 保护：`watchdog 10`、systemd 自动重启、90°C fail-safe、退出恢复 `auto`。
- suspend/resume 后重置滤波，并重新 arm watchdog。

> 读数提示：`auto` 降速会经过 ~2300 RPM，这是过渡值不是 level 1；风扇启动瞬间可能读到 65535 RPM，是 tach 溢出，忽略即可。

## 对比 thinkfan

- **直接写 EC 档位**：用 `/proc/acpi/ibm/fan` 的 level 1–7；thinkfan 常见路径是 hwmon PWM 0–255，ThinkPad 上还要确认 EC 是否接受 PWM。
- **更适合温度跃变**：EMA 快升慢降 + 2 秒/4 秒大跃变快速升档；thinkfan 是静态分段曲线。
- **零依赖**：一个 bash 脚本 + 一个 systemd 单元，不需要装包或 YAML。
- **保护写死**：watchdog、90°C fail-safe、退出恢复 `auto` 都在脚本里，方便审计。
- **自动找传感器**：`coretemp` / `k10temp` / `GPU` 标签自动识别。

## 先跑 check-compat.sh

**任何 ThinkPad 在安装服务之前，先跑：**

```bash
sudo ./check-compat.sh
```

它会检查：

- 机型 / BIOS / `fan_control`；
- `/proc/acpi/ibm/fan` 是否存在；
- CPU/GPU 传感器标签；
- 写入 `level 1` 和 `level 5` 后转速是否真的变化。

如果 `level 5` 明显高于 `level 1`，说明这台机器支持手动档位，可以继续；否则不要用。脚本会自动恢复 `level auto`。

### 手动档位无效时

`level 1` 和 `level 5` 没有区别，说明 EC 忽略手动档位，**不要安装本脚本**。这不等于无解，可以按顺序尝试：

1. **平台性能模式**（粗调，只有三档，没有温度曲线）
   ```bash
   cat /sys/firmware/acpi/platform_profile_choices
   echo performance | sudo tee /sys/firmware/acpi/platform_profile
   ```
   切到 `performance` 会强制 EC 重新计算风扇策略，高温时往往能让风扇提前启动。只有存在 `/sys/firmware/acpi/platform_profile` 时才有用。
2. **全速档**（仅应急，部分机型支持，噪声很大）：`echo "level full-speed" | sudo tee /proc/acpi/ibm/fan`。脚本本身不会使用这一档。
3. 仍不行时：`thinkfan` 在 ThinkPad 上也走 `/proc/acpi/ibm/fan`，档位无效时帮不上；可考虑 `nbfc-linux` 或对应机型的 EC 专用工具。

## 安装

### 1. 打开 fan_control

```bash
echo 'options thinkpad_acpi fan_control=1' | sudo tee /etc/modprobe.d/thinkpad_acpi.conf
sudo update-initramfs -u
sudo reboot
```

### 2. 实测档位

```bash
sudo ./measure-levels.sh
```

不同机型/BIOS/EC 的 level→RPM 完全不同。如果实测值和默认曲线差很多，改脚本顶部的 `ON` / `OFF`。

### 3. 安装服务

```bash
sudo install -m 755 thinkfan-lite.sh /usr/local/sbin/thinkfan-lite.sh
sudo install -m 644 thinkfan-lite.service /etc/systemd/system/thinkfan-lite.service
sudo systemctl daemon-reload
sudo systemctl enable --now thinkfan-lite.service
systemctl status thinkfan-lite.service --no-pager
journalctl -t thinkfan-lite -f
```

## 其他机型

| 机型 | 状态 |
|---|---|
| T14 Gen 1 (Intel) | 已实测 |
| P14s Gen 1 (Intel/AMD) | 同平台，预计可用；先跑 `check-compat.sh` |
| T14s Gen 1 / X13 Gen 1 | 预计可用；机身更薄，阈值可能要调 |
| T14 Gen 2 / P14s Gen 2 | 未验证；新 EC 可能忽略手动档位 |
| T490 / T495 / P43s | 未验证；档位映射不同 |
| AMD | 传感器已支持 `k10temp`；仍需验证档位 |

**不要直接套用 T14 Gen 1 的 RPM/阈值。** 先 `check-compat.sh`，再 `measure-levels.sh`。

## 注意

- 不要用 `level 0`、`disengaged`、`full-speed`；脚本本身也不会用。
- 手动模式会绕过 EC 自动曲线；脚本已有 watchdog/fail-safe，但仍建议先读一遍脚本。
- BIOS/EC 升级后重跑 `measure-levels.sh`；内核/NVIDIA 驱动升级通常不影响。

## 回滚

```bash
sudo systemctl disable --now thinkfan-lite.service
echo 'level auto' | sudo tee /proc/acpi/ibm/fan
```

彻底恢复 EC 自动控制：

```bash
sudo rm /etc/modprobe.d/thinkpad_acpi.conf
sudo update-initramfs -u
sudo reboot
```

## 文件

- `thinkfan-lite.sh`：守护脚本
- `thinkfan-lite.service`：systemd 单元
- `measure-levels.sh`：实测 level→RPM
- `check-compat.sh`：兼容性检查
- `NOTICE`：GPL-2.0-or-later 声明
- `README.en.md`：英文版

## License

GPL-2.0-or-later. See `LICENSE` and `NOTICE`.
