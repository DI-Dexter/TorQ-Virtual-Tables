#!/bin/bash
# Regression runner for testfiles/.
#
#   ./regress.sh              every test the environment allows
#   ./regress.sh --quick      self-contained tests only, never touches a running stack
#   ./regress.sh -v           stream each test's output instead of summarising
#   ./regress.sh --no-mutate  skip the one test that rewrites files in var/db
#
# Tests come in two kinds. SELF-CONTAINED ones build their own database in a scratch
# directory and clean it up; they never touch var/ and are safe to run any time. The rest
# need the stack already up because they publish through the live tickerplant.
#
# ONE TEST MUTATES var/db: vt-compress-test compresses every partition older than a day and
# leaves it compressed. That is what it is for - it checks a live reader copes with files
# being rewritten underneath it - and compression is transparent and idempotent, so nothing
# is lost. But it does change query latency on those partitions. Pass --no-mutate to skip it.
#
# Every test prints "  N passed, M failed" and exits non-zero if anything failed, so this
# script reports both the exit status and the counts.

cd "$(dirname "$0")"
. ./setenv.sh >/dev/null 2>&1

# vt-partition-test loads the real timezone.q and eodtime.q from TorQ core rather than a
# copy of their formula, so the suite needs TORQHOME even though the databases are scratch.
if [ ! -f "${TORQHOME}/torq.q" ]; then
  echo "ERROR: no torq.q under TORQHOME=${TORQHOME}" >&2
  echo "       set TORQHOME to your TorQ checkout, or edit setenv.sh" >&2
  exit 1
fi

TIMEOUT=${TIMEOUT:-300}
IDBPORT=$((${KDBBASEPORT:-6000}+30))        # the idb, per appconfig/process.csv
QUICK=0; VERBOSE=0; NOMUTATE=0
for a in "$@"; do
  case "$a" in
    --quick) QUICK=1 ;;
    --no-mutate) NOMUTATE=1 ;;
    -v|--verbose) VERBOSE=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $a"; exit 2 ;;
  esac
done

SELFCONTAINED="vt-partition-test vt-rollover-test vt-newtable-test vt-restart-test
               vt-inflight-test vt-damage-test vt-multistack-test vt-wdbrestart-test
               vt-compat-test vt-diskfull-test"
NEEDSTACK="vt-replay-test vt-symdomain-test vt-collision-test vt-tprestart-test"

LOGDIR=$(mktemp -d); PASS=0; FAIL=0; SKIP=0; ROWS=""

run () {                                    # run <name> <command...>
  local name=$1; shift
  printf "  %-24s " "$name"
  local log="$LOGDIR/$name.log" rc counts
  if [ "$VERBOSE" = 1 ]; then
    echo ""; timeout -k 10 "$TIMEOUT" "$@" </dev/null 2>&1 | tee "$log"; rc=${PIPESTATUS[0]}
    printf "  %-24s " "$name"
  else
    timeout -k 10 "$TIMEOUT" "$@" </dev/null >"$log" 2>&1; rc=$?
  fi
  counts=$(grep -oE '[0-9]+ passed, [0-9]+ failed' "$log" | tail -1)
  [ -z "$counts" ] && counts="no assertions reported"
  if [ "$rc" = 0 ]; then
    echo "PASS   $counts"; PASS=$((PASS+1))
  elif [ "$rc" = 77 ]; then
    # 77 is the pack's convention for "precondition not met" - the database has no
    # partitions yet, too few instruments, or only one date. That is not a failure:
    # it is a test that cannot run yet, and it must not read as one on a fresh clone.
    echo "SKIP   $(tail -1 "$log" | sed 's/^ *//')"; SKIP=$((SKIP+1))
  elif [ "$rc" = 124 ]; then
    echo "TIMEOUT after ${TIMEOUT}s"; FAIL=$((FAIL+1))
  else
    echo "FAIL   rc=$rc  $counts"; FAIL=$((FAIL+1))
  fi
  ROWS="$ROWS$name|$rc|$counts\n"
}

# For tests whose non-zero exit is expected: pass if the result still matches the recorded
# baseline, fail if it moves. vt-compare-kdb exits 1 because differences exist at all, but
# the three that differ are known and documented - what matters is that it is still three.
run_expect () {                             # run_expect <name> <baseline regex> <command...>
  local name=$1 want=$2; shift 2
  printf "  %-24s " "$name"
  local log="$LOGDIR/$name.log" got
  timeout -k 10 "$TIMEOUT" "$@" </dev/null >"$log" 2>&1
  got=$(grep -oE "$want" "$log" | tail -1)
  if [ -n "$got" ]; then
    echo "PASS   $got (baseline)"; PASS=$((PASS+1)); ROWS="$ROWS$name|0|$got\n"
  else
    echo "FAIL   baseline moved - expected /$want/"; FAIL=$((FAIL+1)); ROWS="$ROWS$name|1|baseline moved\n"
  fi
}

echo ""
echo "regression run - $(date '+%Y-%m-%d %H:%M:%S')"
echo "  timeout per test : ${TIMEOUT}s"
echo "  logs             : $LOGDIR"
echo ""
echo "self-contained (build their own database, safe any time)"
for t in $SELFCONTAINED; do run "$t" q "testfiles/$t.q"; done

echo ""
if [ "$QUICK" = 1 ]; then
  echo "stack tests skipped (--quick)"
  # ADD to SKIP - self-contained tests may already have skipped on rc=77
  SKIP=$((SKIP + $(echo $NEEDSTACK | wc -w) + 2))       # +vt-compress-test +vt-compare-kdb
elif (ss -ltn 2>/dev/null || netstat -ltn 2>/dev/null) | grep -qE ":${IDBPORT}\b"; then
  echo "against the running stack"
  for t in $NEEDSTACK; do run "$t" q "testfiles/$t.q"; done
  # must go through its wrapper: --test swaps in the 1-day age tier, without which
  # nothing in a few-days-old database is in scope and the test has nothing to compress
  if [ "$NOMUTATE" = 1 ]; then
    printf "  %-24s SKIP   --no-mutate\n" "vt-compress-test"; SKIP=$((SKIP+1))
  else
    echo "  (vt-compress-test compresses partitions older than a day in var/db, and leaves them so)"
    run vt-compress-test ./compress.sh --test
  fi
  run_expect vt-compare-kdb '16 matched, 3 differed' ./testfiles/vt-compare-kdb.sh
else
  echo "stack tests skipped - nothing listening on ${IDBPORT}. Run torq.sh start all first."
  # ADD to SKIP - self-contained tests may already have skipped on rc=77
  SKIP=$((SKIP + $(echo $NEEDSTACK | wc -w) + 2))       # +vt-compress-test +vt-compare-kdb
fi

echo ""
echo "----------------------------------------"
printf "  %d passed, %d failed" "$PASS" "$FAIL"
[ "$SKIP" -gt 0 ] && printf ", %d skipped" "$SKIP"
echo ""
echo "----------------------------------------"
if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "failures:"
  echo -e "$ROWS" | awk -F'|' -v L="$LOGDIR" '$2!="0" && $1!="" {print "  "$1"  (rc="$2")  "L"/"$1".log"}'
  echo ""
  exit 1
fi
rm -rf "$LOGDIR"
echo ""
