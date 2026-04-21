#!/bin/bash

REMOTE_HOST="10.77.77.3"
REMOTE_PORT="5533"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <command text>" >&2
    exit 2
fi

cmd="$*"

send_remote()
{
    timeout 2 bash -c "printf '%s\\n' \"$cmd\" > /dev/tcp/$REMOTE_HOST/$REMOTE_PORT" 2>/dev/null
}

send_remote

exit 0