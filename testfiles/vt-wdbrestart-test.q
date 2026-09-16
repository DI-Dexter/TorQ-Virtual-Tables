/ What does a reader serve while the writer is rebuilding the day? (4.7, 5.3, recovery)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-wdbrestart-test.q
/ .
/ A writer restart is not a quiet event on disk. It DELETES the whole live date directory and
/ then rebuilds it by replaying the tickerplant log - which for a full day is hundreds of
/ milliseconds of directories reappearing one at a time. The reader is not told any of this. It
/ is holding a catalogue of live views that point straight into the directory that just went
/ away, and its sweep will fire somewhere in the middle.
/ .
/ So there are three distinct states a query can land in, and they are not the same:
/ .
/   deleted, not yet rescanned   the catalogue still lists partitions that no longer exist
/   deleted, rescanned           the reader knows they are gone
/   half rebuilt                 some partitions are back, some are not, one may be mid-write
/ .
/ The question that matters is not whether a query can fail - it obviously can, the data is
/ genuinely absent for a moment - but whether it can come back WRONG. A short answer that
/ completes itself is a different thing from a plausible answer that is quietly missing rows.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

.lg.o:{[t;m]}; .lg.w:{[t;m] warns,:enlist m}; .lg.e:{[t;m] errs,:enlist m};
.servers.startupdepcycles:{[t;i;c] '"no wdb in this test"};
.servers.gethandlebytype:{[t;m] ()};
.timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};
warns:(); errs:();

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };
try:{[f;a] .[f;a;{[e] `$"ERR:",e}]};
failed:{[x] $[-11h=type x; x like "ERR:*"; 0b]};
q:{[s] try[{[x] value x};enlist s]};

s:"/tmp/vt-wdbrestart-",string .z.i;
system"rm -rf ",s; system"mkdir -p ",s;
root:hsym`$s;
(.Q.dd[root;`sym]) set 0#`;
d:2026.01.02;
past:2026.01.01;
insts:`$"I",/:string til 12;
rows:50;

mk:{[root;rows;dt;t;i]
  x:([]time:rows#.z.p; price:rows?100f; side:rows?`buy`sell);
  (.Q.dd[.Q.dd[.Q.dd[.Q.dd[root;`$string dt];t];i];`]) set .Q.ens[root;x;`sym];
  }[root;rows];

/ yesterday, closed and immutable - a writer restart must never touch it
mk[past;`trade;] each insts;
mk[past;`quote;] each insts;
/ today, the live partition
mk[d;`trade;] each insts;
mk[d;`quote;] each insts;

.vtidb.roots:enlist root;
.vtidb.partitioncol:`instrument;
system"l ",getenv[`KDBAPPCODE],"/processes/vtidb.q";
.vtidb.current:d;
.vtidb.dropcache[]; .vtidb.rebuild[];

full:count[insts]*rows;
-1 "";
-1 "  ",string[count insts]," instruments x ",string[rows]," rows, on ",(string past)," and ",string d;
-1 "  baseline today ",string q"count select from trade where date=",string d;

check[full=q"count select from trade where date=",string d; "baseline is correct"];
check[(2*full)=q"count select from trade"; "and both dates are attached"];

/ ---------------------------------------------------------------------------
/ 1. the moment after clearwdbdata: the directory is gone, the catalogue is not.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  DELETED, NOT YET RESCANNED - the catalogue points at directories that are gone";
system"rm -rf ",s,"/",string d;

n:q"count select from trade where date=",string d;
-1 "    today             ",$[failed n; string n; string n];
y:q"count select from trade where date=",string past;
-1 "    yesterday         ",$[failed y; string y; string y];

check[failed n; "a query for the deleted date FAILS - loudly, naming the missing file"];
check[(not failed y) and full=y;
  "but yesterday is untouched and still exact - the blast radius is the live date only"];
check[failed q"count select from trade";
  "a whole-database query fails too, because it has to open every partition"];
-1 "    -> this is the state that matters most, and it errors rather than under-reporting.";
-1 "       a client sees an exception, not a plausible number that is quietly short.";

/ ---------------------------------------------------------------------------
/ 2. the sweep runs while the directory is still empty.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  DELETED, RESCANNED - the sweep has caught up with the deletion";
warns:(); errs:();
.vtidb.rebuild[];
check[not failed q"count select from trade"; "queries answer again once the sweep has run"];
check[full=q"count select from trade"; "and return exactly yesterday, with today absent"];
check[0=count .vtidb.parts[`trade] where .vtidb.parts[`trade][`date]=d;
  "the deleted date is dropped from the catalogue entirely"];
check[not any {x like "*coverage gap*"} each warns;
  "4.6's coverage check stays silent - and correctly so: it compares dates ACROSS tables, and a ",
  "writer restart removes the date from every table at once. a symmetric loss is invisible to it"];

/ ---------------------------------------------------------------------------
/ 3. the replay puts partitions back, one at a time, with the sweep firing in between.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  HALF REBUILT - the sweep fires while the replay is still running";
seen:();
{[mk;d;insts;i]
  mk[d;`trade;insts i];
  mk[d;`quote;insts i];
  .vtidb.rebuild[];                                  / the sweep, landing mid-replay
  r:q"count select from trade";
  seen,:enlist (i; $[failed r; -1; r]);
  }[mk;d;insts] each til count insts;

got:{x 1} each seen;
-1 "    rows seen as partitions came back: ",.Q.s1 got;
check[not any got=-1; "no query errored while the replay was in progress"];
check[got~asc got; "every answer was larger than the last - monotonic, never going backwards"];
check[all got>=full; "and never below yesterday's total, which was never at risk"];
check[(2*full)=last got; "the last one is the complete database again"];

/ ---------------------------------------------------------------------------
/ 4. the sharper case: the sweep lands while a partition is MID-WRITE, with .d
/ already on disk and its columns not. this is the state 5.7 documents, reached
/ here the way a replay would reach it rather than by a full disk.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  MID-WRITE - .d is on disk, the columns are not yet";
half:.Q.dd[.Q.dd[.Q.dd[root;`$string d];`trade];`HALF];
system"mkdir -p ",1_string half;
(.Q.dd[half;`.d]) set `time`price`side;              / promises three columns, has none
warns:(); errs:();
.vtidb.rebuild[];
r:q"count select from trade";
check[failed r;
  "a whole-database query fails while that partition is mid-write - the reader cannot ",
  "tell it apart from a permanently damaged one (5.7)"];
sel:q"count select from trade where date=",(string d),", instrument=`I0";
check[(not failed sel) and rows=sel;
  "a SELECTIVE query on a healthy instrument is unaffected - partition elimination again"];

/ and it clears itself the moment the writer finishes that directory
mk[d;`trade;`HALF];
check[not failed q"count select from trade";
  "and it resolves as soon as the columns land, with no rebuild and no intervention"];

-1 "";
-1 "  WHAT THIS ADDS UP TO";
-1 "";
-1 "  Only the FIRST state is loud. Once the sweep has run, the reader is serving a database";
-1 "  that is genuinely missing today - and it answers, with a number that looks perfectly";
-1 "  reasonable. The same is true all the way through the replay: 650 rows when the true";
-1 "  figure is 1200 is not an error, it is a short answer, and nothing marks it as one.";
-1 "";
-1 "  So a writer restart opens a window - the replay time plus up to one sweep interval -";
-1 "  in which whole-database aggregates under-report silently. Selective queries on";
-1 "  instruments already rebuilt are exact throughout, and history is never at risk.";
-1 "";
-1 "  That is a property of restarting the writer, not a defect in the reader: the rows really";
-1 "  are absent from disk while the replay runs. It is worth knowing before scheduling a";
-1 "  writer restart underneath something that reports numbers to people.";
-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
system"rm -rf ",s;
exit $[fail>0;1;0]
