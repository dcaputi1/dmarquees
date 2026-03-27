#!/bin/bash

CMD_FIFO="${DMARQUEES_CMD_FIFO:-/tmp/dmarquees_cmd}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARCADE_HOME_DEFAULT="$(cd "$SCRIPT_DIR/.." && pwd)"
CFG_PATH_DEFAULT="$ARCADE_HOME_DEFAULT/.dmarquees_transport.conf"
CFG_PATH="${DMARQUEES_TRANSPORT_CFG:-$CFG_PATH_DEFAULT}"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <command text>" >&2
    exit 2
fi

cmd="$*"
transport="LOCAL"
remote_host="10.77.77.3"
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
        send_remote() {
            {
                printf '%s\n' "$cmd"
                sleep 0.1
            } > /dev/tcp/"$remote_host"/"$remote_port" 2>/dev/null
        }

        send_local() {
            if [ -p "$CMD_FIFO" ]; then
                printf '%s\n' "$cmd" > "$CMD_FIFO" 2>/dev/null || true
            fi
        }

        case "$cmd" in
            DCPANEL\ *|MCPANEL\ *|SWAPART|REFRESH)
                # Pi3 is the art host in dual-Pi mode.
                send_remote
                ;;
            RA|SA|NA|CLEAR|RC:*)
                # These update both the remote art host and the local Pi5 splash host.
                send_remote
                send_local
                ;;
            RESET)
                send_remote
                send_local
                ;;
            EXIT)
                send_remote
                ;;
            *)
                # Default to remote-only in TCP mode.
                send_remote
                ;;
        esac
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
