#!/bin/bash
# VT-12 load test. Starts a clean stack WITHOUT the demo feed, then hands off to
# code/loadtest.q which drives the load and measures the whole chain from one process.
#
#   ./loadtest.sh                            200k rows, 50 instruments
#   ROWS=2000000 PAIRS=500 ./loadtest.sh     heavier
#
# Wipes var/ so every run starts from a known state.

cd "$(dirname "$0")"
. ./setenv.sh >/dev/null 2>&1

if [ ! -f "${TORQHOME}/torq.q" ]; then
  echo "ERROR: no torq.q under TORQHOME=${TORQHOME}" >&2
  echo "       set TORQHOME to your TorQ checkout, or edit setenv.sh" >&2
  exit 1
fi

ROWS=${ROWS:-200000}
PAIRS=${PAIRS:-50}
BATCH=${BATCH:-1000}

SETENV="$PWD/setenv.sh" "$TORQHOME/torq.sh" stop all >/dev/null 2>&1
rm -rf var
mkdir -p "$KDBDB" "$KDBLOG" "$KDBTPLOG"

echo "load test: $ROWS rows, $PAIRS instruments, batches of $BATCH"

APPHOME="$TORQAPPHOME"

# Bring the stack up through TorQ's process manager, naming the processes so the demo
# feed (feed1) is left out - the load test drives its own data through code/loadtest.q.
SETENV="$PWD/setenv.sh" "$TORQHOME/torq.sh" start discovery1 stp1 wdb1 idb1
sleep 8

# count only THIS pack's processes - the procnames are TorQ defaults, so an unscoped
# pgrep counts every stack on the machine (it reported 8/4 with two stacks up)
up=$(pgrep -f 'procname (discovery1|stp1|wdb1|idb1)' 2>/dev/null | while read -r pid; do
  ps -p "$pid" -o args= 2>/dev/null | grep -qF -- "$TORQAPPHOME" && echo x
done | wc -l)
echo "stack up: ${up}/4"
echo ""

LOADROWS=$ROWS LOADPAIRS=$PAIRS LOADBATCH=$BATCH q "${APPHOME}/code/loadtest.q" </dev/null

echo ""
echo "  files on disk          : $(find "$KDBDB" -type f | wc -l)"
echo "  size on disk           : $(du -sh "$KDBDB" | cut -f1)"
echo "  error bytes            : $(cat "${KDBLOG}"/err_*.log 2>/dev/null | wc -c)"
