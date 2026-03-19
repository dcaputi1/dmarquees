#!/bin/bash

CMD_FIFO="${DMARQUEES_CMD_FIFO:-/tmp/dmarquees_cmd}"
CFG_PATH_DEFAULT="$HOME/.dmarquees_transport.conf"
CFG_PATH="${DMARQUEES_TRANSPORT_CFG:-$CFG_PATH_DEFAULT}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <command text>" >&2
    exit 2
fi

cmd="$*"
transport="LOCAL"
remote_host="192.168.50.3"
remote_port="5533"

if [ -f "$CFG_PATH" ]; then
    # shellcheck disable=SC1090
    source "$CFG_PATH"
    transport="${DMARQUEES_TRANSPORT:-$transport}"
    remote_host="${DMARQUEES_REMOTE_HOST:-$remote_host}"
    remote_port="${DMARQUEES_REMOTE_PORT:-$remote_port}"
fi

case "$transport" in
    LOCAL)
        printf '%s\n' "$cmd" > "$CMD_FIFO"
        ;;
    TCP)
        # Send to remote Pi3 via TCP
        {
            printf '%s\n' "$cmd"
            sleep 0.1
        } > /dev/tcp/"$remote_host"/"$remote_port" 2>/dev/null

        # Also forward to local Pi5 splash daemon so it can update its display
        # (e.g. blank on ROM launch, show RA/SA/NA splash on frontend changes).
        # Skip SWAPART — that command only makes sense on Pi3's FUSE mount.
        if [ "$cmd" != "SWAPART" ] && [ -p "$CMD_FIFO" ]; then
            printf '%s\n' "$cmd" > "$CMD_FIFO" 2>/dev/null || true
        fi
        ;;
    UDP)
        # UDP mode not directly supported via /dev/tcp; recommend TCP instead
        echo "Warning: UDP mode not supported without netcat. Using TCP fallback to $remote_host:$remote_port" >&2
        {
            printf '%s\n' "$cmd"
            sleep 0.1
        } > /dev/tcp/"$remote_host"/"$remote_port" 2>/dev/null
        ;;
    *)
        echo "Unknown dmarquees transport mode: $transport" >&2
        exit 2
        ;;
esac
