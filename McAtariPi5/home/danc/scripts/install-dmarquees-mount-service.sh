#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_SRC="$SCRIPT_DIR/dmarquees-mount.service"
ENV_EXAMPLE_SRC="$SCRIPT_DIR/dmarquees-mount.env.example"

SERVICE_DST="/etc/systemd/system/dmarquees-mount.service"
ENV_DST="/etc/default/dmarquees-mount"

if [ ! -f "$SERVICE_SRC" ] || [ ! -f "$ENV_EXAMPLE_SRC" ]; then
    echo "Missing required source files in $SCRIPT_DIR" >&2
    exit 1
fi

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"

if [ ! -f "$ENV_DST" ]; then
    install -m 0644 "$ENV_EXAMPLE_SRC" "$ENV_DST"
fi

systemctl daemon-reload
systemctl enable --now dmarquees-mount.service

echo "Installed and started dmarquees-mount.service"
echo "Edit $ENV_DST to override default user/paths, then:"
echo "  sudo systemctl restart dmarquees-mount.service"
echo "Check status/logs:"
echo "  systemctl status dmarquees-mount.service"
echo "  journalctl -u dmarquees-mount.service -f"
