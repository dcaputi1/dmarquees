#!/usr/bin/env bash
set -euo pipefail

# Target ALSA device
CARD_NUM="2"
DEV_NUM="0"

ASOUND_CONF="/etc/asound.conf"
TMP_FILE="$(mktemp)"

cleanup() {
  rm -f "$TMP_FILE"
}
trap cleanup EXIT

# Build desired config
cat > "$TMP_FILE" <<EOF
# /etc/asound.conf
# Force ALSA default device to card ${CARD_NUM}, device ${DEV_NUM} (hw:${CARD_NUM},${DEV_NUM})

pcm.!default {
    type plug
    slave.pcm "hw:${CARD_NUM},${DEV_NUM}"
}

ctl.!default {
    type hw
    card ${CARD_NUM}
}
EOF

# Install only if changed
if [[ -f "$ASOUND_CONF" ]] && sudo cmp -s "$TMP_FILE" "$ASOUND_CONF"; then
  echo "[OK] $ASOUND_CONF already up to date."
else
  echo "[INFO] Updating $ASOUND_CONF ..."
  sudo install -m 0644 -o root -g root "$TMP_FILE" "$ASOUND_CONF"
  echo "[OK] Wrote $ASOUND_CONF"
fi

# Optional: restart modern audio services if present (no error if absent)
sudo systemctl restart pipewire pipewire-pulse wireplumber 2>/dev/null || true

echo "[DONE] ALSA default set to hw:${CARD_NUM},${DEV_NUM}"
