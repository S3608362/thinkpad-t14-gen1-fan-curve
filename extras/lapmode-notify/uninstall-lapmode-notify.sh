#!/usr/bin/env bash
set -euo pipefail

systemctl --user disable --now lapmode-notify.service 2>/dev/null || true
rm -f "$HOME/.local/bin/lapmode-notify.sh" \
      "$HOME/.config/systemd/user/lapmode-notify.service"
systemctl --user daemon-reload

echo "已卸载。"
echo "缓存状态保留在 ${XDG_CACHE_HOME:-$HOME/.cache}/lapmode-notify/，可手动删除。"
