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

## Set Up

Assuming that the community edition of [KDB-X](https://code.kx.com/kdb-x/get_started/kdb-x-install.html)
is already set up and available from the command prompt as `q`, then:

1. Download the install script in the directory where you want the pack to be installed using:

    `wget https://raw.githubusercontent.com/DataIntellectTech/TorQ-Virtual-Tables/main/installlatest.sh`

2. Run it. It downloads the latest TorQ release and this pack, and lays them out the way
   `installtorqapp.sh` does for any TorQ application, under `deploy/`:

    `bash installlatest.sh`

3. Run `torq.sh` in the bin directory with the command line argument `start all`:

    `./deploy/bin/torq.sh start all`

Use an empty directory, and stop any other TorQ stack first — see below. The pack needs the
`kx.pq.t` virtual-table module that ships with KDB-X.

### Installation details

**Install into an empty directory.** `deploy/` is created relative to wherever the script runs,
and if one is already there — an existing Finance Starter Pack install, say — it is treated as an
upgrade: `TorQ/latest` and `TorQApp/latest` are repointed at the new install and `bin/setenv.sh` is
overwritten. The other application stops being the one `deploy/bin/torq.sh` starts, and anything
whose `TORQHOME` follows `TorQ/latest` silently moves to a different TorQ version. The previous
versions stay on disk, so it is recoverable, but a fresh directory avoids it entirely:

```sh
mkdir ~/vtpack && cd ~/vtpack
```

**Ports.** This pack and the FSP both use base port 6000, so only one of them can run at a time.
Stop the other stack before starting this one.

**Installing a branch or a fork.** With no release published, `installlatest.sh` takes the tip of
`main`. To try something not yet merged, point it at the repository and branch:

```sh
wget https://raw.githubusercontent.com/<owner>/TorQ-Virtual-Tables/<branch>/installlatest.sh
APP_REPO=<owner>/TorQ-Virtual-Tables bash installlatest.sh --app-ref <branch>
```

Once a release exists, a plain `bash installlatest.sh` installs the latest *release* rather than the
tip of `main`, so work merged after that release is not picked up until the next one is cut.
`--torq-version <x.y.z>` pins TorQ instead of taking its latest release. GitHub caches the raw
script for five minutes, so a push can take that long to reach `wget`.

**Re-running.** Running it again over an existing `deploy/` keeps `deploy/data`, and regenerates
`deploy/bin/setenv.sh`, so edits made there are lost. It extracts over the existing version
directory rather than replacing it, which is `installtorqapp.sh`'s behaviour for every TorQ
application: files deleted upstream are left behind. A release gets a directory of its own, so
this only matters for branch installs — delete `deploy/TorQApp/` first for a clean one.

## Run

As in the FSP, Linux has no wrapper script: `torq.sh` in the bin directory is the interface, and
it builds every start line from `appconfig/process.csv`.

```sh
./deploy/bin/torq.sh start all
./deploy/bin/torq.sh stop all
./deploy/bin/torq.sh summary                # what is running, with PIDs and ports
./deploy/bin/torq.sh start idb1 wdb1        # named processes only
./deploy/bin/torq.sh print all              # the start lines, without running them
./deploy/bin/torq.sh debug idb1             # one process in the foreground
./deploy/bin/torq.sh stop all -force        # kill -9
```

Watch it capture:

```sh
find deploy/data/db -mindepth 3 -maxdepth 3 -type d | head
```

And query it:

```q
h:hopen `::6030:idb:pass
h"select n:count i by sym from trade"
h"select from trade where sym=`AMD, date=.vtidb.current"
```

### Two capture stacks

`VTSTACKS=2` starts a **second** complete capture stack — its own tickerplant, writer, feed and
reader at `{KDBBASEPORT}+100` — writing into the *same* database root as the first. This is the
arrangement described in §8.3.2 of the design doc, and nothing needs editing to get it:

```sh
VTSTACKS=2 ./deploy/bin/torq.sh start all
./deploy/bin/torq.sh summary                 # remembers - all nine processes
./deploy/bin/torq.sh stop all                # stops both stacks
```

The choice is recorded in `$TORQDATAHOME/.vtstacks`, so it only has to be given once. It has to
be remembered rather than re-typed: `torq.sh` only knows about the processes in the file the flag
picks, so a `stop all` that forgot it would leave the second stack running and unmanaged. Set
`VTSTACKS` again to change the answer — `VTSTACKS=1` goes back to one stack and is remembered in
turn. The marker lives with the database, not the install, so two data directories can be running
different topologies at once.

The second stack captures a disjoint instrument universe (`appconfig/settings/feed2.q`). That is
required, not cosmetic: the same `(date;instrument)` written under one root by two writers is
served **twice**, with no error and nothing in any log. Either reader serves both stacks' data.

The partition column is exposed under the name in `partitioncol` (`appconfig/settings/idb.q`),
set here to `sym` so queries read the same as against a conventional database.

`.vtidb.current` is the partition the writer is filling. Prefer it to `.z.D` in examples:
if `rolltimeoffset` is set, the business day ends somewhere other than midnight and the two
disagree for part of every day.

Ask twice a few seconds apart and the counts move. Nothing was reloaded — each partition is
opened as a live view, so rows the writer appends are visible immediately.

## Working from a clone

For development against a TorQ checkout (5.2.x) rather than an installed tree. Point `TORQHOME`
at the checkout, either in the environment:

```sh
export TORQHOME=/path/to/TorQ
```

or by filling in the one line in `setenv.sh` that is deliberately left empty:

```sh
export TORQHOME="${TORQHOME:-}"          # -> ${TORQHOME:-/path/to/TorQ}
```

Everything else derives from that and from the location of the pack. `QHOME`, `QLIC` and
`QPATH` are defaulted to the usual KDB-X locations under `~/.kx` and can be overridden the same
way.

`torq.sh` then has to be told which environment to load. It looks for `setenv.sh` in its own
directory, which for `$TORQHOME/torq.sh` is TorQ core's — and that points at an
`appconfig/process.csv` a TorQ checkout does not have, so every command fails with a
missing-file error:

```sh
export SETENV=$PWD/setenv.sh
$TORQHOME/torq.sh start all
$TORQHOME/torq.sh stop all
```

The data lands in `var/` rather than `deploy/data/`:

```sh
find var/db -mindepth 3 -maxdepth 3 -type d | head
tail -f var/logs/out_wdb1.log
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

## Self test

The test scripts live in the pack itself. From an install, run them from inside it; from a
clone, from the repository root. Either way they find the right TorQ and database on their own.

```sh
cd deploy/TorQApp/latest        # from an install
./selftest.sh
```

Publishes a brand new instrument to the tickerplant and checks it travels the whole chain:
the writer creates a partition directory, notifies, the reader rebuilds, the rows come back
through the virtual table, the partition column is *not* in the files, and plain appends need
no rebuild. Exits non-zero on failure, so it can be wired into a smoke test.

## Regression

```sh
cd deploy/TorQApp/latest    # from an install
./regress.sh                # every test the environment allows
./regress.sh --quick        # self-contained tests only
./regress.sh --no-mutate    # skip the one test that rewrites files in the database
```

The database is `deploy/data/db` in an install and `var/db` in a clone.

Runs the sixteen assertion tests in `testfiles/` and summarises them. Ten work in a scratch
directory and never write to the database, so they are safe to run at any time — though four of
them seed that scratch copy from a partition in the database, and one loads TorQ's `timezone.q`
and `eodtime.q`, so the stack needs to have run at least once and `TORQHOME` must be set. The
other six need the stack up, and are skipped with a note if nothing is listening on the IDB
port (`KDBBASEPORT`+30, so 6030 by default). Exits non-zero if any test fails, and prints the
log path for each failure.

A test that *cannot run yet* exits **77** and is reported as `SKIP` rather than `FAIL`: the
database has no partitions, too few instruments, or only one date. On a fresh install, or a clone
whose stack has been up for a few minutes, that is the expected state of `vt-compress-test`, which needs the
stack to have crossed a day boundary. Anything reported as `FAIL` is a real failure.

Two of them need explaining. `vt-compress-test` goes through `./compress.sh --test`, which
swaps in a 1-day age tier — and it leaves those partitions compressed, which is the one thing
in the suite that changes the database. Re-running is still safe: `vt-damage-test` copies a
partition and truncates a column in it, and a compressed column raises where an uncompressed
one short-reads, so it forces its copy back to uncompressed first and asserts the same thing
on every run. `vt-compare-kdb` is checked against a recorded baseline of
**16 matched, 3 differed** rather than its exit code, because it exits non-zero whenever any
difference exists and three are expected (see §9 of the doc).

## Layout

```
setenv.sh                  the only file to edit: TORQHOME, then everything derives
installlatest.sh           download and unpack the latest TorQ release; --deploy builds
                           a deploy/ tree with installtorqapp.sh, as the FSP does
(no start/stop scripts)   as in the FSP, Linux uses TorQ's own torq.sh. Start lines come
                           from appconfig/process.csv, and torq.sh scopes by
                           -stackid $KDBBASEPORT, so other TorQ stacks on the machine are
                           left alone even though they share the default procnames
selftest.sh                end-to-end smoke test (testfiles/selftest.q)
regress.sh                 runs the assertion tests in testfiles/
loadtest.sh                throughput run on a clean stack (testfiles/loadtest.q). DESTRUCTIVE:
                           it does rm -rf var to start from a known state, so run it on a
                           throwaway copy unless you mean to lose the database
compress.sh                the weekend compression job; --dry-run and --test
database.q                 the schema the tickerplant loads

appconfig/
  process.csv              the process list - one capture stack
  process-2stack.csv       the process list for VTSTACKS=2 - two capture stacks over one
                           root, every port derived from {KDBBASEPORT} (+100 for stack 2)
  sort.csv                 declares the partition column (sym)
  compressionconfig.csv    the age tier: how old a partition must be before compression

  passwords/               accesslist.txt and feed.txt - one entry per proctype this pack
                           runs, plus admin for qcon
  settings/default.q       settings shared by every process
  settings/wdb.q           WDB config, including symdomain (see §8.3.1 for multi-stack)
  settings/idb.q           IDB config
  settings/compression.q   the size gate (.cmp.minfilesize)
  settings/feed.q          demo feed config
  settings/feed2.q         the second stack's instrument universe - loaded only for feed2,
                           which exists only in process-2stack.csv
  settings/segmentedtickerplant.q

code/
  wdb/vtwrite.q            the writer overrides this design needs (see §4 of the doc)
  wdb/vtwritemulti.q       scoped pre-replay delete, for a root shared by two writers (§8.3.2)
  wdb/vttickerplant.q      binds a writer to ONE named tickerplant (§8.3.2)
  processes/vtidb.q        the IDB reader (see §5 of the doc)
  processes/vtcompress.q   the compression job and its --dry-run report (see §7 of the doc)
  tick/feed.q              demo feed, FSP trade/quote generator

docs/                      the architecture document
testfiles/                 tests, evidence scripts and the self and load test drivers - see
                           below. Also compressionconfig-test.csv, the 1-day copy
                           ./compress.sh --test uses
var/                       created at runtime in a clone: db/, logs/, tplogs/. An install
                           uses deploy/data/ instead
```

`testfiles/` holds three kinds of script, and only the first is run by `./regress.sh`:

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

drivers (2)                run by their own scripts at the root, against the live stack
  selftest                 end-to-end smoke test, run by ./selftest.sh
  loadtest                 throughput through the whole chain, run by ./loadtest.sh
```

The database is one directory holding live and historical data alike: `var/db` in a clone,
`deploy/data/db` in an install.

## What is on disk

In a clone, under `var/db`; in an install, the same tree under `deploy/data/db`.

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
taken from the first directory only. See §10 of the architecture document, and §13
for the consolidated list of known issues.
