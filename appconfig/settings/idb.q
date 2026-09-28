// Virtual-table capture pack : IDB config
// see docs/virtual-table-capture-pack.md §5

\d .vtidb
roots:enlist hsym`$getenv`KDBDB          // database roots to scan. A list, so one reader can
                                         // serve several capture stacks. §8.3
tabs:`                                   // ` = discover the table list from disk. Set
                                         // explicitly to restrict, e.g. `trade
historydays:0W                           // how many days back to attach. 0W = everything
sweep:0D00:00:30                         // backstop rescan behind the wdb's notification;
                                         // deliberately slack. §4.1
symsweep:0D00:00:01                      // how often to reload the enumeration domain; a new
                                         // symbol value announces nothing. §5.4

partitioncol:`sym                        // name the partition column is exposed under. Not
                                         // stored on disk, so it must match the schema
multiwriter:@[value;`multiwriter;0b]     // hold the live partition at the earliest date any
                                         // writer still has open. One round trip per writer
                                         // per rebuild, so off for a single writer. §8.3
writertimeout:@[value;`writertimeout;1000]   // ms to wait for a writer's answer

wdbtypes:`wdb
wdbcheckcycles:3                         // cycles to wait for a wdb before starting anyway
wdbconnsleepintv:5

\d .servers
CONNECTIONS:`wdb`discovery               // wdb: to register for new-partition notifications
STARTUP:1b

\d .proc
loadprocesscode:0b                       // process code comes from -load, not $KDBAPPCODE/idb/
