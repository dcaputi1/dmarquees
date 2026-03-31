#!/bin/bash


CMD_FIFO="/tmp/dmarquees_cmd"
REMOTE_HOST="10.77.77.3"
REMOTE_PORT="5533"


if [ $# -lt 1 ]; then
    echo "Usage: $0 <command text>" >&2
    exit 2
fi

cmd="$*"

# Send to remote TCP
send_remote() {
    {
        printf '%s\n' "$cmd"
        sleep 0.1
    } > /dev/tcp/"$REMOTE_HOST"/"$REMOTE_PORT" 2>/dev/null
}

# Send to local FIFO
send_local() {
    if [ -p "$CMD_FIFO" ]; then
        printf '%s\n' "$cmd" > "$CMD_FIFO" 2>/dev/null || true
    fi
}

send_local
send_remote
