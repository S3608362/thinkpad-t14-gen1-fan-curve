#!/usr/bin/env bash
# /usr/local/sbin/thinkfan-lite.sh
# ThinkPad 手动风扇曲线：coretemp 采样 + 档位滞后 + watchdog + fail-safe
set -u

FAN=/proc/acpi/ibm/fan
INTERVAL=2
FAILSAFE=90
DOWN_CONFIRM=3

find_hwmon() {
  local d
  for d in /sys/class/hwmon/hwmon*; do
    [ -r "$d/name" ] || continue
    [ "$(cat "$d/name")" = "$1" ] && { printf '%s\n' "$d"; return 0; }
  done
  return 1
}

CORE=$(find_hwmon coretemp) || { echo "coretemp hwmon not found" >&2; exit 1; }
TP=$(find_hwmon thinkpad) || { echo "thinkpad hwmon not found" >&2; exit 1; }
TEMP_CPU="$CORE/temp1_input"
TEMP_GPU="$TP/temp2_input"

# 实测：1=2868, 2=3293, 3=3405, 4=3512, 5=4518, 6=4987, 7=4970 RPM
# 2/3/4 几乎一样，6/7 饱和，所以只用 1/2/5/6/7。
declare -A ON=(  [1]=48 [2]=56 [5]=68 [6]=80 [7]=88 )
declare -A OFF=( [1]=44 [2]=52 [5]=64 [6]=76 [7]=84 )

current=auto
down_count=0
t=0
t_cpu=0
t_gpu_display='--'
log() { logger -t thinkfan-lite "$*"; }

set_level() {
  local lvl=$1
  if printf 'level %s\n' "$lvl" > "$FAN" 2>/dev/null; then
    [ "$lvl" != "$current" ] && log "temp=${t}C (cpu=${t_cpu}C gpu=${t_gpu_display}C) -> level $lvl"
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

  if [ "$t" -ge "$FAILSAFE" ]; then
    set_level 7
    continue
  fi

  desired=auto
  for lvl in 7 6 5 2 1; do
    if [ "$t" -ge "${ON[$lvl]}" ]; then desired=$lvl; break; fi
  done

  if [ "$current" = auto ]; then
    if [ "$desired" != auto ]; then
      set_level "$desired"
      down_count=0
    fi
  elif [ "$desired" = auto ]; then
    if [ "$t" -le "${OFF[$current]}" ]; then
      down_count=$((down_count + 1))
      if [ "$down_count" -ge "$DOWN_CONFIRM" ]; then
        set_level auto
        down_count=0
      fi
    else
      down_count=0
    fi
  elif [ "$desired" -gt "$current" ]; then
    set_level "$desired"
    down_count=0
  elif [ "$desired" -lt "$current" ]; then
    if [ "$t" -le "${OFF[$current]}" ]; then
      down_count=$((down_count + 1))
      if [ "$down_count" -ge "$DOWN_CONFIRM" ]; then
        set_level "$desired"
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
done
