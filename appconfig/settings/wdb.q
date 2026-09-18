// Virtual-table capture pack : WDB config
// see docs/virtual-table-capture-pack.md §3.3

\d .wdb
savedir:hdbdir:hsym`$getenv`KDBWDB       // one directory; sym file lives at its root
multiwriter:@[value;`multiwriter;0b]                           // 8.3.2 - set when another writer shares this root.
                                         // TorQ's pre-replay clearwdbdata deletes the WHOLE
                                         // date directory, which silently destroys the other
                                         // writer's data for that date; with this on, the
                                         // delete is scoped to the instruments this writer has
                                         // an ownership manifest for. Off for a single stack,
                                         // where the stock delete is correct and cheaper
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
// Seed the partition from the BUSINESS date, not the calendar date.
//
// TorQ seeds .wdb.currentpartition from .proc.cd[], and clearwdbdata[] deletes THAT
// partition before replaying the tickerplant log. Under a roll offset the two disagree, so
// the delete misses, fixpartition corrects the date afterwards, and the replay writes the
// day on top of data that was never removed. Measured: 442 duplicate rows after one restart.
// .eodtime.getday is what the tickerplant dates its own logs with, so seeding from it makes
// the two agree at any offset, including none.
//
// NOTE .eodtime is not loaded when this file runs, so the lookup sits inside the function
// body rather than at the top level.
startpartition:{[]
  d:@[{[x] .eodtime.getday .z.p};(::);{[e] .proc.cd[]}];
  (`date^@[value;`.wdb.partitiontype;`date])$d
  };

getpartition:{[] @[value;`.wdb.currentpartition;{[e] .wdb.startpartition[]}]};

tickerplantname:`                        // 8.3.2 - pin this writer to ONE tickerplant, by name.
                                         // ` takes whichever tickerplant is found first, which is
                                         // right with one stack and a coin toss with two: a writer
                                         // that binds to the other stack's tickerplant captures the
                                         // other stack's instruments and still looks healthy.
                                         // Set it from the process file's extras column
                                         // (-.wdb.tickerplantname stp2). It has to be DECLARED
                                         // here for that to work - .proc.override[] runs before
                                         // process code loads and only overrides variables that
                                         // already exist. see code/wdb/vttickerplant.q

symdomain:`sym                           // this stack's enumeration domain file. One reader
                                         // serving several stacks needs a distinct name per
                                         // stack (`syma, `symb...) - two roots both calling
                                         // it `sym cannot be read together (8.3.1)

\d .servers
CONNECTIONS:`segmentedtickerplant`idb`discovery

\d .proc
loadprocesscode:1b                       // loads $KDBAPPCODE/wdb/vtwrite.q
