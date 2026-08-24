// Virtual-table capture pack : WDB config
// see docs/virtual-table-capture-pack.md §3.3

\d .wdb
savedir:hdbdir:hsym`$getenv`KDBWDB       // one directory; sym file lives at its root
writedownmode:`partbyattr                // date + instrument directories.
                                         // NB necessary but NOT sufficient - on its own it
                                         // also writes the partition column into the files,
                                         // which defeats the purpose. see code/wdb/vtwrite.q
mode:`saveandsort                        // the sort phase is overridden to a no-op (4.2)
immediate:1b                             // flush on every timer tick, ignore maxrows
settimer:0D00:00:01                      // ...every second
gc:0b                                    // at 1s cadence do not gc on every flush
rdbtypes:hdbtypes:gatewaytypes:()        // none of these processes exist
sorttypes:sortworkertypes:()
idbtypes:`idb
permitreload:0b                          // nothing to reload
sortcsv:hsym`$getenv[`KDBAPPCONFIG],"/sort.csv"
// ---------------------------------------------------------------------------
// seed the partition from the BUSINESS date, not the calendar date.
//
// TorQ initialises .wdb.currentpartition from .proc.cd[] - the calendar date - and
// clearwdbdata[] then deletes THAT partition before the tickerplant log is replayed. With a
// roll offset the two disagree: at 07:06 UTC under a 09:00 roll the calendar says the 19th
// while the tickerplant is still logging the 18th. The delete then misses (nothing exists for
// the 19th yet), fixpartition corrects currentpartition afterwards from the tp log date, and
// the replay writes the whole day on top of data that was never removed - duplicating every
// row already on disk. Measured on this stack after one restart: 442 duplicate rows.
//
// .eodtime.getday is the same function the tickerplant uses to date its own logs, so seeding
// from it makes the writer agree with the tickerplant by construction at ANY roll offset -
// including none, where it reduces to the plain date and nothing changes.
//
// NOTE .eodtime is not loaded when this settings file runs (settings load ~11ms earlier), so
// the lookup sits inside the function body, not at the top level. writedown.q calls
// getpartition[] well after eodtime.q has loaded; the trap covers it never arriving at all.
// ---------------------------------------------------------------------------
startpartition:{[]
  d:@[{[x] .eodtime.getday .z.p};(::);{[e] .proc.cd[]}];
  (`date^@[value;`.wdb.partitiontype;`date])$d
  };

getpartition:{[] @[value;`.wdb.currentpartition;{[e] .wdb.startpartition[]}]};

symdomain:`sym                           // name of this stack's enumeration domain file.
                                         // leave as `sym for a single stack. when several
                                         // stacks are to be served by ONE reader, give each
                                         // its own name (`syma, `symb...) - two roots both
                                         // calling it `sym cannot be read together (8.3.1)

\d .servers
CONNECTIONS:`segmentedtickerplant`idb`discovery

\d .proc
loadprocesscode:1b                       // loads $KDBAPPCODE/wdb/vtwrite.q
