/ Does the writer delete the partition it is actually filling? (4.7, recovery)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./vt-env.sh && q testfiles/vt-partition-test.q
/ .
/ A writer restart is destructive before it is restorative. TorQ deletes the current partition
/ and then rebuilds it by replaying the tickerplant log:
/ .
/     upd:.wdb.replayupd;
/     .wdb.clearwdbdata[];      / deletes savedir/<getpartition[]>/
/     .wdb.startup[];           / subscribe -> replay the day's logs
/ .
/ Which makes getpartition[] load-bearing at exactly one moment: process start, before anything
/ has told the writer what date the tickerplant is on. TorQ seeds it from .proc.cd[], the
/ CALENDAR date. With a roll offset the tickerplant is on a different date - under this pack's
/ 17:00 roll they disagree from midnight until the roll - so the delete misses, the real
/ partition survives untouched, and the replay writes the whole day on top of it. Every row
/ already on disk is duplicated. Measured on the live stack: 442 duplicate rows from one
/ restart, all inside the replayed window.
/ .
/ fixpartition does correct currentpartition afterwards, from the tp log date. It is too late:
/ clearwdbdata has already run, and its corrective branch only fires when the WRONG directory
/ exists, to rename it. When the wrong date simply has no directory, nothing is cleaned.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

/ enough of TorQ for the date logic to run standalone. the REAL eodtime.q is loaded rather
/ than a copy of its formula, so this tests what the writer actually runs - which means
/ supplying the two framework hooks timezone.q reaches for on the way in.
.proc.cd:{[] .z.d};
.lg.o:{[t;m]}; .lg.w:{[t;m]}; .lg.e:{[t;m] -2 "  ",m;};
/ NOTE returns SYMBOLS - timezone.q does `string first ...`, and a string there would be
/ decomposed one character per element
.proc.getconfigfile:{[f] enlist `$getenv[`KDBCONFIG],"/",f};
system"l ",getenv[`KDBCODE],"/common/timezone.q";
system"l ",getenv[`KDBCODE],"/common/eodtime.q";

\d .wdb
partitiontype:`date;
/ the two definitions under test, lifted verbatim from appconfig/settings/wdb.q
startpartition:{[]
  d:@[{[x] .eodtime.getday .z.p};(::);{[e] .proc.cd[]}];
  (`date^@[value;`.wdb.partitiontype;`date])$d
  };
getpartition:{[] @[value;`.wdb.currentpartition;{[e] .wdb.startpartition[]}]};
/ what TorQ does today, for comparison
stockpartition:{[] @[value;`.wdb.currentpartition;(`date^partitiontype)$.proc.cd[]]};
\d .

/ set a roll offset and recompute the way a process would at startup
setroll:{[off]
  .eodtime.rolltimeoffset:off;
  .eodtime.d:.eodtime.getday .z.p;        / the tickerplant's log date, as it computes it
  };

-1 "";
-1 "  now  ",(string .z.p)," UTC   calendar date ",string .proc.cd[];

/ ---------------------------------------------------------------------------
/ 1. no roll configured - the default. nothing may change.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  NO ROLL OFFSET - the stock configuration";
setroll 0D00:00;
-1 "    tickerplant logs to   ",string .eodtime.d;
-1 "    writer would seed     ",string .wdb.startpartition[];
check[.wdb.startpartition[]=.eodtime.d;
  "the writer seeds the same date the tickerplant is logging to"];
check[.wdb.startpartition[]=.eodtime.getday .z.p; "  - which is the plain date, no adjustment"];

/ ---------------------------------------------------------------------------
/ 2. a roll offset, chosen so that right now falls in the pre-roll window whatever
/ time this test is run at. that is the window where the bug bites.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  ROLL OFFSET IN FORCE - now is before today's roll";
/ put the roll comfortably after the current time so the business date is still yesterday
/ time-of-day plus an hour, so the roll is always still ahead of us whatever time this runs
off:0D01:00+.z.p-"p"$"d"$.z.p;
setroll off;
-1 "    roll offset           ",string off;
-1 "    tickerplant logs to   ",string .eodtime.d;
-1 "    calendar date         ",string .proc.cd[];
check[not .eodtime.d=.proc.cd[];
  "the two really do disagree - this is the state the pack runs in for most of the day"];
check[.wdb.startpartition[]=.eodtime.d;
  "the writer still seeds the tickerplant's date, not the calendar's"];
check[not .wdb.stockpartition[]=.eodtime.d;
  "REGRESSION GUARD: stock TorQ seeds ",(string .wdb.stockpartition[]),
  " here, which is the wrong directory to delete"];

/ ---------------------------------------------------------------------------
/ 3. once the writer knows its partition, that answer wins - so the end-of-day
/ roll (currentpartition::pt+1) is not undone on the next flush.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  AFTER THE WRITER HAS A PARTITION";
.wdb.currentpartition:2030.01.01;
check[.wdb.getpartition[]=2030.01.01;
  "getpartition returns the writer's own partition once it is set"];
check[not .wdb.getpartition[]=.eodtime.d; "  - and does not fall back to the date logic"];
.wdb.currentpartition:2030.01.02;
check[.wdb.getpartition[]=2030.01.02; "an end-of-day roll therefore sticks"];
![`.wdb;();0b;enlist`currentpartition];

/ ---------------------------------------------------------------------------
/ 4. it must not need .eodtime at all.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  WITHOUT .eodtime LOADED";
saved:.eodtime.getday;
![`.eodtime;();0b;enlist`getday];
check[.wdb.startpartition[]=.proc.cd[];
  "falls back to the calendar date rather than failing to start"];
.eodtime.getday:saved;
check[.wdb.startpartition[]=.eodtime.getday .z.p; "and recovers once it is back"];

/ ---------------------------------------------------------------------------
/ 5. the consequence, stated as the thing an operator would see: which directory
/ does a restart delete?
/ ---------------------------------------------------------------------------
-1 "";
-1 "  WHICH DIRECTORY A RESTART WOULD DELETE";
setroll off;
s:"/tmp/vt-partition-",string .z.i;
system"rm -rf ",s; system"mkdir -p ",s,"/",string .eodtime.d;
.wdb.savedir:hsym`$s;
target:{[pt] .Q.par[.wdb.savedir;pt;`]};
-1 "    data is in            ",1_string target .eodtime.d;
-1 "    stock would delete    ",1_string target .wdb.stockpartition[];
-1 "    this pack deletes     ",1_string target .wdb.startpartition[];
check[()~key target .wdb.stockpartition[];
  "stock targets a directory that does not exist - so it deletes NOTHING, and the replay ",
  "then duplicates everything already written"];
check[not ()~key target .wdb.startpartition[];
  "this pack targets the directory that actually holds the data, so the replay rebuilds it"];
system"rm -rf ",s;

-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
exit $[fail>0;1;0]
