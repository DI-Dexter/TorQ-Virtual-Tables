// Virtual-table capture pack : compression config
// see docs/virtual-table-capture-pack.md §4.4 and §7

\d .cmp
hdbpath:hsym`$getenv`KDBHDB              // one database root - the writer writes where the
                                         // readers read, so this is the capture tree itself
maxage:365                               // oldest partition to consider. The lower bound is
                                         // minage in compressionconfig.csv, which must stay
                                         // >0 so the live partition is untouched

minfilesize:4096                         // skip column files this size or smaller: a file
                                         // already inside one filesystem block frees nothing
                                         // and only adds work to every read (doc §7.3).
                                         // 0 compresses everything, as stock TorQ does

// The hdbstructure override lives in code/processes/vtcompress.q, not here: settings files
// load BEFORE code/common/compress.q, so defining it here is silently overwritten and the
// job compresses nothing.
\d .
