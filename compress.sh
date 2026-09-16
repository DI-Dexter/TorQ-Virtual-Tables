#!/bin/bash
# Run the weekend compression job over the capture tree, then exit.
#
#   ./compress.sh              compress everything older than minage (compressionconfig.csv)
#   ./compress.sh --dry-run    list what would be compressed, change nothing
#   ./compress.sh --test       compress underneath the running reader and verify it copes
#
# Two gates decide what gets touched, and both are deliberate (see §7.3 of the doc):
#   age tier   minage in appconfig/compressionconfig.csv - recent data stays uncompressed so
#              interactive queries run at full speed. also keeps the job off the live partition
#   size gate  .cmp.minfilesize in appconfig/settings/compression.q - a column file that fits
#              in one filesystem block frees nothing when compressed, so it is skipped
#
# Cron it for a quiet period, e.g. Saturday 02:00:
#   0 2 * * 6  /path/to/TorQ-VT-Capture-Pack/compress.sh

set -e
. "$(cd "$(dirname "$0")" && pwd)/setenv.sh"

if [ ! -f "${TORQHOME}/torq.q" ]; then
  echo "ERROR: no torq.q under TORQHOME=${TORQHOME}" >&2
  exit 1
fi

# NOTE this runs in the FOREGROUND and tees its output, which is why it invokes q
# directly rather than going through torq.sh (which backgrounds via nohup).
cd "$TORQHOME"
ACL="${KDBAPPCONFIG}/passwords/accesslist.txt"

if [ "$1" = "--test" ]; then
  # VT-15: compress with the reader live, and check it never notices. uses the test config,
  # whose age tier is 1 day, so it has something to work on in a database a few days old
  export VTCMP_CONFIG="${TORQAPPHOME}/testfiles/compressionconfig-test.csv"
  exec q "${TORQAPPHOME}/testfiles/vt-compress-test.q" </dev/null
fi

if [ "$1" = "--dry-run" ]; then
  echo "dry run: scanning ${KDBDB}"
  q torq.q -load "${KDBAPPCODE}/processes/vtcompress.q" -stackid "$KDBBASEPORT" \
    -proctype compression -procname cmp1 -U "$ACL" -localtime -dryrun 1 </dev/null
  exit 0
fi

echo "compressing ${KDBDB}"
q torq.q -load "${KDBAPPCODE}/processes/vtcompress.q" -stackid "$KDBBASEPORT" \
  -proctype compression -procname cmp1 -U "$ACL" -localtime \
  </dev/null 2>&1 | tee "${KDBLOG}/cmp1.console.log"

echo ""
echo "done. per-file detail was written to ${KDBLOG}/cmp1.console.log"
