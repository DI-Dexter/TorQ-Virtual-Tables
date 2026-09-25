// Virtual-table capture pack : WDB config
// see docs/virtual-table-capture-pack.md §3.3

\d .wdb
savedir:hdbdir:hsym`$getenv`KDBWDB       // one directory; sym file lives at its root.
                                         // With several capture stacks setenv.sh overrides BOTH
                                         // from the process file - each writer owns its own root
                                         // (8.3). code/wdb/vtwrite.q keeps them equal regardless
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
// Seed the partition from the business date, not the calendar date. TorQ seeds
// .wdb.currentpartition from .proc.cd[] and clearwdbdata[] deletes that partition before
// replaying the log, so under a roll offset the two disagree and the replay lands on top of
// data the delete missed. .eodtime.getday is what the tickerplant dates its own logs with.
//
// NOTE .eodtime is not loaded when this file runs, so the lookup sits inside the function
// body rather than at the top level.
startpartition:{[]
  d:@[{[x] .eodtime.getday .z.p};(::);{[e] .proc.cd[]}];
  (`date^@[value;`.wdb.partitiontype;`date])$d
  };

getpartition:{[] @[value;`.wdb.currentpartition;{[e] .wdb.startpartition[]}]};

tickerplantname:`                        // 8.3 - pin this writer to ONE tickerplant, by name.
                                         // ` takes whichever tickerplant is found first, which is
                                         // a coin toss with several stacks. Set from the process
                                         // file; it must be declared here for that to work, as
                                         // .proc.override[] only overrides names that already
                                         // exist. see code/wdb/vttickerplant.q

symdomain:`sym                           // this stack's enumeration domain file. One reader
                                         // serving several stacks needs a distinct name per
                                         // stack (`sym1, `sym2...) - two roots both calling
                                         // it `sym cannot be read together (8.3.1). setenv.sh
                                         // sets it from the process file when VTSTACKS>1

\d .servers
CONNECTIONS:`segmentedtickerplant`idb`discovery

\d .proc
loadprocesscode:1b                       // loads $KDBAPPCODE/wdb/vtwrite.q
