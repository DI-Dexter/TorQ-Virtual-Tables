/ Can the reader start up in the middle of a write, and recover? (5.1, 5.3, 6.1)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-restart-test.q
/ .
/ A reader is restarted at whatever moment the operator restarts it, which is not a moment the
/ writer knows about. So it can arrive while a flush is half-done: a directory that has been
/ made but not filled, a partition whose columns are still being extended, a table directory
/ that exists for trade but not yet for quote.
/ .
/ None of that has to be handled perfectly - the writer will finish a moment later. What it
/ has to do is HEAL: whatever the reader could not read at startup, it must pick up on a later
/ sweep without anyone intervening. That property rests entirely on one variable. .vtidb.current
/ is the partition the writer is filling, and it decides which dates get rescanned (mutable) and
/ which are cached forever (immutable). Get it wrong and the reader stops looking at the very
/ date that is still growing - and says nothing, because from its point of view there is
/ nothing to report.
/ .
/ The last section is the one that matters. It covers the case where the reader cannot ask the
/ writer what partition it is on, which is exactly the case a restart hits: the reader comes up
/ first, or comes up alone.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

.lg.o:{[t;m]}; .lg.w:{[t;m] warns,:enlist m}; .lg.e:{[t;m] errs,:enlist m};
.servers.startupdepcycles:{[t;i;c] '"no wdb in this test"};
.servers.gethandlebytype:{[t;m] ()};
.timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};
warns:(); errs:();
/ warns is emptied between sections, and () like "..." is a type error rather than a false.
/ NOTE `like` takes ONE string, so a list of them has to be walked - x like p over a
/ two-element list of strings is a type error, over a one-element list it is not, which is
/ exactly the shape of bug that passes until a second warning shows up
saw:{[pat] $[count warns; any {[p;w] w like p}[pat] each warns; 0b]};

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };
try:{[f;a] .[f;a;{[e] `$"ERR:",e}]};

s:"/tmp/vt-restart-",string .z.i;
system"rm -rf ",s; system"mkdir -p ",s;
root:hsym`$s;
(.Q.dd[root;`sym]) set 0#`;

live:2026.08.18;                        / the date the writer is filling
past:2026.08.17;                        / a date that has already rolled

tdir:{[root;d;t;i] .Q.dd[.Q.dd[.Q.dd[root;`$string d];t];`$"I",string i]}[root];
mk:{[root;tdir;d;t;i;n]
  x:([]time:n#.z.p; price:n?100f; side:n?`buy`sell);
  (.Q.dd[tdir[d;t;i];`]) set .Q.ens[root;x;`sym];
  }[root;tdir];

mk[past;`trade;] ./: (0 5;1 5;2 5);
mk[live;`trade;] ./: (0 5;1 5;2 5);
mk[past;`quote;] ./: (0 5;1 5;2 5);
mk[live;`quote;] ./: (0 5;1 5;2 5);

.vtidb.roots:enlist root;
.vtidb.partitioncol:`instrument;
system"l ",getenv[`KDBAPPCODE],"/processes/vtidb.q";

/ a reader restart, without re-loading the file: forget everything learned and rescan
restart:{[cur] warns::(); errs::(); .vtidb.dropcache[]; .vtidb.current:cur; .vtidb.rebuild[]; };

-1 "";
-1 "  scratch ",s;

/ ---------------------------------------------------------------------------
/ 1. a directory that exists but has nothing in it yet.
/ mkdir happens before the columns are written, so this is the state a reader sees if it scans
/ between the two. it must not take the process down, and it must not poison the other
/ partitions of the same table.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  STARTED MID-FLUSH - a directory made, not yet filled";

system"mkdir -p ",1_string tdir[live;`trade;7];
restart live;
n:.vtidb.parts`trade;
check[0=count errs; "an empty partition directory does not error the reader"];
check[saw "*unreadable*"; "it is reported as unreadable, not passed over in silence"];
check[6=count n; "the other 6 partitions attach normally - one bad directory is not contagious"];
check[30=try[{[] count select from trade};enlist(::)]; "and every row of them is served"];

/ now the writer finishes that directory. no restart, no dropcache - just the next sweep
mk[live;`trade;7;5];
.vtidb.rebuild[];
check[7=count .vtidb.parts`trade; "the next rebuild picks it up - the reader heals by itself"];
check[35=try[{[] count select from trade};enlist(::)]; "with its rows"];

/ ---------------------------------------------------------------------------
/ 2. a partition caught mid-append.
/ the columns are written one at a time, so a reader that starts here sees a directory whose
/ column files disagree in length. vt-inflight-test.q establishes that this reads as a short
/ but consistent prefix; what matters on the restart path is that the reader does not CACHE
/ that short answer.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  STARTED MID-APPEND - a partition whose columns are different lengths";

pfile:.Q.dd[tdir[live;`trade;0];`price];
full:hcount pfile;
system"truncate -s ",string[8*2]," ",1_string pfile;      / price now holds 2 of 5 rows
restart live;
short:try[{[] count select from trade};enlist(::)];
check[35>short; "the ragged partition is served short (",string[short]," of 35 rows)"];
check[0=count errs; "and still without an error - this is the quiet one"];

system"truncate -s ",string[full]," ",1_string pfile;     / the writer finishes the column
check[35=try[{[] count select from trade};enlist(::)];
  "when the column catches up the rows appear with NO rebuild at all - a live view has no ",
  "length cached in it (5.2)"];

/ ---------------------------------------------------------------------------
/ 3. one table flushed, the other not.
/ savetables walks the tables in order, so between them a partition has trade and no quote.
/ 4.6 established that this is served as a silently absent date; on the restart path the
/ requirement is that it is at least SAID.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  STARTED BETWEEN TABLES - trade written for a date, quote not yet";

mk[2026.08.19;`trade;] ./: (0 5;1 5);
restart live;
check[saw "*coverage gap*";
  "a date with trade but no quote is reported as a coverage gap (4.6)"];
check[2026.08.19 in exec date from .vtidb.parts`trade; "trade serves the new date"];
check[not 2026.08.19 in exec date from .vtidb.parts`quote; "quote does not - correctly, it has no data"];

mk[2026.08.19;`quote;] ./: (0 5;1 5);
warns:();                               / NOT warns:: - at top level that defines a view
.vtidb.rebuild[];
check[2026.08.19 in exec date from .vtidb.parts`quote; "and it heals when the writer catches up"];
check[not saw "*coverage gap*"; "the gap stops being reported once it closes"];

/ ---------------------------------------------------------------------------
/ 4. the reader cannot ask the writer which partition is live.
/ .
/ THIS IS THE ONE. On restart the reader calls findwdb, and it can come back empty - the
/ writer is down, or the reader came up first, or the read of .wdb.currentpartition failed.
/ The reader then has to decide for itself which date is live, and that decision is not
/ cosmetic: an immutable date is cached and never looked at again.
/ .
/ .z.D is the wrong answer, and wrong in the normal case rather than an exotic one. This pack
/ rolls at 17:00 local (0D09:00 in GMT, see appconfig/settings/default.q), so from midnight
/ until the roll the writer is still filling YESTERDAY while .z.D already says today. A reader
/ that guesses .z.D marks the live partition immutable, caches it, and every instrument that
/ starts trading after that point is invisible - present on disk, absent from every query, with
/ nothing in the log.
/ .
/ The date on disk is knowable without asking anyone: it is the latest one there.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  NO WRITER TO ASK - which date does the reader think is live?";

/ a second root, dated relative to today, so this reproduces the pre-roll window on any day:
/ the writer is filling YESTERDAY while .z.D already says today
r2:hsym`$s,"/preroll";
system"mkdir -p ",1_string r2;
(.Q.dd[r2;`sym]) set 0#`;
mk2:{[r2;d;i]
  x:([]time:5#.z.p; price:5?100f; side:5?`buy`sell);
  (.Q.dd[.Q.dd[.Q.dd[.Q.dd[r2;`$string d];`trade];`$"I",string i];`]) set .Q.ens[r2;x;`sym];
  }[r2];
writerpart:.z.D-1;                      / the partition the writer is on before the 17:00 roll
mk2[.z.D-2;] each til 2;
mk2[writerpart;] each til 2;

/ drive the REAL startup path rather than setting state by hand - init is where the live
/ partition is decided, and findwdb below it will come back empty in this mock
.vtidb.roots:enlist r2;
.vtidb.dropcache[];
.vtidb.current:0Nd;
warns:();
.vtidb.init[];

-1 "    .z.D                    ",string .z.D;
-1 "    writer is filling       ",string writerpart;
-1 "    reader believes live is ",string .vtidb.current;
check[.vtidb.current=writerpart;
  "started with no writer, the reader takes the live partition from DISK, not from .z.D"];
check[not .vtidb.current=.z.D;
  "  - which in the pre-roll window is a different date, and the one that matters"];

/ the consequence, which is what an operator would actually notice - or rather, would not
was:count .vtidb.parts`trade;
mk2[writerpart;99];
.vtidb.rebuild[]; .vtidb.rebuild[];
check[was<count .vtidb.parts`trade;
  "a new instrument on the writer's partition is picked up (",string[was]," -> ",
  string[count .vtidb.parts`trade],"). believing that date had rolled would CACHE it, and ",
  "the instrument would sit on disk absent from every query with nothing logged"];

/ and it has to keep following the disk, or the same freeze returns tomorrow
mk2[.z.D;0];
.vtidb.rebuild[];
check[.vtidb.current=.z.D; "the live partition follows the disk forward with no rollover call"];
was2:count .vtidb.parts`trade;
mk2[.z.D;1];
.vtidb.rebuild[];
check[was2<count .vtidb.parts`trade; "and the new date goes on growing after the move"];

/ the other direction: a writer that has rolled but not yet flushed is AHEAD of the disk, and
/ that answer has to be kept - clamping it back to the disk would un-close the closed date
.vtidb.current:.z.D+1;
.vtidb.rebuild[];
check[.vtidb.current=.z.D+1;
  "a writer that has rolled but not yet written stays ahead of the disk - the disk is a ",
  "lower bound, not an override"];

-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
system"rm -rf ",s;
exit $[fail>0;1;0]
