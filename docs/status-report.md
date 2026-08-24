# Virtual-Table Capture Pack — status report

Point-in-time summary for ticket tracking. Written 2026-08-14, updated 2026-08-24
(VT-18 to VT-21: the load-order and live-partition defects, end-of-day catalogue reuse,
the remaining testing gaps, and the move of all tests into `testfiles/`).
Technical detail: `docs/virtual-table-capture-pack.md`. Presentable summary: the published
design brief (link in the ticket).

---

## Epic summary

Prototype a kdb+ market-data capture stack that partitions by **date and instrument** rather
than date alone, so that a lookup for one instrument becomes a directory lookup instead of a
scan. Data is written once and never moved: there is no RDB, no HDB, no overnight
sort/merge, and no gateway. History and live data are the same files, served by one process
type.

Built as a standalone application overlay onto a TorQ checkout. Runs on kdb-x, using its
virtual-table module to make the layout queryable. Captures the Finance Starter Pack's
`trade` and `quote` schema, partitioned on `sym`.

**Status: prototype complete and verified end to end. Agrees with stock kdb+ on identical data,
and sustains 1.45M rows/sec with zero loss. No blocking gaps remain in the prototype; the
outstanding items are deployment concerns and one external dependency on KX.**

Weekend compression is built, measured and shipped on a retention tier: it frees 83 % of the
bytes and 81 % of the disk at realistic partition sizes, for roughly double the query latency —
which is why it runs behind an age tier rather than over everything. Measuring it also settled
the last open scaling question: readers need no notification across a compression run, which
unblocked VT-17. **End of day is now flat — no operation in this design scales with how much
history is attached.**

Multi-stack read is no longer blocked. One reader serves several capture stacks by naming each
stack's enumeration domain apart rather than sharing one file, which keeps the stacks
independent. One documented limitation remains, on cross-stack grouping by a symbol column.

**Everything in the prototype is now built and verified.** VT-14 (legacy data migration) is
proven but deliberately unbuilt: greenfield deployment, and its shape depends on the open KX
item. That external dependency is the only thing outstanding.

---

## Status at a glance

| area | state |
|---|---|
| Architecture and design decisions | Complete, documented |
| Writer (date+instrument partitions) | Complete, verified |
| Reader (virtual tables over the tree) | Complete, verified |
| End-to-end capture → query | Verified, 2 ms latency for a new instrument |
| Scaling behaviour | Measured to 40,000 partitions; no operation now scales with retention |
| Client compatibility | Measured, 38 operations (`vt-compat-test.q`) |
| Correctness vs stock kdb+ | Verified — 16/19 queries identical, no silent disagreement |
| Load / volume testing | Verified — 1.45M rows/sec peak, zero loss |
| Silent-failure detection | Complete, verified |
| Weekend compression | Complete, measured, shipped on a retention tier with a size gate |
| Multi-stack read | Complete, verified, one documented limitation |
| Legacy migration | Designed and proven; build deferred pending KX (§9.6) |
| External blocker on KX | 1 open |

---

# Completed

## VT-1 · Architecture and design specification
1,201-line design document, 11 sections. Every decision recorded against the alternative that
was tried and rejected.

- **VT-1.1** Capture requirements and target topology defined (segmented tickerplant, writer,
  N replicable readers, minimal end-of-day, weekend housekeeping)
- **VT-1.2** Process inventory decided — what is kept, what is deleted, and why each deletion
  is safe (RDB, HDB, sort, sort workers, gateway all removed)
- **VT-1.3** On-disk contract specified: exact directory layout produced, and the three
  consequences that drive the rest of the design
- **VT-1.4** Gap analysis against TorQ 5.2.15 source — six changes identified, each traced to
  a specific line, with the root cause established (the write mode is a *staging* format in
  stock TorQ, so every "nobody reads this" exclusion becomes a defect once the merge is removed)
- **VT-1.5** Configuration design: process list, per-process settings, partition-column
  declaration, environment contract
- **VT-1.6** End-of-day sequence designed and documented (no data movement, no restart)
- **VT-1.7** Decisions register written — 8 decisions, each with the rejected alternative and
  the reason, so the design can be picked up cold
- **VT-1.8** Backward-compatibility analysis for existing date-partitioned data, including
  evaluation of three candidate approaches proposed at kick-off
- **VT-1.9** Comparison against the No-RDB Starter Pack, to establish what is genuinely new
  here versus already solved
- **VT-1.10** Third-party multipart-table module evaluated and its approach to partition-column
  handling adopted

## VT-2 · Establish query-engine behaviour
Determined empirically how the engine decides what to read. This drove the single most
important design decision.

- **VT-2.1** Constraint routing established: which conditions are answered from directory
  names versus by opening files
- **VT-2.2** Confirmed that a column stored inside the files can *never* be used to skip
  directories — so the partition column must be stripped on write, or the layout delivers no
  benefit at all and is slower than what it replaces
- **VT-2.3** Range-based partition-skipping mechanism investigated (an undocumented feature),
  including which operators it supports; concluded unusable for this schema
- **VT-2.4** Findings made reproducible as `testfiles/vt-probe.q`

## VT-3 · Writer implementation
Four overrides to the TorQ write path, 95 lines, applied as an overlay with no fork of TorQ.

- **VT-3.1** Strip the partition column from stored data (the load-bearing change)
- **VT-3.2** Detect newly created partition directories and notify readers — only on creation,
  not on every write
- **VT-3.3** Guarantee every table has a directory in every partition, before notifying
- **VT-3.4** Replace the overnight merge with a no-op plus a rollover notification
- **VT-3.5** Overlay install mechanism, working around TorQ's load order so the stock process
  code does not clobber the overrides
- **VT-3.6** Compression path corrected for the deeper directory tree
- **VT-3.7** Writer configuration and partition-column declaration

## VT-4 · Reader implementation
New process, 203 lines, serving history and the live day as one queryable object.

- **VT-4.1** Tree scan and partition catalogue construction
- **VT-4.2** Live-view file opening, so appended rows are visible with no reload
- **VT-4.3** Virtual-table construction, one per table, in the namespace clients query
- **VT-4.4** Table list discovered from disk rather than configured, so a schema addition needs
  no reader change
- **VT-4.5** Symbol-domain handling, ordered so directories are never opened against a stale
  domain
- **VT-4.6** Registration with the writer, plus handlers for the new-partition and end-of-day
  notifications
- **VT-4.7** Backstop rescan timer, so a lost notification degrades to staleness rather than
  blindness
- **VT-4.8** Operates correctly with no writer present — starts in any order, survives a writer
  restart, can serve an archived tree
- **VT-4.9** Reader configuration, including the history-window control
- **VT-4.10** Process attributes published for service discovery

## VT-5 · Packaging and operability
- **VT-5.1** Extracted into a standalone package, independent of the Finance Starter Pack it
  was derived from
- **VT-5.2** Single environment file; verified portable across paths and TorQ versions
- **VT-5.3** Start and stop scripts covering the full stack
- **VT-5.4** 7-assertion end-to-end self test, exits non-zero on failure, suitable for a smoke
  test
- **VT-5.5** README covering setup, running, querying and layout
- **VT-5.6** Source repository restored to its prior state, with the parallel FX demo intact

## VT-6 · End-to-end verification
- **VT-6.1** Capture layer verified: directory shape correct, partition column confirmed absent
  from stored files
- **VT-6.2** Directory skipping proven by deliberately corrupting one instrument — queries for
  other instruments continued to work, proving the corrupt directory was never opened
- **VT-6.3** Appended rows confirmed visible with **no reload and no notification**
- **VT-6.4** New instrument measured end to end at **2 ms** from directory creation to
  queryable
- **VT-6.5** Cold start verified with all state wiped and launched from an unrelated directory —
  reader bootstraps from an empty database and grows as the writer works
- **VT-6.6** End-of-day rollover path exercised
- **VT-6.7** Zero errors logged across all runs

## VT-7 · Failure-mode verification
- **VT-7.1** Writer's ordering guarantee deliberately broken to test the failure it prevents
- **VT-7.2** Tested with the gap in the first partition, the last partition, and for both an
  empty and a populated table
- **VT-7.3** Established the true symptom — quietly incomplete results, not the documented hard
  failure — and quantified it (half the data returned, no error)
- **VT-7.4** Confirmed the damage is bounded by the rescan interval rather than permanent
- **VT-7.5** Design document corrected; reproduction shipped as `testfiles/vt-gap-test.q`

## VT-8 · Scaling measurement
- **VT-8.1** Synthetic tree generator built, to test sizes beyond what the demo feed produces
- **VT-8.2** Kernel resource usage measured (memory mappings, file descriptors, resident
  memory) from 400 to 40,000 partitions
- **VT-8.3** System limits confirmed on the host
- **VT-8.4** Query latency measured against partition count — **targeted queries confirmed flat
  at 300–400 µs**, which verifies the design's central claim at scale
- **VT-8.5** Established that the documented memory-mapping ceiling **does not apply**, and
  identified why the original measurement was misleading
- **VT-8.6** Identified the real scaling limit (rescan time) and quantified it
- **VT-8.7** Design document corrected; reproduction shipped as `testfiles/vt-scale-test.q`

## VT-9 · Rescan optimisation
- **VT-9.1** Designed around the observation that historical partitions are immutable, so only
  the live partition can change
- **VT-9.2** Implemented catalogue and open-view reuse for immutable dates
- **VT-9.3** Cache invalidation handled for the cases that need it — end of day, and after
  compression rewrites historical files
- **VT-9.4** Verified the optimised path returns results identical to a full rescan
- **VT-9.5** Confirmed it never blocks discovery of a late-appearing historical partition
- **VT-9.6** Measured: **154x faster at 40,000 partitions, and now flat with respect to history
  depth** — the scaling limit from VT-8 is removed

## VT-10 · Client compatibility assessment
- **VT-10.1** 38 common query operations probed, now by a runnable test rather than by hand
- **VT-10.2** Established that 22 work directly and 9 fail only when applied to the table
  object — all 9 work when wrapped in a `select`, making migration mechanical
- **VT-10.3** Identified the one genuine gap: tooling that *discovers* table names sees nothing
- **VT-10.4** Corrected two incorrect claims in the design document, one of which was a faulty
  test rather than a real limitation

---

## Key findings

**The core premise is verified, not just argued.** A targeted query — one date, one instrument
— runs in 300–400 µs and **does not slow down as history grows**, measured from 400 to 40,000
partitions. This is the benefit the whole design exists to deliver.

**Two documented assumptions were proved wrong by measurement.** Both had been stated
confidently in the design and were corrected once tested:

- A predicted memory-mapping ceiling, which would have limited the design to roughly nine days
  of history, **does not exist**. The original measurement was valid but measured a file-open
  method the reader does not use. Actual cost is 891 bytes of memory per partition.
- A predicted hard failure when a partition is incomplete **does not occur**. The reader
  instead returns quietly incomplete results — a worse failure mode than the one expected,
  because nothing surfaces it.

Both corrections are recorded in the design document alongside the original claim, so the
reasoning is auditable rather than silently rewritten.

**Client impact is smaller than first thought.** 27 of 38 operations work directly. Eleven fail
on the table object but work when wrapped in a `select` — a mechanical edit to existing
scripts, not a redesign. One genuine gap remains: tooling that discovers table names rather
than being told them sees nothing.

**It agrees with kdb+.** Given identical data, 16 of 19 queries return identical results. The
three that differ all *error* rather than returning a wrong number, and all three work when the
query is wrapped in a `select`. **No silent disagreement was found** — the important property,
since an error is recoverable and a quietly wrong number is not.

**One naming decision needed.** The reader exposes the partition column as `instrument`
regardless of what the source schema calls it (`sym` here). Existing queries naming
the schema column would need changing. Cheap to fix now, expensive once clients are written.

**One external blocker.** A single virtual table cannot span partitions with different column
layouts, which prevents presenting old-format and new-format data under one table name.
Requires a change from KX. Workaround exists (separate table names); it pushes complexity onto
clients.

## VT-11 · Validation against stock kdb+
Two databases built from the **same captured bytes** — the new date+instrument format, and a
conventional date-partitioned kdb+ database with the partition column stored as a real column.
The conventional one stood up as a plain q process with no TorQ involved. 19 queries run against
both and compared.

- **VT-11.1** Conventional control database built from identical data
- **VT-11.2** Query battery defined across filters, aggregations, grouping, time ranges,
  weighted averages, empty results and the partition column
- **VT-11.3** Results compared after normalising row order, column order and symbol
  representation — **16 of 19 identical**
- **VT-11.4** The 3 differences characterised: in every case the virtual table **raises an error
  rather than returning a wrong answer**, and all 3 work when wrapped in a `select`
- **VT-11.5** Two representation differences identified and assessed as non-defects; the
  partition column's exposed name has since been made configurable and set to match the schema,
  so client queries port across unchanged
- **VT-11.6** Reproducible as `testfiles/vt-compare-kdb.sh`

## VT-12 · Load and volume testing
Rate-controlled generator plus a harness that bursts volume through a clean stack and polls the
reader until every row is visible, so the figure measures the whole chain.

- **VT-12.1** Load generator built (`code/tick/loadfeed.q`, `code/loadtest.q`) with configurable
  volume, batch size and instrument universe; harness `./loadtest.sh`
- **VT-12.2** Throughput established across five configurations up to 4M rows —
  **peak 1,447,000 rows/sec end to end, with zero data loss and no errors in any run**
- **VT-12.3** Instrument-count cost quantified: same volume across 50, 500 and 2,000 instruments
  reduces write throughput (637k → 216k → 97k rows/sec) and scales whole-database operations
  with directory count
- **VT-12.4** Query latency re-measured at realistic partition sizes: selective queries track
  **rows read, not database size** (0.2–0.3 µs/row), and a wider instrument universe makes a
  single-instrument query *faster*
- **VT-12.5** Storage footprint quantified: **4.9x amplification** from 35 bytes/row at 50
  instruments to 172 bytes/row at 2,000 — the small-files cost, now measured rather than
  asserted. The narrower the row, the worse the ratio: per-file overhead is fixed
- **VT-12.6** Burst-absorption behaviour identified: the writer buffers in memory when a burst
  outpaces the flush (2,098,000 rows observed in one cycle), so a large burst is bounded by
  writer RAM — needs a memory limit and an alert in a real deployment

## VT-13 · Detection for the silent failure mode
The incomplete-partition failure from VT-7 produces wrong answers with no signal. The reader now
compares partition coverage across tables on every rebuild and says so.

- **VT-13.1** Coverage-gap warning implemented: a table whose date coverage is a strict subset of
  another's is reported by name, with the missing dates
- **VT-13.2** `coverage[]` exposed for monitoring, so a health check can poll it rather than
  scrape logs
- **VT-13.3** Verified three ways: silent on a healthy database, fires on a real gap, and does
  **not** repeat on subsequent rebuilds — it logs only when the gap set changes, and logs a
  recovery message when gaps clear

## VT-15 · Weekend compression
Scheduled, run against a live stack, and measured. Two of the three sub-points changed a
documented design claim.

- **VT-15.1** Compression job built and scheduled: `code/processes/vtcompress.q` replaces the
  stock process and applies the directory-classifier fix; `./compress.sh` runs it, with
  `--dry-run` to report scope and `--test` to exercise it against the running stack. A cron
  line for a Saturday window is documented
- **VT-15.1a** *Defect found in the documented fix.* The classifier override was specified to
  live in the process's settings file. It cannot: settings load ~13 ms **before**
  `code/common/compress.q`, which then reinstates the stock definition. The job runs, reports
  success, and compresses nothing — the exact failure the fix was written to prevent. The
  override now lives in process code, which loads after common code
- **VT-15.2** *Documented caveat disproved.* The design said readers must be sent a rollover
  after compression or they would serve pre-compression data indefinitely. Measured: a reader
  returns byte-identical results through the **same handle**, with no rollover, no re-map and
  no restart, after every eligible column file was compressed and renamed over beneath it. The
  reason is the one already established for memory mapping — a trailing-slash open is a live
  view, so there is no stale inode to hold. **This unblocks VT-17**
- **VT-15.3** Compression ratio measured on real partition sizes: **83 % of the bytes and
  81 % of the disk** at 20,000 rows per instrument per day. The two numbers converge once
  column files clear a filesystem block — and diverge sharply below it, where the same job
  frees 83 % of the bytes and under 10 % of the disk. The ratio is a function of partition
  size, not of the data, which is the small-files cost of instrument-splitting quantified
- **VT-15.4** Read cost measured properly — 1,000 samples per state, min and median: the same
  single-instrument select goes from 382 µs to ~800 µs, **about +100 %** at these partition
  sizes. So the trade is 75–80 % of disk for roughly double the query latency, not a free win.
  The age tier is what makes that tolerable: recent data stays uncompressed and fast
- **VT-15.5** Threshold established for the enable/disable decision: compressed size lands on
  the one-block-per-file floor immediately and stays flat, so the saving is decided by rows per
  instrument per day. Below ~1,000 it recovers under 40 %; above ~10,000 it recovers over 80 %
- **VT-15.6** Recommendation implemented and shipped: an **age tier** (`minage 7`, so recent
  data stays uncompressed and interactive queries run at full speed) and a **size gate**
  (`.cmp.minfilesize 4096`, skipping files that cannot free a block). A/B measured across
  uncompressed / gated / ungated: the gate compresses 350 files instead of 750 for an
  **identical** result — same 8,220 kB on disk, same latency within noise. It buys less job
  time and 53 % fewer files rewritten per weekend, not faster queries; the expectation that it
  would cut read cost was tested and disproved

## VT-16 · Multi-stack read
One reader now serves several capture stacks safely. The blocker was resolved by a third option
neither of the two originally proposed: name the domains apart rather than share one.

- **VT-16.1** *Blocker, as previously reported:* two capture trees could not have independent
  `sym` files. The reader loaded each root's domain in turn and the last won, so every earlier
  root's symbol columns silently resolved to the wrong values
- **VT-16.2** *Decision.* The ticket offered a shared enumeration domain or one reader per
  stack. One reader per stack was rejected outright — it pushes the join to the client, which
  this design exists to avoid. `load` binds a global named after the **file**, and each column
  records which domain it belongs to, so `sym` and `symb` coexist in one process with each
  column resolving through its own. Verified at the kdb+ level before committing to it
- **VT-16.2a** *An objection of ours turned out to be wrong.* The shared domain was also
  rejected on the grounds that two writers appending to one `sym` file risk corrupting it.
  Measured (`testfiles/vt-sym-concurrency.q`): six concurrent writers, 1,800 enumeration calls on an
  overlapping vocabulary, **zero duplicates and zero indices invalidated** — the primitive
  locks. The real constraint is storage, not concurrency: sharing means both stacks writing one
  inode, symlinked into each root, so it needs a shared filesystem. Two *copies* is the unsafe
  configuration, because they diverge on the first new symbol. Both options are now supported
  and documented, with the choice driven by storage topology
- **VT-16.3** Implemented both sides as configuration: `symdomain` in the writer's settings
  (redirecting `.Q.en` to `.Q.ens`, one line covering every enumeration site), and domain
  *discovery* in the reader instead of assuming `sym`. The collision check now reports only the
  genuinely unsafe case — two roots using the same name for different contents
- **VT-16.4** **Both modes work, and the reader needs no configuration to tell them apart** —
  it discovers whatever domain files exist per root. The choice is made per stack on the writer
  side: leave `symdomain` at `` `sym `` and symlink one file into each root, or set a different
  `symdomain` per stack. Verified across all three configurations a deployment can reach —
  separate domains, one shared file symlinked into both roots, and the broken middle case of two
  copies under one name — by `testfiles/vt-multistack-test.q`, 17 assertions. The shared case checks
  that a write through the link *extends the shared file and leaves it a link*, which is what
  would otherwise silently turn mode two into mode three
- **VT-16.5** *Limitation found, measured and documented.* Grouping on a symbol column held
  inside the files splits per domain (`` `sym$`book1 `` and `` `symb$`book1 `` are distinct), so
  a cross-stack `by side` returns one group per domain rather than one per value. Grouping by
  the **partition column** — the query this layout exists to serve — is correct, as is
  filtering, and `value` on the column fixes the rest. Asserted in the test so an engine change surfaces it
- **VT-16.6** Cost measured: same data across one tree versus two costs 73 → 119 µs on rebuild
  (one extra directory read per date per table) and 254 → 278 µs on a selective query

## VT-17 · Make end of day flat
Rollover dropped the reader's whole cache, so end of day rescanned all history — the last cost
that still grew with retention. It now forgets one date. **No operation in this design scales
with how much history is attached.**

- **VT-17.1** Cache drop removed from `rollover`, replaced with `dropdates` — targeted
  invalidation of a single date, keeping the rest of the catalogue and its opened views
- **VT-17.2** *Silent data-loss trap found and avoided.* Simply deleting the `dropcache[]` call
  is wrong: `mutable` is `d>=current`, so once `current` moves to the new date the date that
  just **closed** reads as immutable, and the reader reuses its stale catalogue. Any directory
  the writer created in its final flush of the day would be on disk and permanently invisible,
  with no error. The drop must therefore happen **before** `current` moves
- **VT-17.3** Measured: end of day now tracks the live rebuild instead of the cold rescan —
  2/3/7/8/11 ms at 400 to 40,000 directories, against 18/90/388/731/1,540 ms before.
  **Flat with retention, 140x cheaper at 40,000 directories.** 2.4 ms on the running stack
- **VT-17.4** `testfiles/vt-rollover-test.q` added, covering the trap in VT-17.2 specifically: it
  creates a directory the reader has not scanned, rolls over, and checks the rows survive.
  Verified to fail against the naive version of the change and pass against the shipped one

## VT-18 · Writer restart preserved the wrong layout — FOUND AND FIXED
Found by accident on 2026-08-19, while restarting the stack for an unrelated config change.
Not a TorQ gap: a gap in this pack's own overlay, and the one class of defect the existing
tests could not reach.

- **VT-18.1** *Defect.* Restarting the writer is the normal recovery path: TorQ deletes the
  current partition and rebuilds it from the tickerplant log. That replay runs inside
  `.wdb.startup[]`, roughly a second **before** `.proc.init[]` runs the init list — which is
  where the pack installed its overrides. So every partition rebuilt by a replay was written by
  the **stock** writer, keeping the partition column in the files. All 22 partitions came back
  8 columns wide instead of 7, putting the database into the mismatched-column state of §9.3:
  silently wrong answers, no error
- **VT-18.2** *Why it was never caught.* Every test in the pack wipes `var/` first, so the
  tickerplant log is empty and the replay is a no-op. The defect is only reachable by
  restarting a writer whose log has data — which is exactly what a real deployment does
- **VT-18.3** *Fix.* `startup` is defined in `code/wdb/origstartup.q`, which loads before the
  overlay, and `wdb.q` only calls it — so the overlay wraps it and installs the overrides
  first. Verified from the writer's log: overrides at line 171, replay at 184 (previously 3573
  and 185). The init-list registration stays as a fallback for a writer that never subscribes
- **VT-18.4** `testfiles/vt-replay-test.q` added, asserting the ordering out of the writer's own log
  plus the consequence in the tree — no table may hold two column widths, and the partition
  column may not appear in any file


## VT-19 · A new symbol value read as null for up to 30 seconds — FOUND AND FIXED
Found on 2026-08-19 while answering a question about what the live view guarantees. Second
defect in the pack's own code, and the same shape as VT-18: an invariant that was true for the
case the tests covered and false for one they did not.

- **VT-19.1** *Defect.* §5.2's result — appends need no rebuild — holds for rows but not for
  symbol *values*. Symbol columns are indices into an enumeration domain the reader holds in
  memory. A value never seen before is appended to the domain file and written into an
  **existing** partition, so no directory is created and nothing is announced (§4.1 is
  edge-triggered on directories). The rows appear immediately; that column reads as **null**
  until the domain is reloaded. Silently
- **VT-19.2** *Why it was never caught.* The only caller of `loadsym` was `rebuild`, so the
  window was the 30-second backstop sweep. Every test either wipes the database first or works
  with a fixed symbol universe, so no test ever introduced a new value into a live partition
- **VT-19.3** *Fix.* The domain now has its own timer, `symsweep`, defaulting to one second.
  `symchanged` is a single `hcount` per root — far cheaper than the ~10 ms rebuild it used to
  ride on, so it can run often without making the reader rescan directories
- **VT-19.4** Measured: **1.1 s, 1.9 s, 2.6 s** over three runs, against up to 30 s before. The
  floor is the writer's own flush interval, since the value is not in the domain file until the
  writer flushes
- **VT-19.5** `testfiles/vt-symdomain-test.q` added, asserting both halves: that the rows arrive
  immediately, and that the value resolves inside a five-second budget

## VT-20 · The tests all started from a clean, static world
Both defects found on 2026-08-19 (VT-18, VT-19) were invisible for the same structural reason,
not by coincidence: every test either builds a scratch tree from nothing or assumes a fixed
symbol universe. Neither *restart with prior state* nor *novelty at runtime* was reachable by
any of them. Four more cases from that class were then worked through deliberately.

- **VT-20.1** *Restart under load — clean.* A writer restart deletes and replays the live
  partition; done underneath a running reader, the reader and disk agreed throughout and counts
  kept rising. TorQ's source only warns about the Windows case (delete fails); on Linux it
  succeeds and the trailing-slash view simply re-resolves
- **VT-20.2** *Name collision — confirmed, and worse than documented.* Two instruments whose
  names differ only in punctuation share one directory. Measured: the hyphenated one returns
  **0 rows** and the other returns **all of them**. Both answers wrong, neither errors. The
  design had called this "rows interleave". No detection exists and none is cheap — by the time
  the writer holds a directory name the distinguishing character is gone.
  `testfiles/vt-collision-test.q`
- **VT-20.3** *On-disk damage — three kinds, one dangerous.* A truncated column attaches and
  **silently returns the shortest column's row count**; a missing `.d` is detected, excluded and
  logged; a corrupt column errors loudly. Blast radius is contained by partition elimination:
  selective queries on healthy instruments are unaffected, whole-table queries fail — including
  ones that never name the damaged column. `testfiles/vt-damage-test.q`
- **VT-20.4** *A table added mid-life works, and trips the gap check.* It is discovered from the
  tree with no config change and is immediately queryable. It also has fewer dates than its
  peers, which is indistinguishable on disk from §4.6's failure, so it is reported as a coverage
  gap on every rebuild for as long as the older dates are attached. Correct by its own rules;
  worth knowing before adding a table to a live database. `testfiles/vt-newtable-test.q`
- **VT-20.5** *Tickerplant restart — capture stalls permanently.* See §4.8. The feed half is
  fixed; the writer half is an operational procedure (restart it — the replay loses nothing) and
  a design question deferred rather than patched. `testfiles/vt-tprestart-test.q`

## VT-21 · The three moments a test never covered — TWO DEFECTS FOUND AND FIXED
VT-20 closed the *stale state* and *novelty* gaps. Three remained, all of the same shape: a
query or a process arriving in the middle of something rather than after it. Working through
them found two defects, one of which had been running in production configuration all along.

- **VT-21.1** *A query arriving mid-write — safe, and for a reason worth knowing.* A splayed
  write extends columns one at a time, so a partition genuinely has ragged column lengths on
  disk while it is written; **200 of 5,000 concurrent reads landed in that window**. Not one
  returned a torn row or an error. A splayed table is cut to its shortest column, so a short
  read is a consistent *prefix* — the same rule that makes truncation silent (VT-20.3) is what
  makes this safe. Mid-rebuild is safe for a different reason: q's main loop serialises, so the
  cost of a rebuild is paid as **queuing**, never as inconsistency. `testfiles/vt-inflight-test.q`
- **VT-21.2** *A reader with no writer froze the live partition — FOUND AND FIXED.* `.vtidb.current`
  decides which dates are cached forever. When the reader could not ask the writer, it fell back
  to `.z.D` — and with a non-zero roll offset the writer is still filling *yesterday* for the hours
  after midnight GMT. In that window the live date was marked immutable and cached: new
  instruments were on disk, absent from every query, with nothing logged. The live partition is
  now taken from the newest directory on disk, which the writer cannot contradict, and the
  writer's own answer is still preferred when it is ahead. §5.8, `testfiles/vt-restart-test.q`
- **VT-21.3** *A fourth kind of damage — FOUND, MEASURED, DELIBERATELY NOT GUARDED.*
  `.d` is written before the columns, so every new partition passes through a state where it
  names files that do not exist. A lazy `get` accepts it and even counts it correctly, and then
  **every whole-database query fails** — one directory is enough, because all of them must be
  opened. A guard was built and reverted. The transient race is the 30-second sweep landing in
  the daily creation burst: **once per ~9 years at 10 instruments, once per ~2 months at 500,
  once per ~6 days at 5,000**, and it heals on the next sweep. The only permanent source is a
  full disk — where capture has already stopped, and a reader that keeps answering while
  silently omitting an instrument is worse than one that fails loudly. Cost of the guard was
  ~45% of a full rescan. §5.7, `testfiles/vt-diskfull-test.q` asserts the unguarded behaviour
- **VT-21.4** *Disk full — nothing is lost, but a retry duplicates.* ENOSPC arrives as a normal
  q error naming the file; the process stays up and keeps serving. TorQ empties the in-memory
  table only after the upsert loop and the pack's override rethrows, so the rows survive for the
  next flush. But the partitions written *before* the failure are already on disk, and the retry
  re-upserts the whole buffer with nothing to dedupe it. After any ENOSPC, check the partitions
  that succeeded, not only the one that reported. §8.5, `testfiles/vt-diskfull-test.q`

- **VT-21.5** *Table discovery still scanned all of history — REMOVED.* Asked to justify each
  gap's code by probability rather than by possibility, one item did not survive: `tablelist`
  did a `readdir` per **date** on every rebuild so that a table appearing mid-life would be
  found. At 250 dates that was 2.6 ms of a 4.2 ms rebuild, growing with retention for ever, to
  notice something that happens once in a deployment's life. It now scans the live partition
  only — where a new table can actually appear — plus every date once on a cold catalogue.
  Live rebuild at 250 dates: **4,194 µs → 1,428 µs**, the same as hard-configuring `tabs`.
  At 40,000 partitions the sweep's rebuild went 10 ms → 6 ms and is now flat. The cost is that
  a table added to an already-rolled date needs `dropcache[]`, which is the rule §6.1 already
  states for a directory added to a past date. §5.3, `testfiles/vt-newtable-test.q`

- **VT-21.6** *A writer restart duplicated the day it was meant to rebuild — FOUND AND FIXED.*
  Recovery deletes the live partition and replays the tickerplant log, but `clearwdbdata` runs
  against `getpartition[]`, which TorQ seeds from `.proc.cd[]` — the **calendar** date. Under a
  roll offset the tickerplant is on a different date, so the delete missed, the real partition
  survived untouched, and the replay wrote the whole day on top of it. `fixpartition` corrects
  the date afterwards, too late, and its corrective branch only fires when the wrong directory
  exists. **Measured on the live stack: 442 duplicate rows on 2026.08.18 from a single restart**,
  all inside the replayed window. The pack now seeds from `.eodtime.getday`, the same function
  the tickerplant uses to date its own logs, so the two agree by construction at any offset —
  including none, where it reduces to the plain date. `appconfig/settings/wdb.q`,
  `testfiles/vt-partition-test.q` (12 assertions, fails against the stock seeding)
- **VT-21.7** *Partitions created during log replay are never announced.* Found while verifying
  the above. `replaymaxrowcheck` calls `savetables` directly rather than through `savetodisk`,
  so the `vtnew` edge signal accumulates during the replay and is then cleared by the next
  timed flush before anything reads it. Consequences are small and measured: readers pick the
  partitions up on the 30-second sweep instead of immediately, and `vtfill` does not run for
  them, so a table with no data in that partition keeps no empty directory. **Not fixed** —
  logged here because the impact is bounded and the fix belongs with the §4.8 re-subscribe
  question rather than on its own.

- **VT-21.8** *A writer restart under-reports to readers for the length of the replay.* The
  restart deletes the live date and rebuilds it, and the reader is not told. Three states,
  measured: while the catalogue still points at deleted directories every query **fails loudly**
  naming the missing file; once the sweep rescans, the reader serves history only and today is
  **silently absent**; through the replay, whole-database counts climb monotonically
  (650 → 1200) and are **short but not wrong**. Selective queries on instruments already rebuilt
  are exact throughout and history is never at risk. §4.6's coverage check cannot see any of it,
  because the date leaves every table at once and the check only compares tables against each
  other. Not a reader defect — the rows genuinely are off disk — but worth knowing before
  restarting a writer underneath anything that reports numbers to people.
  `testfiles/vt-wdbrestart-test.q` (16 assertions)

- **VT-21.6** *`vtfill` never ran during a log replay — FOUND AND FIXED.* The load-order fix of
  VT-18 makes the replay write the right layout; it does not make it run the rest of a flush.
  TorQ's `replaymaxrowcheck` calls `savetables` directly, so `vtnew` filled correctly and was
  then thrown away by the `vtnew::()` opening the next flush — meaning §4.6's empty-directory
  fill was absent on the routine recovery path. Found on a real restart after an overnight
  shutdown: nine instruments had a `trade` directory and no `quote` one. Fixed by carrying the
  pending list across the boundary, which costs nothing in steady state. §4.7,
  `testfiles/vt-replay-test.q`

VT-21.2 shares the signature the whole project keeps returning to: correct bytes on disk, no
error anywhere, and an answer that is quietly incomplete. VT-21.3 is the counter-case, and the
reason the guard was reverted — there, *failing* is the honest behaviour, and suppressing it
would have manufactured exactly that signature.

---

# Remaining work

## VT-14 · Legacy data migration — DESIGNED, PROVEN, DELIBERATELY NOT BUILT
Held open on purpose. This is a greenfield deployment with no history to migrate, and the
approach depends on the open KX item below: if one table can span both formats, the right
design is a single table name and the two-name workaround becomes dead code. Building it now
would ship a migration path nobody has asked to use.

Prototyped far enough to retire the risk, then reverted (§9.6 records the findings and what it
takes to rebuild — roughly 40 lines in the reader).

- **VT-14.1** ✓ *Proven.* A conventional date-partitioned database built from real captured
  data attaches beside the capture tree, keyed on date alone, under its own table name
- **VT-14.2** ✓ *Proven.* Row counts, symbols and numerics identical to a plain read of the
  same files; and **280 µs conventional load versus 320 µs through the reader**, so the
  design's "correct, and no faster" claim is now measured — ~14 % overhead, not a regression.
  (Measured before the schema was switched to the Starter Pack's `trade`/`quote`; the design
  is schema-independent and the legacy path is no longer in the code)
- **VT-14.3** ✓ *Proven.* count, aggregate, time filter, distinct, sort, `meta`, and a union
  across both table names all behave
- **VT-14.4** Cutover procedure — **open**, and correctly so: it depends on whether clients end
  up with one table name or two, which is what the KX item decides

**Trigger to build it: KX answers on differing column lists, or a deployment with real history
appears.**

---

## Risks

| risk | impact | mitigation |
|---|---|---|
| ~~Results may not match stock kdb+~~ | Retired — VT-11 verified agreement | closed |
| ~~Untested at realistic volume~~ | Retired — VT-12 measured to 4M rows, no loss | closed |
| Storage amplifies 4.9x at wide instrument universes | Capacity planning | Measured; size the estate on 172 B/row, not row data |
| Large bursts bounded by writer RAM | Writer could exhaust memory | Set a `-w` limit and alert |
| ~~Partition column exposed under a different name than the schema~~ | Retired — now configurable via `partitioncol`, set to the schema's name | closed |
| ~~Incomplete partitions fail silently~~ | Retired — prevented on the writer, detected on the reader (VT-13) | closed |
| ~~Several capture roots cannot have independent sym files~~ | Retired — VT-16 named the domains apart | closed |
| Cross-stack `by` on a symbol column splits per domain | Wrong group count in multi-stack reports | Documented; use `value`, or share one domain (§8.3.1) |
| ~~End of day rescans all history~~ | Retired — VT-17 made it O(instruments) | closed |
| One table cannot span both data formats | Clients must know two table names | Raised with KX; workaround in place |
| Small-files count | Constrains filesystem choice and backup tooling | Known and quantified; inherent to the design |
| **A tickerplant restart stalls capture until the writer is restarted** | Silent — every process stays up and looks healthy | Feed fixed; writer needs a manual restart, which replays and loses nothing. Detect with `vt-tprestart-test.q` (§4.8) |
| **A truncated column file returns fewer rows, silently** | Wrong answers, no warning | Demonstrated (`vt-damage-test.q`). Specific to **uncompressed** columns: a compressed one carries a metadata header kdb+ validates, so the same damage raises instead. No detection exists for the uncompressed case |
| **Instrument names differing only in punctuation** | **One becomes unqueryable, the other absorbs its rows — silently** | Demonstrated (`vt-collision-test.q`). No detection exists. Hash or escape identifiers containing `.` `-` `/` before they reach the parted column |
| Client scripts need edits | Migration effort for existing dashboards | Quantified: 11 of 38 operations need a `select` wrapper (`vt-compat-test.q`) |
| ~~A new symbol value reads as null until the next rebuild~~ | Retired — VT-19 gave the domain its own timer | closed |
| ~~Writer restart rebuilt partitions in the wrong layout~~ | Retired — VT-18 installs the overrides before replay | closed |
| A writer restart deletes and rebuilds the live partition | Anything not in the current tp log is not restored | Stock TorQ recovery; know it before restarting a writer |
| **A partition whose `.d` names columns that are not on disk** | **Every whole-database query fails, not just that partition** | Not guarded, by decision (§5.7): transient case heals within one sweep, permanent case is a full disk where failing loudly is correct. Pinned down by `vt-diskfull-test.q` |
| **A disk-full retry re-writes partitions that already succeeded** | Duplicate rows, silently, in the partitions written *before* the failure | Demonstrated (`vt-diskfull-test.q`, §8.5). No dedupe exists — check those partitions after any ENOSPC |
| **The same `(date;instrument)` under two roots** | Rows served twice, no error, one key | Demonstrated (`vt-inflight-test.q`, §8.3.1). Keep stack instrument universes disjoint |
| ~~Reader with no writer freezes the live partition~~ | Retired — the live date is taken from disk, not `.z.D` | closed (§5.8) |
| ~~A writer restart duplicates the day under a roll offset~~ | Retired — the partition is seeded from the business date | closed (VT-21.6). Rows duplicated by a restart *before* the fix stay on disk — check any partition written across a pre-fix restart |
| Partitions created during tp log replay are not announced | Up to 30s of staleness after a writer restart; `vtfill` skipped for them | Known, not fixed (VT-21.7) |

---

## Notes for reviewers

Every claim in the design document has a runnable script that reproduces it, all under
`testfiles/`:

```
testfiles/vt-probe.q          how the query engine routes conditions
testfiles/vt-limitations.q    what works and what does not
testfiles/vt-sample-legacy.q  attaching an existing date-partitioned database
testfiles/vt-gap-test.q       what an incomplete partition actually does
testfiles/vt-scale-test.q     resource use and latency versus partition count
testfiles/vt-compare-kdb.sh   agreement with a conventional kdb+ database, same data
./compress.sh --dry-run  what the weekend job would touch, and the ceiling on what it can free
./compress.sh --test     compression underneath a live reader; ratio and read cost
testfiles/vt-compress-ratio.q where the saving actually lands, bucketed by original file size
testfiles/vt-compress-sizes.q how the saving scales with rows per instrument per day
testfiles/vt-compress-ab.q    uncompressed vs gated vs ungated: disk and latency, 1000 samples
testfiles/vt-rollover-test.q  end of day keeps the date it just closed, and does not rescan history
testfiles/vt-multistack-test.q one reader over two capture stacks: all three domain configurations
testfiles/vt-sym-concurrency.q concurrent writers against one shared enumeration domain
testfiles/vt-replay-test.q    overrides installed before the tp log replay, and 4.6's fill survives it
testfiles/vt-symdomain-test.q rows arrive live; a brand new symbol value resolves within seconds
testfiles/vt-collision-test.q what two instruments sharing a sanitised directory name actually do
testfiles/vt-damage-test.q    truncated / .d-less / corrupt partitions, and the blast radius
testfiles/vt-newtable-test.q  a table appearing mid-life is discovered, and trips the coverage check
testfiles/vt-tprestart-test.q liveness: writer subscribed, database growing, feed not holding a handle
testfiles/vt-compat-test.q   38 client operations: what works, what needs a select wrapper
testfiles/vt-inflight-test.q  a query arriving mid-append and mid-rebuild: short reads, never wrong ones
testfiles/vt-restart-test.q   a reader started in the middle of a flush, and whether it heals
testfiles/vt-diskfull-test.q  a genuinely full filesystem: what breaks, what survives, what duplicates
testfiles/vt-partition-test.q which partition a restart deletes, at any roll offset or none
testfiles/vt-wdbrestart-test.q what a reader serves while the writer deletes and replays the day
./loadtest.sh            throughput, storage and latency under real volume
./selftest.sh            end-to-end check against a running stack
./regress.sh             runs the sixteen assertion tests above and summarises them
```

This was deliberate: two of the design's stated assumptions turned out to be wrong when
measured, and both were caught because the claims were made reproducible rather than asserted.
