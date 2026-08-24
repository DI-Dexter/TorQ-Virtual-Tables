// Virtual-table capture pack : IDB config
// see docs/virtual-table-capture-pack.md §5

\d .vtidb
roots:enlist hsym`$getenv`KDBDB          // database roots to scan. a list rather than an atom
                                         // so one reader can serve several capture stacks (§8.3)
tabs:`                                   // ` = discover the table list from disk. the scan looks
                                         // at the LIVE partition only (every date once, when
                                         // the catalogue is empty), so it does not grow with
                                         // retention. a table added to a date that has already
                                         // rolled needs dropcache[] - see 6.1.
                                         // set explicitly to restrict, e.g. `trade
historydays:0W                           // how many days back to attach. 0W = everything
sweep:0D00:00:30                         // backstop rescan. the primary path is a notification
                                         // from the wdb (§4.1); this only bounds the damage
                                         // from a dropped message, so it is deliberately slack
symsweep:0D00:00:01                      // how often to check whether the enumeration domain
                                         // has grown. a new value in a data symbol column of
                                         // an EXISTING partition creates no directory, so the
                                         // writer never announces it, and the value reads as
                                         // null until the domain is reloaded (§5.4). the check
                                         // is one hcount per root, so this can be fast

partitioncol:`sym                       // name the partition column is exposed under.
                                         // the reader cannot derive it - the column is not
                                         // stored on disk - so it must match the schema's
                                         // name, or client queries will not port across
wdbtypes:`wdb
wdbcheckcycles:3                         // wait this many cycles for the wdb, then start anyway.
wdbconnsleepintv:5                       // the reader does not need the writer to function -
                                         // without it the sweep keeps it current, just slower

\d .servers
CONNECTIONS:`wdb`discovery               // wdb: to register for new-partition notifications
STARTUP:1b

\d .proc
loadprocesscode:0b                       // process code comes from -load, not $KDBAPPCODE/idb/
