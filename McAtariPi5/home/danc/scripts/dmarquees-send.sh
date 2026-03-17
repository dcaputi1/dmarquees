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
        # Use bash built-in /dev/tcp (no netcat dependency required)
        {
            printf '%s\n' "$cmd"
            sleep 0.1
        } > /dev/tcp/"$remote_host"/"$remote_port" 2>/dev/null
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
