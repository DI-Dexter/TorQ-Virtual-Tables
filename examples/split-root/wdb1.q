// 8.3.3 - stack 1's own root and its own enumeration domain.
// Copy to appconfig/settings/wdb1.q and set the path. TorQ loads settings in the order
// default -> parentproctype -> proctype -> procname, so this file applies to wdb1 alone.
\d .wdb
savedir:hdbdir:hsym`$"/path/to/data/db1"
symdomain:`syma                          // must differ per root: the reader binds a global
                                         // named after the file, so two roots both calling
                                         // theirs `sym collide silently (8.3.1)
\d .
