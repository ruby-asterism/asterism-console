#!/bin/sh
# The router of deploy/vps: zenohd 1.10.1 on the configuration the console
# generates from its registry (/generated/cloud.json5). The console's apply
# writes that file, then /generated/restart.request (bin/relay_restart_request);
# this loop sees the request change and restarts zenohd, so the console
# needs no docker rights. A zenohd that stops by itself is started again.
cfg=/generated/cloud.json5
req=/generated/restart.request
child=

stop() {
  [ -n "$child" ] && kill "$child" 2>/dev/null && wait "$child"
  exit 0
}
trap stop TERM INT

while [ ! -s "$cfg" ]; do
  echo "run.sh: waiting for $cfg (bin/rails relay:generate in the console container)"
  sleep 5
done

while true; do
  last=$(cat "$req" 2>/dev/null)
  echo "run.sh: starting zenohd on $cfg ($(sed -n 3p "$cfg"))"
  /zenohd -c "$cfg" &
  child=$!
  while kill -0 "$child" 2>/dev/null; do
    sleep 2
    now=$(cat "$req" 2>/dev/null)
    if [ "$now" != "$last" ]; then
      echo "run.sh: restart requested ($now)"
      kill "$child" 2>/dev/null
      wait "$child"
      break
    fi
  done
  wait "$child" 2>/dev/null
  child=
  sleep 1
done
