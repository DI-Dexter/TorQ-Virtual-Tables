#!/bin/bash
# =============================================================================
# Two capture stacks over ONE root, end to end, with real processes (§8.3.2).
#
#   ./testfiles/vt-twostack-test.sh
#
# The unit test (vt-multiwriter-test.q) proves the logic; this proves the wiring,
# which is where every fault in this feature has actually been - a guard that
# looks installed and does nothing. It asserts the two failures a shared root
# introduces, both of which are silent:
#
#   the pre-replay delete removing the other writer's day on a restart
#   a writer binding to the WRONG tickerplant and capturing the other's data
#
# Runs on its own ports (6200/6300) so it does not disturb a dev stack, and
# builds its own config, database and logs under a scratch directory.
#
# It is known to catch the real thing: run once with the two multiwriter flags
# landing in the wrong namespace, it reported the restart taking stack 1 from
# 216 rows to 120 - the defect itself, not a proxy for it.
# exit 0 pass, 1 fail, 77 skip.
# =============================================================================
set -u
PACK="$(cd "$(dirname "$0")/.." && pwd)"
PASS=0; FAIL=0
ok  () { PASS=$((PASS+1)); echo "  PASS  $1"; }
bad () { FAIL=$((FAIL+1)); echo "  FAIL  $1"; }
skip() { echo "  $1"; exit 77; }

[ -n "${TORQHOME:-}" ] || skip "TORQHOME is not set - source setenv.sh first"
[ -f "$TORQHOME/torq.sh" ] || skip "no torq.sh under TORQHOME=$TORQHOME"
command -v q >/dev/null || skip "q is not on PATH"
for p in 6200 6205 6230 6300 6305 6330; do
  (exec 3<>/dev/tcp/localhost/$p) 2>/dev/null && skip "port $p is in use"
done

S=$(mktemp -d /tmp/vt-twostack-XXXX)
DB="$S/db"
cleanup () {
  for n in 1 2; do SETENV="$S/s$n/env.sh" "$TORQHOME/torq.sh" stop all >/dev/null 2>&1; done
  sleep 1; rm -rf "$S"
}
trap cleanup EXIT

UK='`BARC`HSBA`LLOY`NWG`STAN`VOD`BP`SHEL`GSK`AZN'

# --- one config tree per stack, sharing KDBDB ---------------------------------
for n in 1 2; do
  base=$((6100 + n*100))                                  # 6200, 6300
  cfg="$S/s$n/appconfig"
  mkdir -p "$cfg/settings" "$S/s$n/logs" "$S/s$n/tplogs" "$DB"
  cp -r "$PACK/appconfig/settings/." "$cfg/settings/"
  cp -r "$PACK/appconfig/passwords" "$cfg/" 2>/dev/null
  cp "$PACK/appconfig/sort.csv" "$PACK/appconfig/compressionconfig.csv" "$cfg/" 2>/dev/null

  # every writer on a shared root scopes its delete; every reader guards the live partition.
  # NOTE the namespace is stated: both settings files end inside \d .proc, so a bare append
  # would set .proc.multiwriter and the override would never install
  printf '\n\\d .wdb\nmultiwriter:1b\n\\d .\n'   >> "$cfg/settings/wdb.q"
  printf '\n\\d .vtidb\nmultiwriter:1b\n\\d .\n' >> "$cfg/settings/idb.q"
  # the process file is the only wiring: no discovery in this topology
  printf '\n\\d .servers\nCONNECTIONSFROMDISCOVERY:0b\nDISCOVERYREGISTER:0b\n\\d .\n' >> "$cfg/settings/default.q"
  # disjoint universes, or the same (date;instrument) is served twice (§8.3.1)
  [ "$n" = 2 ] && printf '\n\\d .\nsyms:%s\n' "$UK" >> "$cfg/settings/feed.q"

  # both writers and both readers; only THIS stack's tickerplant
  cat > "$cfg/process.csv" <<CSV
host,port,proctype,procname,U,localtime,g,T,w,load,startwithall,extras,qcmd
localhost,$base,segmentedtickerplant,stp$n,\${KDBAPPCONFIG}/passwords/accesslist.txt,1,0,,,\${KDBCODE}/processes/segmentedtickerplant.q,1,-schemafile $PACK/database.q -tplogdir \${KDBTPLOG},q
localhost,$((base+5)),wdb,wdb$n,\${KDBAPPCONFIG}/passwords/accesslist.txt,1,1,,,\${KDBCODE}/processes/wdb.q,1,,q
localhost,6205,wdb,wdb1,\${KDBAPPCONFIG}/passwords/accesslist.txt,1,1,,,\${KDBCODE}/processes/wdb.q,0,,q
localhost,6305,wdb,wdb2,\${KDBAPPCONFIG}/passwords/accesslist.txt,1,1,,,\${KDBCODE}/processes/wdb.q,0,,q
localhost,$((base+30)),idb,idb$n,\${KDBAPPCONFIG}/passwords/accesslist.txt,1,1,60,4000,\${KDBAPPCODE}/processes/vtidb.q,1,-s 4,q
localhost,6230,idb,idb1,\${KDBAPPCONFIG}/passwords/accesslist.txt,1,1,60,4000,\${KDBAPPCODE}/processes/vtidb.q,0,-s 4,q
localhost,6330,idb,idb2,\${KDBAPPCONFIG}/passwords/accesslist.txt,1,1,60,4000,\${KDBAPPCODE}/processes/vtidb.q,0,-s 4,q
localhost,$((base+14)),feed,feed$n,,1,0,,,\${KDBAPPCODE}/tick/feed.q,1,,q
CSV
  # the duplicate row for this stack's own writer/reader is dropped: keep the first
  awk -F, '!seen[$4]++' "$cfg/process.csv" > "$cfg/process.csv.tmp" && mv "$cfg/process.csv.tmp" "$cfg/process.csv"

  cat > "$S/s$n/env.sh" <<ENV
export TORQHOME="$TORQHOME"
export TORQAPPHOME="$PACK"
export KDBCONFIG="\$TORQHOME/config"; export KDBCODE="\$TORQHOME/code"
export KDBLIB="\$TORQHOME/lib";       export KDBHTML="\$TORQHOME/html"
export KDBAPPCODE="$PACK/code";       export KDBAPPCONFIG="$cfg"
export TORQPROCESSES="$cfg/process.csv"
export KDBDB="$DB"; export KDBWDB="$DB"; export KDBHDB="$DB"
export KDBLOG="$S/s$n/logs"; export KDBTPLOG="$S/s$n/tplogs"
export QHOME="${QHOME:-$HOME/.kx/q}"; export QLIC="${QLIC:-$HOME/.kx}"; export QPATH="${QPATH:-$HOME/.kx/mod}"
export QCMD=q; export KDBBASEPORT=$base
ENV
done

# --- run ----------------------------------------------------------------------
for n in 1 2; do SETENV="$S/s$n/env.sh" "$TORQHOME/torq.sh" start all >/dev/null 2>&1; sleep 6; done
sleep 14

qq () { q "$S/query.q" -q -port "$1" -expr "$2" 2>/dev/null; }
cat > "$S/query.q" <<'QEOF'
o:.Q.opt .z.x;
h:@[hopen;(`$":localhost:",first[o`port],":admin:admin";5000);0Ni];
$[null h; -1 "NOCONN"; -1 .Q.s1 @[h;first o`expr;{[e] `$"ERR: ",e}]];
exit 0;
QEOF

us=$(qq 6230 'count select from trade where sym in `AMD`AIG`AAPL`DELL`DOW`GOOG`HPQ`INTC`IBM`MSFT')
uk=$(qq 6230 "count select from trade where sym in $UK")
[ "$us" -gt 0 ] 2>/dev/null && ok "stack 1's instruments are captured ($us rows)" \
                             || bad "stack 1 captured nothing (got '$us')"
[ "$uk" -gt 0 ] 2>/dev/null && ok "stack 2's instruments are captured ($uk rows)" \
                             || bad "stack 2 captured nothing (got '$uk') - did wdb2 bind to the wrong tickerplant?"

dups=$(qq 6230 'count select from (select n:count i by date,sym from trade) where n=0')
own=$(ls "$DB/.vtowner" 2>/dev/null | wc -l)
[ "$own" -eq 2 ] && ok "both writers wrote an ownership manifest" \
                 || bad "expected 2 ownership manifests, found $own"

# --- the headline defect: restart one writer, the other's data must survive ----
before_us=$us
SETENV="$S/s2/env.sh" "$TORQHOME/torq.sh" stop wdb2 >/dev/null 2>&1; sleep 2
SETENV="$S/s2/env.sh" "$TORQHOME/torq.sh" start wdb2 >/dev/null 2>&1; sleep 12

after_us=$(qq 6230 'count select from trade where sym in `AMD`AIG`AAPL`DELL`DOW`GOOG`HPQ`INTC`IBM`MSFT')
after_uk=$(qq 6230 "count select from trade where sym in $UK")
if [ "$after_us" -ge "$before_us" ] 2>/dev/null; then
  ok "restarting wdb2 left stack 1's data intact ($before_us -> $after_us rows)"
else
  bad "restarting wdb2 DESTROYED stack 1 data ($before_us -> $after_us rows)"
fi
[ "$after_uk" -gt 0 ] 2>/dev/null && ok "stack 2 recovered its own data after the restart ($after_uk rows)" \
                                   || bad "stack 2 lost its own data on restart (got '$after_uk')"

scoped=$(grep -lh 'scoped delete' "$S/s2/logs"/out_wdb2*.log 2>/dev/null | wc -l)
[ "$scoped" -ge 1 ] && ok "the scoped delete ran on the restart" \
                    || bad "no scoped delete in wdb2's log - the override did not install"

echo ""
echo "  $PASS passed, $FAIL failed"
echo ""
[ "$FAIL" -eq 0 ]
