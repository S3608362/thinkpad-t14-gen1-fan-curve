# lapmode-notify

ThinkPad lap mode 状态通知：状态变化时弹一条桌面通知，解释“为什么机器突然变慢”。

这是**纯观察**组件，不写 `dytc_lapmode`，不切性能模式，也不控制风扇。

## 它解决什么

部分 ThinkPad 的 EC 会在判定“膝上模式”时把 CPU 限制到 1GHz 以下，特征是：

```
温度不高 + 风扇很安静 + 系统莫名卡顿
```

不熟悉这个机制的人会误以为是 Linux 或驱动问题。这个脚本会在进入/退出膝上模式时提示。

## 设计

- 每 **30 秒**读一次 `/sys/devices/platform/thinkpad_acpi/dytc_lapmode`
- **只在 0↔1 变化时**发通知
- 使用同一个通知 ID（`notify-send -r`）替换，**不累计、不重叠**
- 单个休眠进程，CPU 占用几乎为零
- 状态文件避免服务重启后重复通知

## 安装

```bash
./install-lapmode-notify.sh
```

安装到：

```
~/.local/bin/lapmode-notify.sh
~/.config/systemd/user/lapmode-notify.service
```

## 查看状态

```bash
systemctl --user status lapmode-notify.service
journalctl --user -u lapmode-notify.service -b
```

## 卸载

```bash
./uninstall-lapmode-notify.sh
```

## 手动测试通知

```bash
notify-send -a "ThinkPad" "测试" "通知是否正常"
```

## 注意

- 只支持存在 `dytc_lapmode` 的机型（较新的 ThinkPad）。
- 通知是否显示、停留多久，由桌面环境的通知守护进程决定。
- 如果觉得 30 秒太频繁，可以改脚本里的 `INTERVAL`。
