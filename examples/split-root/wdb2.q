// 8.3.3 - stack 2's own root and its own enumeration domain.
// Copy to appconfig/settings/wdb2.q and set the path. TorQ loads settings in the order
// default -> parentproctype -> proctype -> procname, so this file applies to wdb2 alone.
\d .wdb
savedir:hdbdir:hsym`$"/path/to/data/db2"
symdomain:`symb                          // must differ per root: the reader binds a global
                                         // named after the file, so two roots both calling
                                         // theirs `sym collide silently (8.3.1)
\d .
