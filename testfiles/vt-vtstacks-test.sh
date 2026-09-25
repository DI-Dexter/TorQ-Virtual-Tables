#!/bin/bash
# =============================================================================
# The generated topology: VTSTACKS=n capture stacks on n roots, VTIDBS=m readers (§8.3).
#
#   ./testfiles/vt-vtstacks-test.sh
#
# vt-livepart-test.q proves the reader's guard in isolation; this proves the WIRING, which
# is where every fault in this feature has actually been - a guard that looks installed and
# does nothing. It asserts, with real processes:
#
#   the generator emits the right processes, ports and flags for several shapes
#   each writer owns its OWN root, with its OWN enumeration domain
#   each writer binds to its OWN tickerplant - a lookup by process type takes whichever is
#     found first, so a writer can capture another stack's instruments and still look healthy
#   the feeds' universes are disjoint, which is what keeps one instrument from being
#     captured twice and served twice with no error anywhere
#   one reader answers for every root
#
#   KEEP=1 ./testfiles/vt-vtstacks-test.sh     leave the stacks up for inspection
#
# Runs at KDBBASEPORT=6400 and under its own TORQDATAHOME, so it does not disturb a dev stack.
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
for p in $BASE $((BASE+5)) $((BASE+30)) $((BASE+100)) $((BASE+105)); do
  (exec 3<>/dev/tcp/localhost/$p) 2>/dev/null && skip "port $p is in use"
done

S=$(mktemp -d /tmp/vt-vtstacks-XXXX)
TORQ () { env TORQDATAHOME="$S/run" KDBBASEPORT=$BASE VTSTACKS=2 VTIDBS=1 \
              SETENV="$PACK/setenv.sh" "$TORQHOME/torq.sh" "$@"; }
cleanup () {
  if [ "${KEEP:-0}" = 1 ]; then
    echo ""; echo "  KEEP=1: left running, data and logs under $S/run"
    echo "  stop with: TORQDATAHOME=$S/run KDBBASEPORT=$BASE SETENV=$PACK/setenv.sh \$TORQHOME/torq.sh stop all; rm -rf $S"
    return
  fi
  TORQ stop all >/dev/null 2>&1; sleep 1; rm -rf "$S"
}
trap cleanup EXIT

# --- the generator, before anything is started --------------------------------
# Each probe gets its OWN TORQDATAHOME, because sourcing setenv.sh records the choice there
# and a probe sharing a directory with the one before it would read that back and prove nothing.
gen () {                                    # gen <stacks> <idbs> <dir>  -> prints the file path
  env VTSTACKS="$1" VTIDBS="$2" TORQHOME="$TORQHOME" TORQDATAHOME="$3" \
      bash -c ". $PACK/setenv.sh >/dev/null 2>&1; echo \$TORQPROCESSES"
}
names () { awk -F, 'NR>1{printf "%s ", $4}' "$1"; }

f=$(gen 1 1 "$S/p11")
[ "$(basename "$f")" = "process.csv" ] && ok "1x1 uses the shipped process.csv, ungenerated" \
                                       || bad "1x1 used $(basename "$f")"

f=$(gen 2 1 "$S/p21")
[ "$(names "$f")" = "discovery1 stp1 wdb1 feed1 stp2 wdb2 feed2 idb1 cmp1 " ] \
  && ok "2x1 generates two full stacks and one reader" \
  || bad "2x1 generated: $(names "$f")"

f=$(gen 3 2 "$S/p32")
[ "$(names "$f")" = "discovery1 stp1 wdb1 feed1 stp2 wdb2 feed2 stp3 wdb3 feed3 idb1 idb2 cmp1 " ] \
  && ok "3x2 generates three stacks and two readers" \
  || bad "3x2 generated: $(names "$f")"

f=$(gen 1 3 "$S/p13")
[ "$(names "$f")" = "discovery1 stp1 wdb1 feed1 idb1 idb2 idb3 cmp1 " ] \
  && ok "1x3 generates one stack and three readers" \
  || bad "1x3 generated: $(names "$f")"

# a single stack must stay on the stock root and the stock domain, so a 1-stack tree is
# exactly what Part 1 laid down - no savedir, hdbdir or symdomain overrides at all
f=$(gen 1 3 "$S/p13b")
grep -q "savedir\|symdomain" "$f" && bad "a single stack was given root overrides it does not need" \
                                 || ok "a single stack keeps the stock root and domain"

# savedir and hdbdir must ALWAYS travel together - hdbdir is what .Q.en writes the
# enumeration file to, and overriding only savedir strands every root without a sym file
f=$(gen 2 1 "$S/p21b")
w=$(grep -c ".wdb.savedir" "$f"); h=$(grep -c ".wdb.hdbdir" "$f")
[ "$w" = 2 ] && [ "$h" = 2 ] && ok "every writer gets savedir AND hdbdir, never one alone" \
                             || bad "savedir on $w writers, hdbdir on $h"

# distinct domain per root - two roots calling theirs the same name cannot be read together
f=$(gen 3 1 "$S/p31")
d=$(grep -o "symdomain sym[0-9]*" "$f" | sort -u | wc -l)
[ "$d" = 3 ] && ok "each root gets its own enumeration domain" || bad "$d distinct domains for 3 roots"

# the readers must attach EVERY root, and carry the live-partition guard
r=$(grep -o "\-.vtidb.roots[^,]*" "$f" | head -1 | grep -o ":" | wc -l)
[ "$r" = 3 ] && ok "readers attach every root" || bad "a reader attached $r roots, expected 3"
grep -q ".vtidb.multiwriter 1" "$f" && ok "readers carry the live-partition guard" \
                                    || bad "no .vtidb.multiwriter with several writers"

# remembered, so a later stop all does not orphan half the estate
gen 2 2 "$S/rem" >/dev/null
f=$(env -u VTSTACKS -u VTIDBS TORQHOME="$TORQHOME" TORQDATAHOME="$S/rem" \
        bash -c ". $PACK/setenv.sh >/dev/null 2>&1; echo \$TORQPROCESSES")
[ "$(names "$f")" = "discovery1 stp1 wdb1 feed1 stp2 wdb2 feed2 idb1 idb2 cmp1 " ] \
  && ok "the shape is remembered when the variables are not passed again" \
  || bad "not remembered - a later stop all would orphan processes"

# --- start it for real --------------------------------------------------------
TORQ start all >/dev/null 2>&1
sleep 20

upn=$(TORQ summary 2>/dev/null | grep -c "|  up  ")
[ "$upn" -eq 8 ] && ok "all 8 processes are up" || bad "expected 8 up, torq.sh summary reports $upn"

for n in 1 2; do
  grep -q "subscribing only to tickerplant \`stp$n" "$S/run/logs/out_wdb$n.log" 2>/dev/null \
    && ok "wdb$n installed the tickerplant pin" \
    || bad "wdb$n did not pin its tickerplant - the override did not reach it"
  grep -q "tickerplant found - subscribing to stp$n" "$S/run/logs/out_wdb$n.log" 2>/dev/null \
    && ok "wdb$n subscribed to stp$n" \
    || bad "wdb$n subscribed to the WRONG tickerplant: $(grep -o 'subscribing to stp[0-9]' "$S/run/logs/out_wdb$n.log" | tail -1)"
done

# each root holds its own domain file and nothing else's
for n in 1 2; do
  [ -f "$S/run/db$n/sym$n" ] && ok "db$n holds its own enumeration domain sym$n" \
                             || bad "no sym$n at db$n - .Q.en wrote somewhere else"
done
[ -e "$S/run/db" ] && bad "a stray default root was created - hdbdir was left behind" \
                   || ok "no stray default root"

# the two universes must be disjoint, or one instrument is captured twice and served twice
cat > "$S/u.q" <<'QEOF'
h:hopen`$":localhost:",(first .Q.opt[.z.x]`port),":idb:pass";
a:asc h"key hsym`$\"",(first .Q.opt[.z.x]`d1),"\"";
b:asc h"key hsym`$\"",(first .Q.opt[.z.x]`d2),"\"";
a:a except `$string 2000.01.01+til 40000; b:b except `$string 2000.01.01+til 40000;
-1 "|" sv (" " sv string a;" " sv string b);
exit 0;
QEOF
u=$(q "$S/u.q" -q -port $((BASE+30)) -d1 "$S/run/db1/$(ls $S/run/db1 | grep '^[0-9]' | tail -1)/trade" \
                                     -d2 "$S/run/db2/$(ls $S/run/db2 | grep '^[0-9]' | tail -1)/trade" 2>/dev/null)
u1=$(echo "$u" | cut -d'|' -f1); u2=$(echo "$u" | cut -d'|' -f2)
both=$(echo "$u1 $u2" | tr ' ' '\n' | sort | uniq -d | tr -d '[:space:]')
[ -n "$u1" ] && [ -n "$u2" ] && [ -z "$both" ] \
  && ok "the two stacks captured disjoint instrument sets" \
  || bad "captured by both stacks: '$both' (u1='$u1' u2='$u2')"

# one reader answers for everything
cat > "$S/r.q" <<'QEOF'
h:hopen`$":localhost:",(first .Q.opt[.z.x]`port),":idb:pass";
-1 "|" sv string (count h".vtidb.roots"; h"count select from trade"; h"count select distinct sym from trade");
exit 0;
QEOF
r=$(q "$S/r.q" -q -port $((BASE+30)) 2>/dev/null)
[ "$(echo "$r" | cut -d'|' -f1)" = 2 ] && ok "the reader attached both roots" \
                                       || bad "the reader attached $(echo "$r" | cut -d'|' -f1) roots"
[ "$(echo "$r" | cut -d'|' -f2)" -gt 0 ] 2>/dev/null && ok "the reader is serving rows from both roots" \
                                                     || bad "the reader returned no rows"
# compare against what is actually on disk, not a fixed 20: an instrument gets a directory
# when it first trades, so a short run may not have reached every one of them yet. What must
# hold is that the reader sees ALL of them, from both roots, and no more.
ondisk=$(cat <(ls "$S/run/db1/$(ls $S/run/db1 | grep '^[0-9]' | tail -1)/trade") \
             <(ls "$S/run/db2/$(ls $S/run/db2 | grep '^[0-9]' | tail -1)/trade") | sort -u | wc -l)
[ "$(echo "$r" | cut -d'|' -f3)" = "$ondisk" ] \
  && ok "the reader sees every instrument on both roots ($ondisk of 20 traded so far)" \
  || bad "the reader sees $(echo "$r" | cut -d'|' -f3) instruments, $ondisk are on disk"

echo ""
echo "  $PASS passed, $FAIL failed"
echo ""
exit $([ "$FAIL" -gt 0 ] && echo 1 || echo 0)
