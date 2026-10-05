#!/usr/bin/env bash
# Installs claude-window-keeper as a systemd timer. Run as root.
set -euo pipefail
cd "$(dirname "$0")"

install -m 755 claude-window-keeper.sh /usr/local/bin/claude-window-keeper.sh
# Keep existing settings on re-install.
[[ -e /etc/default/claude-window-keeper ]] || install -m 644 claude-window-keeper.default /etc/default/claude-window-keeper
install -m 644 systemd/claude-window-keeper.service systemd/claude-window-keeper.timer /etc/systemd/system/

systemctl daemon-reload
systemctl enable --now claude-window-keeper.timer
/usr/local/bin/claude-window-keeper.sh --dry-run
