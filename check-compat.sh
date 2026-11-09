#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 S3608362
# check-compat.sh — 快速检查这台 ThinkPad 是否支持手动风扇档位
set -u

FAN=/proc/acpi/ibm/fan

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行" >&2; exit 1; }

echo "Model: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo unknown)"
echo "BIOS:  $(cat /sys/class/dmi/id/bios_version 2>/dev/null || echo unknown)"
echo "fan_control: $(cat /sys/module/thinkpad_acpi/parameters/fan_control 2>/dev/null || echo missing)"
echo

if [ -e "$FAN" ]; then
  echo "=== /proc/acpi/ibm/fan ==="
  cat "$FAN"
else
  echo "$FAN 不存在：thinkpad_acpi 未加载？"
  exit 1
fi

find_hwmon() {
  local d
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue
    [ "$(cat "$d/name")" = "$1" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

CORE=$(find_hwmon coretemp) || CORE=$(find_hwmon k10temp) || true
TP=$(find_hwmon thinkpad) || true

if [ -n "$CORE" ]; then
  echo
  echo "=== CPU sensors ($(basename "$CORE")) ==="
  for t in "$CORE"/temp*_input; do
    [ -e "$t" ] || continue
    printf '%s  %-12s %s\n' "$t" "$(cat "${t%_input}_label" 2>/dev/null)" "$(cat "$t" 2>/dev/null)"
  done
fi

if [ -n "$TP" ]; then
  echo
  echo "=== ThinkPad sensors ($(basename "$TP")) ==="
  for t in "$TP"/temp*_input; do
    [ -e "$t" ] || continue
    printf '%s  %-12s %s\n' "$t" "$(cat "${t%_input}_label" 2>/dev/null)" "$(cat "$t" 2>/dev/null)"
  done
  echo
  echo "Fans:"
  for f in "$TP"/fan*_input; do
    [ -e "$f" ] || continue
    printf '%s  %s RPM\n' "$f" "$(cat "$f" 2>/dev/null)"
  done
fi

if [ -z "$TP" ] || [ ! -e "$TP/fan1_input" ]; then
  echo
  echo "找不到 thinkpad fan1_input，无法测试手动档位。"
  exit 1
fi

cleanup() { printf 'level auto\n' > "$FAN" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

echo
echo "=== 测试手动档位（会短暂改变风扇转速）==="
printf 'level auto\n' > "$FAN" 2>/dev/null || true
sleep 3
before=$(cat "$TP/fan1_input" 2>/dev/null || echo 0)

if ! printf 'level 1\n' > "$FAN" 2>/dev/null; then
  echo "写入 level 1 失败；请确认 fan_control=1"
  exit 1
fi
sleep 10
l1=$(cat "$TP/fan1_input" 2>/dev/null || echo 0)

if ! printf 'level 5\n' > "$FAN" 2>/dev/null; then
  echo "写入 level 5 失败"
  exit 1
fi
sleep 10
l5=$(cat "$TP/fan1_input" 2>/dev/null || echo 0)

printf 'level auto\n' > "$FAN" 2>/dev/null || true

echo "auto/前:  ${before} RPM"
echo "level 1:  ${l1} RPM"
echo "level 5:  ${l5} RPM"

if [ "$l5" -gt "$l1" ]; then
  echo
  echo "结果：手动档位有效。下一步运行 measure-levels.sh 建立 RPM 表。"
else
  echo
  echo "结果：level 1 和 level 5 没有明显差异；这台机器的 EC 可能忽略手动档位。"
  echo
  echo "不要安装本脚本。可以按顺序尝试以下替代方案："
  echo
  if [ -e /sys/firmware/acpi/platform_profile ]; then
    echo "1) 平台性能模式（粗调，只有三档，没有温度曲线）"
    echo "   可选：$(cat /sys/firmware/acpi/platform_profile_choices 2>/dev/null)"
    echo "   高温时切到 performance，强制 EC 重算风扇策略："
    echo "     echo performance | sudo tee /sys/firmware/acpi/platform_profile"
  else
    echo "1) 平台性能模式：本机没有 /sys/firmware/acpi/platform_profile，跳过。"
  fi
  echo
  echo "2) 全速档（仅应急，部分机型支持，噪声很大）："
  echo "     echo \"level full-speed\" | sudo tee $FAN"
  echo
  echo "3) 仍不行：thinkfan 在 ThinkPad 上也走 $FAN，档位无效时帮不上；"
  echo "   可考虑 nbfc-linux 或对应机型的 EC 专用工具。"
fi
