# TorQ Virtual-Table Capture Pack

An application overlay for [TorQ](https://github.com/DataIntellectTech/TorQ) that captures
data partitioned by **date and instrument**, and serves it through kdb-x virtual tables.

There is no RDB, no HDB, no gateway and no sort process. The writer writes where the readers
read, and nothing moves at end of day.

## Why

A normal kdb+ stack partitions by date and applies a `p#` attribute to `sym` overnight so
that selective lookups are fast. That attribute cannot be maintained on a partition being
appended to, so the live day is always un-indexed and a query like ``where sym=`AMD``
scans it.

This pack makes the instrument a *directory* instead. A selective lookup becomes a directory
lookup rather than a scan, it needs no index, and there is nothing to rebuild at end of day.

See `docs/virtual-table-capture-pack.md` — start with §0, which lists each design decision
alongside the alternative that was tried and rejected.

## Requirements

- A TorQ checkout (5.2.x)
- kdb-x, with the `kx.pq.t` virtual-table module on `QPATH`. Not kdb+ 4.x: the reader
  binds `mkP` with ``use`kx.pq.t``, and `use` is a kdb-x keyword

## Setup

Point `TORQHOME` at your TorQ checkout, either in the environment:

```sh
export TORQHOME=/path/to/TorQ
```

or by filling in the one line in `vt-env.sh` that is deliberately left empty:

```sh
export TORQHOME="${TORQHOME:-}"          # -> ${TORQHOME:-/path/to/TorQ}
```

Everything else derives from that and from the location of the pack, so it can be cloned
anywhere. `QHOME`, `QLIC` and `QPATH` are defaulted to the usual kdb-x locations under
`~/.kx` and can be overridden the same way.

## Run

```sh
./start.sh          # discovery + tickerplant + WDB + IDB + feed
./stop.sh
```

Compression is a separate, occasional job — it exits when it finishes, so cron it for a quiet
window rather than running it under the stack. Two gates decide what it touches: an age tier
(`minage` in `appconfig/compressionconfig.csv`, 7 days) so recent data stays uncompressed and
fast to query, and a size gate (`.cmp.minfilesize` in `appconfig/settings/compression.q`) that
skips column files too small to free a filesystem block:

```sh
./compress.sh --dry-run    # what it would touch, and the ceiling on what it can free
./compress.sh              # compress everything older than minage
```

Then watch it work:

```sh
find var/db -mindepth 3 -maxdepth 3 -type d | head
tail -f var/logs/out_wdb1.log
```

And query it:

```q
h:hopen `::6030:idb:pass
h"select n:count i by sym from trade"
h"select from trade where sym=`AMD, date=.vtidb.current"
```

The partition column is exposed under the name in `partitioncol` (`appconfig/settings/idb.q`),
set here to `sym` so queries read the same as against a conventional database.

`.vtidb.current` is the partition the writer is filling. Prefer it to `.z.D` in examples:
if `rolltimeoffset` is set, the business day ends somewhere other than midnight and the two
disagree for part of every day.

Ask twice a few seconds apart and the counts move. Nothing was reloaded — each partition is
opened as a live view, so rows the writer appends are visible immediately.

## Self test

```sh
./selftest.sh
```

Publishes a brand new instrument to the tickerplant and checks it travels the whole chain:
the writer creates a partition directory, notifies, the reader rebuilds, the rows come back
through the virtual table, the partition column is *not* in the files, and plain appends need
no rebuild. Exits non-zero on failure, so it can be wired into a smoke test.

## Regression

```sh
./regress.sh                # every test the environment allows
./regress.sh --quick        # self-contained tests only
./regress.sh --no-mutate    # skip the one test that rewrites files in var/db
```

Runs the sixteen assertion tests in `testfiles/` and summarises them. Ten work in a scratch
directory and never write to `var/db`, so they are safe to run at any time — though four of
them seed that scratch copy from a partition in `var/db`, and one loads TorQ's `timezone.q`
and `eodtime.q`, so the stack needs to have run at least once and `TORQHOME` must be set. The
other six need the stack up, and are skipped with a note if nothing is listening on the IDB
port (`KDBBASEPORT`+30, so 6030 by default). Exits non-zero if any test fails, and prints the
log path for each failure.

A test that *cannot run yet* exits **77** and is reported as `SKIP` rather than `FAIL`: the
database has no partitions, too few instruments, or only one date. On a clone whose stack has
been up for a few minutes that is the expected state of `vt-compress-test`, which needs the
stack to have crossed a day boundary. Anything reported as `FAIL` is a real failure.

Two of them need explaining. `vt-compress-test` goes through `./compress.sh --test`, which
swaps in a 1-day age tier — and it leaves those partitions compressed, which is the one thing
in the suite that changes `var/db`. Re-running is still safe: `vt-damage-test` copies a
partition and truncates a column in it, and a compressed column raises where an uncompressed
one short-reads, so it forces its copy back to uncompressed first and asserts the same thing
on every run. `vt-compare-kdb` is checked against a recorded baseline of
**16 matched, 3 differed** rather than its exit code, because it exits non-zero whenever any
difference exists and three are expected (see §9 of the doc).

## Layout

```
vt-env.sh                  the only file to edit: TORQHOME, then everything derives
start.sh / stop.sh         bring the stack up and down. stop.sh is scoped by path, so it
                           leaves other TorQ stacks on the machine alone even though they
                           share the default procnames
selftest.sh                end-to-end smoke test (code/selftest.q)
regress.sh                 runs the sixteen assertion tests in testfiles/
loadtest.sh                throughput run on a clean stack (code/loadtest.q). DESTRUCTIVE:
                           it does rm -rf var to start from a known state, so run it on a
                           throwaway copy unless you mean to lose the database
compress.sh                the weekend compression job; --dry-run and --test
database.q                 the schema the tickerplant loads

appconfig/
  process.csv              the process list
  sort.csv                 declares the partition column (sym)
  compressionconfig.csv    the age tier: how old a partition must be before compression
  compressionconfig-test.csv  a 1-day copy, used by ./compress.sh --test
  passwords/               accesslist.txt and feed.txt - the stock TorQ demo credentials
  settings/default.q       settings shared by every process
  settings/wdb.q           WDB config, including symdomain (see §8.3.1 for multi-stack)
  settings/idb.q           IDB config
  settings/compression.q   the size gate (.cmp.minfilesize)
  settings/feed.q          demo feed config
  settings/segmentedtickerplant.q

code/
  wdb/vtwrite.q            the writer overrides this design needs (see §4 of the doc)
  processes/vtidb.q        the IDB reader (see §5 of the doc)
  processes/vtcompress.q   the compression job (see §7 of the doc)
  processes/vtcompress-report.q  the --dry-run report, loaded by vtcompress.q
  tick/feed.q              demo feed, FSP trade/quote generator
  tick/loadfeed.q          the load-test feed: no timers, driven as fast as it will go
  selftest.q               the end-to-end check run by ./selftest.sh
  loadtest.q               the load driver and measurement run by ./loadtest.sh

docs/                      the architecture document and the status report
testfiles/                 tests and evidence scripts - see below
var/                       created at runtime: db/, logs/, tplogs/
```

`testfiles/` holds two different kinds of script, and only the first kind asserts:

```
assertions (16)            run by ./regress.sh, each exits non-zero on failure
  self-contained (10)      vt-partition vt-rollover vt-newtable vt-restart vt-inflight
                           vt-damage vt-multistack vt-wdbrestart vt-compat vt-diskfull
  need the stack (4)       vt-replay vt-symdomain vt-collision vt-tprestart
  special (2)              vt-compress-test (via ./compress.sh --test)
                           vt-compare-kdb.sh (drives vt-kdb-prep.q and vt-kdb-compare.q)

evidence (9)               measurements and probes, read for their output, not pass/fail
  vt-compress-ab           before/after on the same partition
  vt-compress-ratio        compression ratio by column
  vt-compress-sizes        file-size distribution against the filesystem block
  vt-scale-test            partition count against mapping cost
  vt-sym-concurrency       two writers against one sym file
  vt-gap-test              what a missing partition directory actually does
  vt-limitations           what virtual tables do not support
  vt-probe                 an annotated tour of the on-disk structures
  vt-sample-legacy         the legacy single-directory sample, kept for comparison
```

`var/db` is the whole database — live and historical data in one directory.

## What is on disk

```
var/db/
  sym
  2026.08.17/
    trade/
      AMD/    time price size stop cond ex side
      AAPL/   time price size stop cond ex side
    quote/
      AMD/    time bid ask bsize asize mode ex src
```

Note that `sym` is **not** among the columns. It is carried by the directory name.
That is deliberate and load-bearing: a column stored inside the files can never be used to
skip directories, so leaving it in would make every query on it scan the whole database.

## Evidence

The scripts under `testfiles/` are runnable and reproduce the findings behind the design:

```sh
q testfiles/vt-probe.q            # how the query engine routes conditions
q testfiles/vt-limitations.q      # what works and what does not, presentable output
q testfiles/vt-sample-legacy.q    # attaching an existing date-partitioned HDB
q testfiles/vt-compress-ratio.q   # where compression's saving lands, by original file size
q testfiles/vt-compress-sizes.q   # how that saving scales with rows per instrument per day
q testfiles/vt-compress-ab.q      # uncompressed vs gated vs ungated: disk and latency
q testfiles/vt-rollover-test.q    # end of day keeps the date it just closed, without rescanning
q testfiles/vt-multistack-test.q  # one reader over two capture stacks, all domain configurations
q testfiles/vt-replay-test.q      # the overrides are in force during tickerplant log replay
q testfiles/vt-symdomain-test.q   # rows arrive live; a new symbol value resolves within seconds
q testfiles/vt-collision-test.q   # two instruments sharing a sanitised directory name
q testfiles/vt-damage-test.q      # truncated / .d-less / corrupt partitions, and the blast radius
q testfiles/vt-newtable-test.q    # a table appearing mid-life
q testfiles/vt-tprestart-test.q   # liveness: subscribed, growing, no cached feed handle
q testfiles/vt-wdbrestart-test.q  # the writer deletes the live partition, then replays it back
q testfiles/vt-restart-test.q     # a reader restarting mid-flush, and where it takes the live date from
q testfiles/vt-inflight-test.q    # querying a partition while it is being written
q testfiles/vt-diskfull-test.q    # ENOSPC: what survives, what duplicates, what fails loudly
q testfiles/vt-partition-test.q   # the partition column is in the name, not the files
q testfiles/vt-compat-test.q      # 38 client operations: direct, wrapped, or unreachable
q testfiles/vt-scale-test.q       # rebuild and query cost against partition count
q testfiles/vt-gap-test.q         # a table missing a date the others have
q testfiles/vt-sym-concurrency.q  # concurrent enumeration against one shared domain file
./testfiles/vt-compare-kdb.sh     # same bytes, two databases: this layout vs stock kdb+
./compress.sh --test         # compression underneath a live reader: ratio and read cost
```

## Status

The capture layer, the reader, compression, end of day and multi-stack read are built and
verified end to end: a new instrument published to the tickerplant is queryable through the
IDB 2 ms later, and the writer's appends need no reload at all.

Results are checked against the same bytes loaded into a stock kdb+ database: **16 of 19
queries identical, three raise an error, none silently different**
(`testfiles/vt-compare-kdb.sh`). Memory mappings are not a limit — the reader opens partitions
with a trailing slash, which does not memory-map, so the count stays flat however much history
is attached (§8.2).

One item remains open and cannot be resolved inside the pack: a single virtual table cannot
span both the new format and existing date-partitioned history, because the column list is
taken from the first directory only. See §10 of the architecture document, and
`docs/status-report.md` for the ticket-level state.
