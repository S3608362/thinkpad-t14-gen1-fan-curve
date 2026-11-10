#!/usr/bin/env bash
# ThinkPad lap mode 状态通知。
#
# 设计目标：
#   - 只观察，不干预（不写 lapmode，不切性能模式）
#   - 只在 0 <-> 1 变化时发通知，不累计、不刷屏
#   - 用同一个通知 ID 替换，新通知覆盖旧通知，不重叠
#   - 30 秒轮询，单个休眠进程，几乎零 CPU
#   - 状态文件记录上次状态，服务重启后不重复通知
set -u

LAPMODE=/sys/devices/platform/thinkpad_acpi/dytc_lapmode
CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}/lapmode-notify"
STATE_FILE="$CACHE_DIR/state"
ID_FILE="$CACHE_DIR/notify-id"
INTERVAL="${LAPMODE_INTERVAL:-30}"

command -v notify-send >/dev/null 2>&1 || { echo "缺少 notify-send" >&2; exit 1; }
[ -r "$LAPMODE" ] || { echo "无法读取 $LAPMODE" >&2; exit 1; }

mkdir -p "$CACHE_DIR"

last_id=""
[ -r "$ID_FILE" ] && last_id=$(cat "$ID_FILE" 2>/dev/null)

notify() {
    local state="$1" title body urgency timeout newid=""

    if [ "$state" = "1" ]; then
        title="ThinkPad 膝上模式"
        body=$'EC 判定底部散热受阻，CPU 已被固件限制到低频。\n温度低、风扇安静但系统卡顿是正常现象。\n改善底部进风后约 4–6 分钟自动解除。'
        urgency="normal"
        timeout=0
    else
        title="膝上模式已解除"
        body="CPU 性能已恢复。"
        urgency="low"
        timeout=5000
    fi

    if [ -n "$last_id" ]; then
        newid=$(notify-send -p -r "$last_id" -u "$urgency" -t "$timeout" \
                -a "ThinkPad" "$title" "$body" 2>/dev/null) || true
    else
        newid=$(notify-send -p -u "$urgency" -t "$timeout" \
                -a "ThinkPad" "$title" "$body" 2>/dev/null) || true
    fi

    if [ -n "$newid" ]; then
        last_id="$newid"
        printf '%s\n' "$newid" > "$ID_FILE"
    fi
}

# 启动基准：沿用上次状态，避免服务重启后重复通知
last=""
[ -r "$STATE_FILE" ] && last=$(cat "$STATE_FILE" 2>/dev/null)

if [ -z "$last" ]; then
    if IFS= read -r cur < "$LAPMODE"; then
        last="$cur"
        printf '%s\n' "$last" > "$STATE_FILE"
        [ "$last" = "1" ] && notify 1
    fi
fi

while :; do
    if IFS= read -r cur < "$LAPMODE"; then
        if [ "$cur" != "$last" ]; then
            notify "$cur"
            last="$cur"
            printf '%s\n' "$last" > "$STATE_FILE"
        fi
    fi
    sleep "$INTERVAL"
done
