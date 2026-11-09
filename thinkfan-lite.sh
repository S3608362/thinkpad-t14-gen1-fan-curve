#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-2.0-or-later
# Copyright (C) 2026 S3608362
# /usr/local/sbin/thinkfan-lite.sh
# ThinkPad 手动风扇曲线：EMA 平滑 + 大跃变快速响应 + 档位滞后 + watchdog + fail-safe
set -u

FAN=/proc/acpi/ibm/fan
INTERVAL=2
FAILSAFE=90
DOWN_CONFIRM=5
FAST_DELTA=10
FAST_DELTA_4S=15
EMA_UP_DIV=2
EMA_DOWN_DIV=4
RESUME_GAP=15
WATCHDOG_REARM=30

find_hwmon() {
  local d
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue
    [ "$(cat "$d/name")" = "$1" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

find_temp_by_label() {
  local dir=$1 label=$2 t l
  for t in "$dir"/temp*_input; do
    [ -e "$t" ] || continue
    l="${t%_input}_label"
    [ -r "$l" ] || continue
    [ "$(cat "$l")" = "$label" ] && { printf '%s\n' "$t"; return 0; }
  done
  return 1
}

CORE=$(find_hwmon coretemp) || CORE=$(find_hwmon k10temp) || {
  echo "CPU sensor (coretemp/k10temp) not found" >&2
  exit 1
}
TP=$(find_hwmon thinkpad) || { echo "thinkpad hwmon not found" >&2; exit 1; }

# Intel: Package id 0；AMD: 优先 Tdie，其次 Tctl；最后回退 temp1。
TEMP_CPU=$(find_temp_by_label "$CORE" "Package id 0") \
  || find_temp_by_label "$CORE" "Tdie" \
  || find_temp_by_label "$CORE" "Tctl" \
  || TEMP_CPU="$CORE/temp1_input"
TEMP_GPU=$(find_temp_by_label "$TP" "GPU") || TEMP_GPU=""

# 实测：1=2868, 2=3293, 3=3405, 4=3512, 5=4518, 6=4987, 7=4970 RPM
# 2/3/4 几乎一样，6/7 饱和，所以只用 1/2/5/6/7。
# ON = 进入档位温度；OFF = 退出档位温度。
# level 1 回差 4°C，其余档位回差 6°C。
declare -A ON=(  [1]=48 [2]=56 [5]=68 [6]=80 [7]=88 )
declare -A OFF=( [1]=44 [2]=50 [5]=62 [6]=74 [7]=82 )

current=auto
down_count=0
t=0
t_filt=0
t_prev=0
t_prev2=0
t_cpu=0
t_gpu_display='--'
first=1
last_time=$(date +%s)
rearm_count=0
log() { logger -t thinkfan-lite "$*"; }
log "sensors: cpu=$TEMP_CPU gpu=$TEMP_GPU"
if [ ! -r "$TEMP_GPU" ]; then
  log "warning: GPU sensor not found, CPU-only control"
fi

set_level() {
  local lvl=$1
  if printf 'level %s\n' "$lvl" > "$FAN" 2>/dev/null; then
    [ "$lvl" != "$current" ] && log "temp=${t}C filt=${t_filt}C (cpu=${t_cpu}C gpu=${t_gpu_display}C) -> level $lvl"
    current=$lvl
  else
    log "failed to set level $lvl"
  fi
}

cleanup() { printf 'level auto\n' > "$FAN" 2>/dev/null || true; }
trap cleanup EXIT INT TERM

if [ "$(cat /sys/module/thinkpad_acpi/parameters/fan_control 2>/dev/null)" != "Y" ]; then
  log "warning: fan_control != Y, level writes may be ignored"
fi

# 脚本卡死/被杀后，EC 在 10 秒后接管（每 2 秒喂一次，允许丢 5 个周期）
if printf 'watchdog 10\n' > "$FAN" 2>/dev/null; then
  log "watchdog 10s armed"
else
  log "watchdog not supported; relying on systemd restart"
fi
printf 'level auto\n' > "$FAN" 2>/dev/null || true

next_lower() {
  case $1 in
    7) echo 6 ;;
    6) echo 5 ;;
    5) echo 2 ;;
    2) echo 1 ;;
    1) echo auto ;;
  esac
}

while sleep "$INTERVAL"; do
  raw_cpu=$(cat "$TEMP_CPU" 2>/dev/null) || {
    printf 'level auto\n' > "$FAN" 2>/dev/null || true
    current=auto
    continue
  }
  t_cpu=$((raw_cpu / 1000))
  raw_gpu=$(cat "$TEMP_GPU" 2>/dev/null) || raw_gpu=0
  t_gpu=$((raw_gpu / 1000))

  # 独显关闭/读数无效时忽略；否则取 CPU 与独显的较大值。
  if [ "$t_gpu" -le 0 ] || [ "$t_gpu" -ge 150 ]; then
    t_gpu_display='--'
    t=$t_cpu
  else
    t_gpu_display="$t_gpu"
    if [ "$t_gpu" -gt "$t_cpu" ]; then t=$t_gpu; else t=$t_cpu; fi
  fi
  t_raw=$t

  now=$(date +%s)
  gap=$((now - last_time))
  last_time=$now

  if [ "$gap" -gt "$RESUME_GAP" ]; then
    # 从 suspend 恢复或长时间卡顿：丢弃旧滤波，立即按当前温度控制。
    t_filt=$t_raw
    t_prev=$t_raw
    t_prev2=$t_raw
    first=0
    down_count=0
    delta=0
    delta4=0
    rearm_count=0
    printf 'watchdog 10\n' > "$FAN" 2>/dev/null || true
    log "resume/stall detected (${gap}s), filter reset"
  elif [ "$first" -eq 1 ]; then
    t_filt=$t_raw
    t_prev=$t_raw
    t_prev2=$t_raw
    first=0
    delta=0
    delta4=0
  else
    delta=$((t_raw - t_prev))
    delta4=$((t_raw - t_prev2))
    if [ "$t_raw" -gt "$t_filt" ]; then
      # 升温快跟（50%）
      t_filt=$(( (t_filt * (EMA_UP_DIV - 1) + t_raw) / EMA_UP_DIV ))
    else
      # 降温慢落（25%）
      t_filt=$(( (t_filt * (EMA_DOWN_DIV - 1) + t_raw) / EMA_DOWN_DIV ))
    fi
    t_prev2=$t_prev
    t_prev=$t_raw
  fi

  # 绝对高温直接拉满，不经过滤波/回差。
  if [ "$t_raw" -ge "$FAILSAFE" ]; then
    set_level 7
    down_count=0
    continue
  fi

  # 大跃变：2 秒 +10°C 或 4 秒 +15°C，直接用原始温度快速升档。
  fast=0
  if [ "$delta" -ge "$FAST_DELTA" ] || [ "$delta4" -ge "$FAST_DELTA_4S" ]; then
    fast=1
    t_filt=$t_raw
  fi

  if [ "$fast" -eq 1 ]; then
    ctrl=$t_raw
  else
    ctrl=$t_filt
  fi

  desired=auto
  for lvl in 7 6 5 2 1; do
    if [ "$ctrl" -ge "${ON[$lvl]}" ]; then desired=$lvl; break; fi
  done

  if [ "$current" = auto ]; then
    if [ "$desired" != auto ]; then
      set_level "$desired"
      down_count=0
    fi
  elif [ "$desired" != auto ] && [ "$desired" -gt "$current" ]; then
    set_level "$desired"
    down_count=0
  elif [ "$desired" != auto ] && [ "$desired" -lt "$current" ]; then
    # 降档：连续 5 个周期低于 OFF，才降一级，避免一次跳到底。
    if [ "$ctrl" -le "${OFF[$current]}" ]; then
      down_count=$((down_count + 1))
      if [ "$down_count" -ge "$DOWN_CONFIRM" ]; then
        set_level "$(next_lower "$current")"
        down_count=0
      fi
    else
      down_count=0
    fi
  elif [ "$desired" = auto ]; then
    if [ "$ctrl" -le "${OFF[$current]}" ]; then
      down_count=$((down_count + 1))
      if [ "$down_count" -ge "$DOWN_CONFIRM" ]; then
        set_level "$(next_lower "$current")"
        down_count=0
      fi
    else
      down_count=0
    fi
  else
    down_count=0
  fi

  # 喂 watchdog：档位不变也要周期性写入
  [ "$current" != auto ] && printf 'level %s\n' "$current" > "$FAN" 2>/dev/null || true

  # 定期重新 arm watchdog，防止 EC 在 suspend/resume 后清掉它
  rearm_count=$((rearm_count + 1))
  if [ "$rearm_count" -ge "$WATCHDOG_REARM" ]; then
    printf 'watchdog 10\n' > "$FAN" 2>/dev/null || true
    rearm_count=0
  fi
done
