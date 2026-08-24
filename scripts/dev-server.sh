#!/bin/sh
# The dev SPICE server is a quickemu guest on the LAN, not a local process — see docs/dev-server.md.
# This only reports whether it is reachable.
set -e
HOST=${SPICE_HOST:-192.168.50.6}
PORT=${SPICE_PORT:-5930}
if nc -vz -G 5 "$HOST" "$PORT" 2>&1; then
  echo "dev server reachable at $HOST:$PORT — confirm SPICE with: swift run spicesee-cli connect $HOST $PORT"
else
  echo "no TCP listener on $HOST:$PORT — start the quickemu guest on the Ubuntu server"
  exit 1
fi
