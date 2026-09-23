// 8.3.3 - one reader serving BOTH roots. Copy to appconfig/settings/idb2.q.
// .vtidb.roots is a list; alldates rakes datedirs over every entry, so the reader holds ONE
// live partition across all of them - which is why .vtidb.multiwriter is still required here.
\d .vtidb
roots:(hsym`$"/path/to/data/db1";hsym`$"/path/to/data/db2")
\d .
