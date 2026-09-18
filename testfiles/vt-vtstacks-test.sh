#!/bin/bash
# =============================================================================
# VTSTACKS=2 : both capture stacks from ONE torq.sh start (§8.3.2).
#
#   ./testfiles/vt-vtstacks-test.sh
#
# vt-twostack-test.sh proves the shared-root BEHAVIOUR by hand-building two config
# trees. This proves the shipped WIRING: that the pack's own setenv.sh, process file
# and settings can start both stacks with nothing to edit, and that the two writers
# end up on different tickerplants.
#
# That last part is the whole reason this file exists. A writer picks its tickerplant
# with a filter on process TYPE and then takes the first row, so with both stacks in
# one process file it can bind to the other stack's tickerplant - and then captures
# the other stack's instruments while every process stays up and logs nothing. The
# ownership manifests are the assertion: they must be disjoint, and they must match
# the universes the two feeds were configured with.
#
#   KEEP=1 ./testfiles/vt-vtstacks-test.sh     leave both stacks up for inspection
#
# Runs at KDBBASEPORT=6400 (so 6400/6500) and under its own TORQDATAHOME, which is all
# it takes to move the whole topology off a dev stack - the process file derives every
# port from the base.
# exit 0 pass, 1 fail, 77 skip.
# =============================================================================
set -u
PACK="$(cd "$(dirname "$0")/.." && pwd)"
BASE=6400
PASS=0; FAIL=0
ok  () { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad () { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
skip() { echo "  $1"; exit 77; }

[ -n "${TORQHOME:-}" ] || skip "TORQHOME is not set - source setenv.sh first"
[ -f "$TORQHOME/torq.sh" ] || skip "no torq.sh under TORQHOME=$TORQHOME"
command -v q >/dev/null || skip "q is not on PATH"
for p in $BASE $((BASE+5)) $((BASE+30)) $((BASE+100)) $((BASE+105)) $((BASE+130)); do
  (exec 3<>/dev/tcp/localhost/$p) 2>/dev/null && skip "port $p is in use"
done

S=$(mktemp -d /tmp/vt-vtstacks-XXXX)
TORQ () { env TORQDATAHOME="$S" KDBBASEPORT=$BASE VTSTACKS=2 SETENV="$PACK/setenv.sh" \
              "$TORQHOME/torq.sh" "$@"; }
cleanup () {
  if [ "${KEEP:-0}" = 1 ]; then
    echo ""
    echo "  KEEP=1: both stacks left running, data and logs under $S"
    echo "  stop with: TORQDATAHOME=$S KDBBASEPORT=$BASE VTSTACKS=2 SETENV=$PACK/setenv.sh \$TORQHOME/torq.sh stop all; rm -rf $S"
    return
  fi
  TORQ stop all >/dev/null 2>&1; sleep 1; rm -rf "$S"
}
trap cleanup EXIT

US='`AMD`AIG`AAPL`DELL`DOW`GOOG`HPQ`INTC`IBM`MSFT'
UK='`BARC`HSBA`LLOY`NWG`STAN`VOD`BP`SHEL`GSK`AZN'

# --- the flag picks the process file, before anything is started ---------------
# Every probe runs against its OWN TORQDATAHOME, because sourcing setenv.sh records the
# choice there - a probe sharing a data directory with the one before it would read that
# back and prove nothing.
sel () {                                    # sel <VTSTACKS or "-"> <data dir>
  local v=$1 d=$2
  if [ "$v" = "-" ]; then
    env -u VTSTACKS TORQHOME="$TORQHOME" TORQDATAHOME="$d" \
        bash -c ". $PACK/setenv.sh >/dev/null 2>&1; basename \$TORQPROCESSES"
  else
    env VTSTACKS="$v" TORQHOME="$TORQHOME" TORQDATAHOME="$d" \
        bash -c ". $PACK/setenv.sh >/dev/null 2>&1; basename \$TORQPROCESSES"
  fi
}
[ "$(sel 1 $S/p1)" = "process.csv" ]        && ok "VTSTACKS=1 selects process.csv" \
                                            || bad "VTSTACKS=1 selected $(sel 1 $S/p1b)"
[ "$(sel 2 $S/p2)" = "process-2stack.csv" ] && ok "VTSTACKS=2 selects process-2stack.csv" \
                                            || bad "VTSTACKS=2 selected $(sel 2 $S/p2b)"
# an unset flag on a fresh data directory must behave as the pack did before it existed
[ "$(sel - $S/p3)" = "process.csv" ] && ok "an unset VTSTACKS on a fresh database selects process.csv" \
                                     || bad "an unset VTSTACKS changed the process file"
# ...but once chosen it is remembered, so stop/summary do not need the flag again
[ "$(sel - $S/p2)" = "process-2stack.csv" ] && ok "VTSTACKS=2 is remembered for later calls" \
                                            || bad "VTSTACKS=2 was not remembered - a later stop all would orphan stack 2"
[ "$(sel 1 $S/p2)" = "process.csv" ] && ok "an explicit VTSTACKS=1 overrides what was remembered" \
                                     || bad "VTSTACKS=1 did not override the remembered choice"
[ "$(sel - $S/p2)" = "process.csv" ] && ok "...and the override is remembered in turn" \
                                     || bad "the override was not written back"
[ -f "$S/p2/.vtstacks" ] && ok "the choice is recorded in the data directory, not the install" \
                         || bad "no .vtstacks marker under the data directory"

# --- start both stacks ---------------------------------------------------------
TORQ start all >/dev/null 2>&1
sleep 20

upn=$(TORQ summary 2>/dev/null | grep -c "|  up  ")
[ "$upn" -eq 9 ] && ok "all 9 processes of both stacks are up" \
                 || bad "expected 9 processes up, torq.sh summary reports $upn"

# --- each writer on its OWN tickerplant ----------------------------------------
for n in 1 2; do
  grep -q "subscribing only to tickerplant \`stp$n" "$S/logs/out_wdb$n.log" 2>/dev/null \
    && ok "wdb$n installed the tickerplant pin" \
    || bad "wdb$n did not pin its tickerplant - the override column did not reach it"
  grep -q "tickerplant found - subscribing to stp$n" "$S/logs/out_wdb$n.log" 2>/dev/null \
    && ok "wdb$n subscribed to stp$n" \
    || bad "wdb$n subscribed to the WRONG tickerplant: $(grep -o 'subscribing to stp[0-9]' "$S/logs/out_wdb$n.log" | tail -1)"
done

# --- the manifests are the proof, and they must be disjoint --------------------
cat > "$S/own.q" <<'QEOF'
d:hsym `$(first .Q.opt[.z.x]`dir),"/.vtowner";
$[()~key d; -1 "NOMANIFEST"; -1 "|" sv {" " sv string asc get x} each ` sv/:d,/:asc key d];
exit 0;
QEOF
own=$(q "$S/own.q" -q -dir "$S/db" 2>/dev/null)
o1=$(echo "$own" | cut -d'|' -f1); o2=$(echo "$own" | cut -d'|' -f2)
[ -n "$o1" ] && [ -n "$o2" ] && [ "$o1" != "$o2" ] \
  && ok "the two writers own different instrument sets" \
  || bad "ownership manifests are missing or identical: '$own'"
both=$(echo "$o1 $o2" | tr ' ' '\n' | sort | uniq -d | tr -d '[:space:]')
[ -z "$both" ] && ok "no instrument is claimed by both writers" \
               || bad "claimed by both writers: $both - a writer bound to the wrong tickerplant"

# --- the reader serves both universes, once each -------------------------------
cat > "$S/query.q" <<'QEOF'
o:.Q.opt .z.x;
h:@[hopen;(`$":localhost:",first[o`port],":admin:admin";5000);0Ni];
$[null h; -1 "NOCONN"; -1 .Q.s1 @[h;first o`expr;{[e] `$"ERR: ",e}]];
exit 0;
QEOF
qq () { q "$S/query.q" -q -port "$1" -expr "$2" 2>/dev/null; }
us=$(qq $((BASE+30)) "count select from trade where sym in $US")
uk=$(qq $((BASE+30)) "count select from trade where sym in $UK")
tot=$(qq $((BASE+30)) 'count select from trade')
[ "$us" -gt 0 ] 2>/dev/null && ok "stack 1's instruments reach the reader ($us rows)" \
                            || bad "stack 1 captured nothing (got '$us')"
[ "$uk" -gt 0 ] 2>/dev/null && ok "stack 2's instruments reach the reader ($uk rows)" \
                            || bad "stack 2 captured nothing (got '$uk')"
[ "$((us+uk))" = "$tot" ] 2>/dev/null && ok "every row belongs to exactly one stack ($us + $uk = $tot)" \
                                      || bad "row counts do not add up: $us + $uk != $tot"

# the second reader is wired to the same root and must answer the same
tot2=$(qq $((BASE+130)) 'count select from trade')
[ -n "$tot2" ] && [ "$tot2" != "NOCONN" ] && ok "the second stack's reader serves the shared root too ($tot2 rows)" \
                                          || bad "idb2 did not answer (got '$tot2')"

# --- restarting one writer must not take the other's day with it ---------------
before=$(qq $((BASE+30)) "count select from trade where sym in $US")
TORQ stop wdb2 >/dev/null 2>&1; sleep 2
TORQ start wdb2 >/dev/null 2>&1; sleep 14
after=$(qq $((BASE+30)) "count select from trade where sym in $US")
[ "$after" -ge "$before" ] 2>/dev/null && ok "restarting wdb2 left stack 1 intact ($before -> $after rows)" \
                                       || bad "restarting wdb2 DESTROYED stack 1 data ($before -> $after rows)"
grep -q "scoped delete" "$S/logs/out_wdb2.log" 2>/dev/null \
  && ok "wdb2 scoped its pre-replay delete to its own instruments" \
  || bad "no scoped delete in wdb2's log - .wdb.multiwriter did not reach it"

echo ""
echo "  $PASS passed, $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ]
