# ThinkPad T14 Gen 1 风扇响应迟滞：诊断与手动风扇曲线

> **English TL;DR** — On a ThinkPad T14 Gen 1 (Intel), the EC fan curve is driven by a slow sensor and stays at 0 RPM until the CPU package reaches ~95°C. Linux exposes no Fan cooling device, and `thermald` refuses to run on this platform (`dytc_lapmode`). This repo contains a small systemd daemon that drives `/proc/acpi/ibm/fan` from `coretemp`, with hysteresis, a 10s watchdog and a 90°C fail-safe. **Tested on T14 Gen 1 only.** Manual fan control bypasses the EC curve — read the warnings before use.

> [!WARNING]
> **不要轻信 fork 仓库。** 只以本仓库（`S3608362/thinkpad-t14-gen1-fan-curve`）的代码为准。fork 可能被修改并加入恶意代码；如果你从 fork 安装，请先逐行审查脚本，不要直接 `sudo` 运行。本项目没有 `curl | bash` 安装方式。

> English version: [README.en.md](README.en.md)

## 症状

- 轻负载升温后，风扇长时间保持 0 RPM；
- 8 线程满载时，封装温度在 28–37 秒内从约 50°C 冲到 93–97°C，风扇才开始转；
- 起转后风扇能到约 4600–5000 RPM，说明风扇/散热器本身没有失效；
- `thermald` 启动后立即退出，日志提示 `dytc_lapmode present: Thermald can't run on this platform`。

## 诊断数据（改造前）

| 项目 | 结果 |
|---|---|
| 冷启动满载到风扇起转 | 28–37 秒 |
| 起转时封装温度 | 93–97°C |
| 峰值封装温度 | 97°C |
| 满载后段 CPU 频率 | 3.4GHz → 2.6–2.8GHz |
| `package_throttle_count` | 1054 |

风扇起转后能到 4600 RPM 并把 97°C 压到 82°C，所以问题不在风扇本体，而在“什么时候开始转”。

## 根因

1. **EC 传感器滞后**：EC 用自身传感器控制风扇，负载突变时比核心温度慢 6–10 秒。实测满载第 7 秒核心已 80°C，EC 传感器只有 48°C。
2. **起转阈值偏高**：冷启动要等 EC 传感器到较高温度才从 0 起转，此时核心已经 93–97°C。
3. **Linux 无法直接控制风扇**：`thermal_zone` 的 cooling device 里没有 Fan，只有 Processor/powerclamp；`thinkpad_acpi` 默认 `fan_control=N`、`pwm1_enable=2`。
4. **`thermald` 不可用**：该平台检测到 `dytc_lapmode`，`thermald` 直接退出，无法用它兜底。
5. **高 PL 放大热冲击**：本机 PL1/PL2 上限为 51W，满载 2 秒内核心可上升 38°C，进一步放大传感器滞后。

## 方案

打开 `thinkpad_acpi` 的手动风扇控制，用一个小的 systemd 守护脚本按 **CPU 封装与独显温度中的较大值** 写 `/proc/acpi/ibm/fan` 的档位。

### 双显卡怎么算

- **核显**：与 CPU 同 die，`coretemp/temp1_input` 已经覆盖；
- **独显**：使用 EC 的 `thinkpad/temp2_input`（实测与 `nvidia-smi` 读数完全一致）；
- 脚本取两者最大值，所以无论 CPU 先热还是独显先热，风扇都会按更热的那个升档；
- 没有独显或独显关闭时，`temp2` 读数为 0/无效，脚本自动忽略，只用 CPU。

轻量 `glxgears` 独显负载下，这张低功耗独显只到 49°C，未触发升档；但传感器读数与 `nvidia-smi` 同步，重负载时脚本会接住。

### 实测档位（仅 T14 Gen 1，其他机型请先自测）

| level | 实测转速 |
|---|---|
| 1 | ~2868–2900 RPM |
| 2 | ~3293 RPM |
| 3 | ~3405 RPM |
| 4 | ~3512 RPM |
| 5 | ~4518 RPM |
| 6 | ~4987 RPM |
| 7 | ~4970 RPM |

2/3/4 的转速几乎一样，6/7 已经饱和，所以脚本只使用 **1 / 2 / 5 / 6 / 7** 五档。

> 读数说明：`auto` 降速时转速会经过 ~2300 RPM，这是过渡值，不是 level 1；部分工具在风扇启动瞬间会读到 65535 RPM，这是 tach 溢出，可忽略。level 1 稳态约 2868–2900 RPM。

### 控制曲线

| coretemp 封装温度 | 档位 |
|---|---|
| < 48°C | auto |
| 48–55°C | level 1 |
| 56–67°C | level 2 |
| 68–79°C | level 5 |
| 80–87°C | level 6 |
| ≥ 88°C | level 7（90°C fail-safe） |

- 小波动：EMA 快升慢降（升温 50%，降温 25%，2 秒采样），避免 1–2°C 抖动触发换档；
- 大跃变：2 秒升温 ≥10°C 或 4 秒 ≥15°C 时，绕过平均、按原始温度立即升档；
- 降档：连续 5 个周期（10 秒）低于回差阈值才执行，而且每次只降一级；
- 回差：level 1 为 4°C，其余档位 6°C。

### 改造后对比

| 指标 | 改造前 | 改造后 |
|---|---|---|
| 风扇起转温度 | 93–97°C | ~48°C（渐进升温）；大跃变 2 秒内升档 |
| 起转延迟 | 28–37 秒 | 2 秒采样；大跃变 2 秒内响应，风扇物理爬升约 8–12 秒 |
| 峰值封装温度 | 97°C | 90°C |
| 满载稳态 | 80–85°C | 78–79°C @ level 5（约 4550 RPM） |

## 文件

- `README.md`：中文版；
- `README.en.md`：英文版；
- `thinkfan-lite.sh`：守护脚本；
- `thinkfan-lite.service`：systemd 单元；
- `measure-levels.sh`：实测 level 1–7 对应转速。

## 安装

### 1. 打开 fan_control

```bash
echo 'options thinkpad_acpi fan_control=1' | sudo tee /etc/modprobe.d/thinkpad_acpi.conf
sudo update-initramfs -u
sudo reboot
```

重启后确认：

```bash
cat /sys/module/thinkpad_acpi/parameters/fan_control   # 应为 Y
cat /proc/acpi/ibm/fan
```

### 2. 实测档位

```bash
sudo ./measure-levels.sh
```

如果某些 level 写入后转速不变，说明该机型/EC 只接受部分档位，按实际结果修改 `thinkfan-lite.sh` 里的 `ON` / `OFF` 表。

### 3. 安装服务

```bash
sudo install -m 755 thinkfan-lite.sh /usr/local/sbin/thinkfan-lite.sh
sudo install -m 644 thinkfan-lite.service /etc/systemd/system/thinkfan-lite.service
sudo systemctl daemon-reload
sudo systemctl enable --now thinkfan-lite.service
systemctl status thinkfan-lite.service --no-pager
journalctl -t thinkfan-lite -f
```

## 安全说明

手动模式会绕过 EC 的自动风扇曲线。脚本包含以下保护：

- `watchdog 10`：脚本卡死/被 `kill -9` 后 10 秒内 EC 接管；
- systemd `Restart=always`：进程崩溃后 2 秒重启；
- `trap ... EXIT INT TERM`：正常退出 / `Ctrl+C` 时写回 `level auto`；
- 传感器读取失败：立即写回 `level auto`；
- 温度 ≥ 90°C：强制 level 7；
- 不使用 `level 0`（停转）、`disengaged`、`full-speed`。

安装前建议先验证 watchdog：

```bash
sudo sh -c "echo 'watchdog 10' > /proc/acpi/ibm/fan"
sudo sh -c "echo 'level 1' > /proc/acpi/ibm/fan"
sleep 15
cat /proc/acpi/ibm/fan    # level 应不再是 1，而是回到 auto 或安全档
sudo sh -c "echo 'level auto' > /proc/acpi/ibm/fan"
sudo sh -c "echo 'watchdog 0' > /proc/acpi/ibm/fan"
```

如果 `level` 写入后转速完全不变，说明该机型 EC 忽略手动档位，请停止使用。

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

## 系统/驱动升级后

- **内核升级**：`/etc/modprobe.d/thinkpad_acpi.conf` 和 systemd 服务会保留。重启后确认 `fan_control=Y`，再看 `journalctl -t thinkfan-lite` 里的传感器路径。
- **BIOS/EC 升级**：档位到转速的映射可能改变。重新运行 `sudo ./measure-levels.sh`；如果 RPM 表变化，按新表调整 `ON` / `OFF`。
- **NVIDIA 驱动升级**：脚本读 EC 的 `thinkpad/temp2_input`，不依赖 `nvidia-smi`，一般不受影响；确认该传感器仍然存在即可。
- **传感器改名/换位置**：脚本按 hwmon 名称（`coretemp`、`thinkpad`）和标签（`Package id 0`、`GPU`）查找；启动日志会打印实际路径。
- **出问题时**：`echo 'level auto' | sudo tee /proc/acpi/ibm/fan`，然后查看 `journalctl -t thinkfan-lite`。

## 其他 ThinkPad 能用吗？

**控制框架可以复用，但参数和传感器假设不能照搬。**

可复用的部分：

- `thinkpad_acpi` 的 `fan_control=1` 和 `/proc/acpi/ibm/fan` 接口；
- 按温度切档、watchdog、systemd 守护；
- hwmon 按名称查找（`coretemp` / `thinkpad`）。

必须逐机验证的部分：

- **level 到转速的映射**：不同机型/BIOS/EC 完全不同，先跑 `measure-levels.sh`；
- **EC 是否接受手动档位**：有些机型写入 level 后转速不变，那就不能用；
- **CPU 传感器**：Intel 是 `coretemp` 的 `Package id 0`；AMD 是 `k10temp`，脚本已支持（优先 `Tdie`，其次 `Tctl`；`Tctl` 可能带 offset）；
- **GPU 传感器**：`thinkpad/temp2_input` 的 `GPU` 标签只在带独显的机型上存在；没有独显或标签不同，脚本会退回 CPU；
- **风扇数量**：双风扇机型（P 系列、X1 Extreme 等）可能需要同时处理 `fan1` / `fan2`；
- **温度阈值**：48/56/68/80/88 只是这台 T14 Gen 1 的起点，换机型要重新跑负载测试。

使用前至少做：

1. `cat /sys/module/thinkpad_acpi/parameters/fan_control` → 必须是 `Y`；
2. `cat /proc/acpi/ibm/fan` → 要有 `level` / `watchdog` 命令；
3. `sudo ./measure-levels.sh` → level 1–7 转速必须真的变化；
4. 检查 `temp*_label`，确认 CPU/GPU 传感器对得上；
5. 先小负载测试，再决定是否长期使用。

## 已验证范围

仅 **ThinkPad T14 Gen 1（Intel 平台）**。不同 BIOS/EC 版本的档位映射可能不同；换机型或升级固件后请先运行 `measure-levels.sh`，不要直接套用阈值。

## License

MIT
