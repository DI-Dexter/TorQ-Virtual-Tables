// Virtual-table capture pack : compression config
// see docs/virtual-table-capture-pack.md §4.4 and §7

\d .cmp
hdbpath:hsym`$getenv`KDBHDB              // one database root - the writer writes where the
                                         // readers read, so this is the capture tree itself
maxage:365                               // oldest partition to consider. the lower bound is
                                         // minage in compressionconfig.csv - the age tier -
                                         // and must stay >0 so the live partition is untouched

minfilesize:4096                         // the size gate: skip any column file this size or
                                         // smaller. a file is allocated in whole filesystem
                                         // blocks, so one that already fits in a block frees
                                         // nothing and only adds work to every read. measured
                                         // at 400 of 750 files - roughly half of
                                         // them - on the reference partition (doc §7.3).
                                         // set 0 to compress everything, as stock TorQ does

// the hdbstructure override that teaches compression to see this layout is NOT here, even
// though it is configuration in spirit. settings files load ~13 ms BEFORE code/common/
// compress.q, so anything defined here is silently overwritten by the stock definition and
// the job compresses nothing. it lives in code/processes/vtcompress.q instead, which is
// loaded after common code.
\d .
