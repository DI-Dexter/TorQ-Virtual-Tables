#!/bin/bash
# VT-11: do identical queries return identical answers from the virtual table and from a
# conventional date-partitioned kdb+ database holding the same data?
#
# Builds two databases from the same captured bytes - the new date+instrument format and a
# conventional date-partitioned splay - stands the conventional one up as a plain q process,
# and runs the same query battery against both.
#
# Requires the capture stack to have run at least once. Run as:
#   cd ~/TorQ-VT-Capture-Pack && ./testfiles/vt-compare-kdb.sh

set -e
cd "$(dirname "$0")/.."
. ./vt-env.sh >/dev/null 2>&1

SCRATCH="/tmp/vt-kdb-compare-$$"
PORT=${PORT:-6099}
mkdir -p "$SCRATCH"
trap 'pkill -f "p $PORT" 2>/dev/null; rm -rf "$SCRATCH"' EXIT

echo "building both databases from the same captured data..."
SCRATCH="$SCRATCH" q testfiles/vt-kdb-prep.q </dev/null

echo ""
echo "starting the conventional kdb+ control on port $PORT..."
q "$SCRATCH/hdb" -p $PORT </dev/null >"$SCRATCH/hdb.log" 2>&1 &
sleep 4

echo ""
SCRATCH="$SCRATCH" PORT=$PORT q testfiles/vt-kdb-compare.q </dev/null
