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


# Track success of each send
send_local
local_status=$?
send_remote
remote_status=$?

# If both fail, exit with error
if [ $local_status -ne 0 ] && [ $remote_status -ne 0 ]; then
    echo "[dmarquees-send.sh] ERROR: Failed to send command to both local FIFO and remote TCP." >&2
    exit 1
fi

# Success if at least one send worked
exit 0
