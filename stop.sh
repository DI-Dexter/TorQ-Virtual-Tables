#!/bin/bash
# Stop every process belonging to THIS pack.
#
# Scoped by path, not by procname alone. discovery1/stp1/wdb1/feed1/idb1 are TorQ's default
# names, so other packs on the same machine use them too - and a second copy of this pack on
# another port uses exactly these. Matching the name alone would stop all of them. Every
# process this pack launches carries $TORQAPPHOME somewhere in its command line (-load,
# -schemafile or -U), so that is what identifies ours.
. "$(cd "$(dirname "$0")" && pwd)/vt-env.sh" >/dev/null 2>&1

PROCS="discovery1 stp1 wdb1 feed1 idb1"

mine () {                                   # pids of <procname> that belong to this pack
  pgrep -f "procname $1" 2>/dev/null | while read -r pid; do
    [ "$pid" = "$$" ] && continue
    ps -p "$pid" -o args= 2>/dev/null | grep -qF -- "$TORQAPPHOME" && echo "$pid"
  done
}

for p in $PROCS; do
  pids=$(mine "$p")
  [ -n "$pids" ] && kill $pids 2>/dev/null && echo "  stopped $p"
done

sleep 1

left=""
for p in $PROCS; do left="$left $(mine "$p")"; done
left=$(echo $left)                          # collapse whitespace
if [ -n "$left" ]; then
  echo "  WARNING: some processes still running:"
  ps -o pid=,cmd= -p $left 2>/dev/null | cut -c1-120 | sed 's/^/    /'
else
  echo "  all stopped"
fi
