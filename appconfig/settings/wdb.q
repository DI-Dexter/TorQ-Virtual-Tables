// Virtual-table capture pack : WDB config
// see docs/virtual-table-capture-pack.md §3.3

\d .wdb
savedir:hdbdir:hsym`$getenv`KDBWDB       // one directory; sym file lives at its root. With
                                         // several stacks setenv.sh overrides both. §8.3
writedownmode:`partbyattr                // date + instrument directories. Not sufficient on
                                         // its own - it also writes the partition column into
                                         // the files. see code/wdb/vtwrite.q
mode:`saveandsort                        // the sort phase is overridden to a no-op. §4.2
immediate:1b                             // flush on every timer tick, ignore maxrows
settimer:0D00:00:01                      // ...every second
gc:0b                                    // at 1s cadence do not gc on every flush
rdbtypes:hdbtypes:gatewaytypes:()        // none of these processes exist
sorttypes:sortworkertypes:()
idbtypes:`idb
permitreload:0b                          // nothing to reload
sortcsv:hsym`$getenv[`KDBAPPCONFIG],"/sort.csv"
// Seed the partition from the business date. TorQ seeds it from .proc.cd[], the calendar
// date, which disagrees under a roll offset - and clearwdbdata[] deletes whatever it says.
//
// NOTE .eodtime is not loaded when this file runs, so the lookup sits inside the function.
startpartition:{[]
  d:@[{[x] .eodtime.getday .z.p};(::);{[e] .proc.cd[]}];
  (`date^@[value;`.wdb.partitiontype;`date])$d
  };

getpartition:{[] @[value;`.wdb.currentpartition;{[e] .wdb.startpartition[]}]};

tickerplantname:`                        // 8.3 - pin this writer to one tickerplant by name;
                                         // ` takes whichever is found first. Set from the
                                         // process file, but declared here so the override
                                         // has something to override

symdomain:`sym                           // this stack's enumeration domain file. One name per
                                         // root; set by setenv.sh when VTSTACKS>1. §8.3.1

\d .servers
CONNECTIONS:`segmentedtickerplant`idb`discovery

\d .proc
loadprocesscode:1b                       // loads $KDBAPPCODE/wdb/vtwrite.q
