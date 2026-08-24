#!/bin/bash
# Start the virtual-table capture stack: discovery + segmented tickerplant + WDB + feed.
# No RDB, HDB, sort process or gateway.
#
#   ./start.sh              start
#   TORQHOME=/path ./start.sh   use a different TorQ checkout

set -e
. "$(cd "$(dirname "$0")" && pwd)/vt-env.sh"

if [ ! -f "${TORQHOME}/torq.q" ]; then
  echo "ERROR: no torq.q under TORQHOME=${TORQHOME}" >&2
  echo "       set TORQHOME to your TorQ checkout, or edit vt-env.sh" >&2
  exit 1
fi

echo "TorQ core : ${TORQHOME}"
echo "pack      : ${TORQAPPHOME}"
echo "database  : ${KDBDB}"
echo "logs      : ${KDBLOG}"
echo ""

cd "$TORQHOME"
ACL="${KDBAPPCONFIG}/passwords/accesslist.txt"

launch () {   # name, proctype, extra flags, load target
  echo "  $1..."
  q torq.q -load "$4" $KDBSTACKID \
    -proctype "$2" -procname "$1" -localtime $3 \
    </dev/null >"${KDBLOG}/$1.console.log" 2>&1 &
}

launch discovery1 discovery "-U $ACL"                                     "${KDBCODE}/processes/discovery.q"
sleep 2
echo "  stp1..."
q torq.q -load "${KDBCODE}/processes/segmentedtickerplant.q" \
  -schemafile "${TORQAPPHOME}/database.q" -tplogdir "$KDBTPLOG" $KDBSTACKID \
  -proctype segmentedtickerplant -procname stp1 -U "$ACL" -localtime \
  </dev/null >"${KDBLOG}/stp1.console.log" 2>&1 &
sleep 2
launch wdb1  wdb  "-U $ACL -g 1"                                          "${KDBCODE}/processes/wdb.q"
sleep 3
launch idb1  idb  "-U $ACL -s 4"                                          "${KDBAPPCODE}/processes/vtidb.q"
sleep 2
launch feed1 feed ""                                                      "${KDBAPPCODE}/tick/feed.q"

echo ""
echo "Started. To watch it work:"
echo "  find ${KDBDB} -mindepth 3 -maxdepth 3 -type d | head"
echo "  tail -f ${KDBLOG}/out_wdb1.log"
echo ""
echo "To query the IDB:"
echo "  q -c 25 200"
echo "  h:hopen \`::$((KDBBASEPORT+30)):idb:pass"
echo "  h\"select n:count i by sym from trade\""
