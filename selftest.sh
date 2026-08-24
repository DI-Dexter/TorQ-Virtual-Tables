#!/bin/bash
# End-to-end self test. Run it with the stack up (./start.sh).
#
# Publishes a new instrument to the tickerplant and checks it arrives at the IDB through
# the whole chain, that the partition column stays out of the files, and that plain
# appends need no rebuild.

. "$(cd "$(dirname "$0")" && pwd)/vt-env.sh" >/dev/null 2>&1

if ! pgrep -f "procname idb1" >/dev/null 2>&1; then
  echo "ERROR: the stack is not running - start it with ./start.sh" >&2
  exit 1
fi

q "${TORQAPPHOME}/code/selftest.q" < /dev/null
