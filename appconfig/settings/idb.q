// Virtual-table capture pack : IDB config
// see docs/virtual-table-capture-pack.md §5

\d .vtidb
roots:enlist hsym`$getenv`KDBDB          // database roots to scan. a list rather than an atom
                                         // so one reader can serve several capture stacks (§8.3)
tabs:`                                   // ` = discover the table list from disk. Scans the
                                         // live partition only once the catalogue is warm, so
                                         // the cost does not grow with retention. A table
                                         // added to an already-rolled date needs dropcache[]
                                         // (6.1). Set explicitly to restrict, e.g. `trade
historydays:0W                           // how many days back to attach. 0W = everything
sweep:0D00:00:30                         // backstop rescan. The primary path is the wdb's
                                         // notification (§4.1); this only bounds a dropped
                                         // message, so it is deliberately slack
symsweep:0D00:00:01                      // how often to check the enumeration domain. A new
                                         // symbol VALUE in an existing partition creates no
                                         // directory, so the writer never announces it and it
                                         // reads as null until reloaded (§5.4). One hcount per
                                         // root, so this can be fast

partitioncol:`sym                       // name the partition column is exposed under. Not
                                         // stored on disk, so it cannot be derived: it must
                                         // match the schema or client queries will not port
wdbtypes:`wdb
wdbcheckcycles:3                         // wait this many cycles for the wdb, then start
wdbconnsleepintv:5                       // anyway - without a writer the sweep keeps the
                                         // reader current, just slower

\d .servers
CONNECTIONS:`wdb`discovery               // wdb: to register for new-partition notifications
STARTUP:1b

\d .proc
loadprocesscode:0b                       // process code comes from -load, not $KDBAPPCODE/idb/
