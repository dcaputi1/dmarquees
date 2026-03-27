#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_SRC="$SCRIPT_DIR/dmarquees-daemon.service"
ENV_EXAMPLE_SRC="$SCRIPT_DIR/dmarquees-daemon.env.example"

SERVICE_DST="/etc/systemd/system/dmarquees-daemon.service"
ENV_DST="/etc/default/dmarquees-daemon"

if [ ! -f "$SERVICE_SRC" ] || [ ! -f "$ENV_EXAMPLE_SRC" ]; then
    echo "Missing required source files in $SCRIPT_DIR" >&2
    exit 1
fi

if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Run as root: sudo $0" >&2
    exit 1
fi


# Always overwrite the systemd service file
install -m 0644 "$SERVICE_SRC" "$SERVICE_DST"

# Ensure the multi-user.target.wants symlink is correct
WANTS_DIR="/etc/systemd/system/multi-user.target.wants"
WANTS_LINK="$WANTS_DIR/dmarquees-daemon.service"
if [ -L "$WANTS_LINK" ] || [ -e "$WANTS_LINK" ]; then
    rm -f "$WANTS_LINK"
fi
ln -s "$SERVICE_DST" "$WANTS_LINK"

if [ ! -f "$ENV_DST" ]; then
    install -m 0644 "$ENV_EXAMPLE_SRC" "$ENV_DST"
fi

systemctl daemon-reload
systemctl enable --now dmarquees-daemon.service

echo "Installed and started dmarquees-daemon.service"
echo "Edit $ENV_DST for startup mode/user, then:"
echo "  sudo systemctl restart dmarquees-daemon.service"
echo "Check status/logs:"
echo "  systemctl status dmarquees-daemon.service"
echo "  journalctl -u dmarquees-daemon.service -f"
