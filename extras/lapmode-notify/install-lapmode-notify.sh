#!/usr/bin/env bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"

install -Dm755 "$HERE/lapmode-notify.sh" "$HOME/.local/bin/lapmode-notify.sh"
install -Dm644 "$HERE/lapmode-notify.service" "$HOME/.config/systemd/user/lapmode-notify.service"

systemctl --user daemon-reload
systemctl --user enable --now lapmode-notify.service

echo "已安装并启动："
systemctl --user status lapmode-notify.service --no-pager | head -8
echo
echo "查看日志："
echo "  journalctl --user -u lapmode-notify.service -b"
echo
echo "卸载："
echo "  ./uninstall-lapmode-notify.sh"
