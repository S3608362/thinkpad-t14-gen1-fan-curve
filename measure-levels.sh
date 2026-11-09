#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 S3608362
# measure-levels.sh — 实测 ThinkPad 风扇 level 1–7 对应转速
set -u

FAN=/proc/acpi/ibm/fan

[ "$(id -u)" -eq 0 ] || { echo "请用 sudo 运行" >&2; exit 1; }
[ -e "$FAN" ] || { echo "$FAN 不存在：thinkpad_acpi 未加载？" >&2; exit 1; }

find_hwmon() {
  local d
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue
    [ "$(cat "$d/name")" = "$1" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

CORE=$(find_hwmon coretemp) || CORE=$(find_hwmon k10temp) || { echo "找不到 coretemp/k10temp hwmon" >&2; exit 1; }
TP=$(find_hwmon thinkpad) || { echo "找不到 thinkpad hwmon" >&2; exit 1; }
TEMP="$CORE/temp1_input"
RPM="$TP/fan1_input"

cleanup() { printf 'level auto\n' > "$FAN" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

# 先回自动，避免继承上一次的手动档位
printf 'watchdog 30\n' > "$FAN" 2>/dev/null || true
printf 'level auto\n' > "$FAN" 2>/dev/null || true

for l in 1 2 3 4 5 6 7; do
  if ! printf 'level %s\n' "$l" > "$FAN" 2>/dev/null; then
    echo "写入 level $l 失败；请确认 fan_control=1" >&2
    break
  fi
  sleep 10
  t=$(( $(cat "$TEMP" 2>/dev/null || echo 0) / 1000 ))
  r=$(cat "$RPM" 2>/dev/null || echo '?')
  printf 'level %s: %s°C  %s RPM\n' "$l" "$t" "$r"
done

printf 'level auto\n' > "$FAN" 2>/dev/null || true
