#!/bin/bash
set -euo pipefail

CFG_PATH="${DMARQUEES_TRANSPORT_CFG:-$HOME/.dmarquees_transport.conf}"
SENDER_SCRIPT="${DMARQUEES_SENDER_SCRIPT:-$HOME/scripts/dmarquees-send.sh}"
CMD_FIFO="${DMARQUEES_CMD_FIFO:-/tmp/dmarquees_cmd}"
PROBE_CMD="${DMARQUEES_PROBE_CMD:-REFRESH}"

SSH_TARGET=""
REMOTE_LOG_LINES=25

usage()
{
    cat <<EOF
Usage: $0 [--ssh user@pi3] [--probe-command CMD]

Checks:
  1) Local transport config and sender script
  2) Local FIFO/daemon status (LOCAL mode)
  3) Remote host/port reachability (TCP/UDP mode)
  4) Sends a probe command through dmarquees-send.sh
  5) Optional remote service and journal check via SSH

Options:
  --ssh user@host      Also validate remote systemd services and recent logs
  --probe-command CMD  Command to send as probe (default: REFRESH)
  -h, --help           Show help
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --ssh)
            SSH_TARGET="${2:-}"
            shift 2
            ;;
        --probe-command)
            PROBE_CMD="${2:-REFRESH}"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

pass=0
warn=0
fail=0

ok()   { echo "[OK]   $*"; pass=$((pass + 1)); }
info() { echo "[INFO] $*"; }
ng()   { echo "[FAIL] $*"; fail=$((fail + 1)); }
wn()   { echo "[WARN] $*"; warn=$((warn + 1)); }

transport="LOCAL"
remote_host="192.168.50.3"
remote_port="5533"

if [ -f "$CFG_PATH" ]; then
    # shellcheck disable=SC1090
    source "$CFG_PATH"
    transport="${DMARQUEES_TRANSPORT:-$transport}"
    remote_host="${DMARQUEES_REMOTE_HOST:-$remote_host}"
    remote_port="${DMARQUEES_REMOTE_PORT:-$remote_port}"
    ok "Loaded transport config: $CFG_PATH"
else
    wn "Transport config not found at $CFG_PATH; assuming LOCAL"
fi

if [ ! -x "$SENDER_SCRIPT" ]; then
    ng "Sender script is missing or not executable: $SENDER_SCRIPT"
    exit 1
fi
ok "Sender script available: $SENDER_SCRIPT"

case "$transport" in
    LOCAL|TCP|UDP)
        ok "Transport mode: $transport"
        ;;
    *)
        ng "Invalid transport mode in config: $transport"
        exit 1
        ;;
esac

if [ "$transport" = "LOCAL" ]; then
    if [ -p "$CMD_FIFO" ]; then
        ok "Local FIFO exists: $CMD_FIFO"
    else
        ng "Local FIFO missing: $CMD_FIFO"
    fi

    if pgrep -x dmarquees >/dev/null 2>&1; then
        ok "Local dmarquees process is running"
    else
        wn "Local dmarquees process is not running"
    fi
else
    if ! command -v nc >/dev/null 2>&1; then
        ng "nc not found. Install netcat-openbsd on Pi5"
        exit 1
    fi

    if [ "$transport" = "TCP" ]; then
        if nc -z -w 1 "$remote_host" "$remote_port" >/dev/null 2>&1; then
            ok "TCP endpoint reachable: $remote_host:$remote_port"
        else
            ng "TCP endpoint unreachable: $remote_host:$remote_port"
        fi
    else
        wn "UDP reachability cannot be proved without app-level ack"
        if nc -u -w 1 "$remote_host" "$remote_port" </dev/null >/dev/null 2>&1; then
            ok "UDP probe packet sent to $remote_host:$remote_port"
        else
            wn "UDP probe send returned non-zero for $remote_host:$remote_port"
        fi
    fi
fi

if "$SENDER_SCRIPT" "$PROBE_CMD"; then
    ok "Probe command sent successfully: $PROBE_CMD"
else
    ng "Probe command failed: $PROBE_CMD"
fi

if [ -n "$SSH_TARGET" ]; then
    info "Running remote checks via SSH: $SSH_TARGET"

    if ssh -o BatchMode=yes -o ConnectTimeout=3 "$SSH_TARGET" "echo ok" >/dev/null 2>&1; then
        ok "SSH connectivity ok: $SSH_TARGET"
    else
        ng "SSH connectivity failed: $SSH_TARGET"
    fi

    if ssh -o BatchMode=yes "$SSH_TARGET" "systemctl is-active dmarquees-daemon.service" | grep -q '^active$'; then
        ok "Remote service active: dmarquees-daemon.service"
    else
        ng "Remote service not active: dmarquees-daemon.service"
    fi

    if ssh -o BatchMode=yes "$SSH_TARGET" "systemctl is-active dmarquees-netbridge.service" | grep -q '^active$'; then
        ok "Remote service active: dmarquees-netbridge.service"
    else
        ng "Remote service not active: dmarquees-netbridge.service"
    fi

    if ssh -o BatchMode=yes "$SSH_TARGET" "journalctl -u dmarquees-netbridge.service -n $REMOTE_LOG_LINES --no-pager" >/tmp/dmarquees-netbridge-journal.txt 2>/dev/null; then
        ok "Fetched remote netbridge journal (last $REMOTE_LOG_LINES lines)"
        if grep -Eqi 'forwarded|recv|listening' /tmp/dmarquees-netbridge-journal.txt; then
            ok "Remote journal contains netbridge activity markers"
        else
            wn "Remote journal fetched but no obvious activity markers found"
        fi
    else
        wn "Could not fetch remote netbridge journal"
    fi
fi

echo
echo "Summary: pass=$pass warn=$warn fail=$fail"

if [ "$fail" -gt 0 ]; then
    exit 1
fi

exit 0
