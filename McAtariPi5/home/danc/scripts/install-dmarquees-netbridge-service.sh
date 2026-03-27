#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_SRC="$SCRIPT_DIR/dmarquees-netbridge.service"
ENV_EXAMPLE_SRC="$SCRIPT_DIR/dmarquees-netbridge.env.example"
PY_SRC="$SCRIPT_DIR/dmarquees-netbridge.py"

SERVICE_DST="/etc/systemd/system/dmarquees-netbridge.service"
ENV_DST="/etc/default/dmarquees-netbridge"
PY_DST="/usr/local/bin/dmarquees-netbridge.py"

if [ ! -f "$SERVICE_SRC" ] || [ ! -f "$ENV_EXAMPLE_SRC" ] || [ ! -f "$PY_SRC" ]; then
    echo "Missing required source files in $SCRIPT_DIR" >&2
    exit 1
fi

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi

install -m 0755 "$PY_SRC" "$PY_DST"
install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"

if [ ! -f "$ENV_DST" ]; then
    install -m 0644 "$ENV_EXAMPLE_SRC" "$ENV_DST"
fi

systemctl daemon-reload
systemctl enable --now dmarquees-netbridge.service

echo "Installed and started dmarquees-netbridge.service"
echo "Edit $ENV_DST for TCP host/port settings, then:"
echo "  sudo systemctl restart dmarquees-netbridge.service"
echo "Check status/logs:"
echo "  systemctl status dmarquees-netbridge.service"
echo "  journalctl -u dmarquees-netbridge.service -f"
