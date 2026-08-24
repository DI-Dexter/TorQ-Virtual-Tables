/ What happens when the disk fills up? (4.5, 5.3, 9.3)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./vt-env.sh && q testfiles/vt-diskfull-test.q
/ .
/ This one needs a filesystem it can actually fill, so it re-runs itself inside a private mount
/ namespace with a small tmpfs in it. No root, and nothing outside that namespace is touched -
/ the mount does not even exist for other processes. If the kernel will not give us a user
/ namespace the test says so and stops rather than pretending.
/ .
/ A full disk is worth its own test because it is the one failure that hits the writer WHILE it
/ is writing, and this design has no staging area to fail into: the writer writes directly into
/ the directories readers are reading. So the questions are:
/ .
/   does the writer survive it, or does q die on a failed write
/   what is left on disk, and what does a reader make of it
/   is the data still in memory to retry, or is it gone
/   what does a retry actually do once space is free
/ .
/ The interesting answer is the third one. TorQ empties the in-memory table AFTER the upsert
/ loop, so an error that propagates leaves the data intact and the next flush retries it - but
/ the partitions written before the failure are written AGAIN, and nothing dedupes them.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

/ ---------------------------------------------------------------------------
/ re-run inside a private mount namespace, unless we are already in one
/ ---------------------------------------------------------------------------
if[not count getenv`VTFULLDIR;
  mnt:"/tmp/vt-diskfull-",string .z.i;
  outf:mnt,".out";
  system"mkdir -p ",mnt;
  / the child's output does not come back through system, so bash writes it to a file INSIDE
  / the -c string where the redirect is honoured. the file sits outside the tmpfs, which only
  / exists inside the namespace and goes away with it
  cmd:"unshare -rm bash -c \"mount -t tmpfs -o size=8M tmpfs ",mnt,
      " && VTFULLDIR=",mnt," ",getenv[`QCMD]," ",(string .z.f)," > ",outf," 2>&1\"";
  @[system;cmd;{[e] ::}];
  out:@[read0;hsym`$outf;{[e] ()}];
  system"rm -rf ",mnt," ",outf;
  if[not any {x like "*passed*"} each out;
    -1 "";
    -1 "  SKIPPED - could not create a private mount namespace on this kernel.";
    -1 "  this test needs unshare -rm to build a small filesystem it can fill.";
    if[count out; -1 each out];
    -1 "";
    exit 0];
  -1 each out;
  exit $[any {x like "*, 0 failed*"} each out; 0; 1]];

/ ---------------------------------------------------------------------------
/ from here on we are inside the namespace, on a filesystem of a few megabytes
/ ---------------------------------------------------------------------------
.lg.o:{[t;m]}; .lg.w:{[t;m] warns,:enlist m}; .lg.e:{[t;m] errs,:enlist m};
.servers.startupdepcycles:{[t;i;c] '"no wdb in this test"};
.servers.gethandlebytype:{[t;m] ()};
.timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};
warns:(); errs:();

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };
try:{[f;a] .[f;a;{[e] `$"ERR:",e}]};
/ `ok is a symbol and so is a trapped error - tell them apart by the text, not the type
failed:{[x] $[-11h=type x; x like "ERR:*"; 0b]};
saw:{[pat] $[count warns; any {[p;w] w like p}[pat] each warns; 0b]};

root:hsym`$getenv`VTFULLDIR;
(.Q.dd[root;`sym]) set 0#`;
d:2026.01.01;
rows:20000;
mktab:{[n] ([]time:n#.z.p; price:n?100f; side:n?`buy`sell)};
pdir:{[root;d;i] .Q.dd[.Q.dd[.Q.dd[root;`$string d];`trade];`$"I",string i]}[root;d];
write:{[root;pdir;i;t] try[{[root;pdir;i;t] (.Q.dd[pdir i;`]) set .Q.ens[root;t;`sym]; `ok}[root;pdir;i];enlist t]}[root;pdir];

-1 "";
-1 "  filesystem ",getenv`VTFULLDIR;
-1 "  ",last system"df -h ",getenv`VTFULLDIR;

/ ---------------------------------------------------------------------------
/ 1. fill it.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  RUNNING OUT OF SPACE";

r:{[write;mktab;rows;i] write[i;mktab rows]}[write;mktab;rows] each til 60;
broke:first where failed each r;
check[not null broke; "the filesystem did fill (",string[broke]," partitions written first)"];
check[(string r broke) like "*No space left on device*";
  "ENOSPC arrives as a normal q error naming the file, not as a signal"];
check[4=try[{[x] x+x};enlist 2]; "the process is alive - a failed write is an error, not a death"];
check[rows=try[{[p] count get .Q.dd[p;`]};enlist pdir 0];
  "and the partitions written before the failure are intact and readable"];

/ ---------------------------------------------------------------------------
/ 2. what it left behind.
/ this is a FOURTH kind of damage, on top of the three in vt-damage-test.q, and it is the
/ worst of them: .d promises columns that were never written. A lazy get accepts it without
/ complaint and even counts it, because a count reads one column.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  THE HALF-WRITTEN PARTITION";

bad:pdir broke;
named:get .Q.dd[bad;`.d];
present:key bad;
-1 "    .d names       ",.Q.s1 named;
-1 "    on disk        ",.Q.s1 present;
missing:named except present;
check[count missing; "the partition promises columns it does not have (",(.Q.s1 missing),")"];

v:try[{[p] get .Q.dd[p;`]};enlist bad];
check[not failed v; "and it still opens cleanly - get is lazy, so nothing fails here"];
check[rows=try[{[x] count x};enlist v];
  "it even counts correctly (",string[rows],") - a count reads only the first column"];
check[failed try[{[x] count select from x};enlist v];
  "the failure lands on the first query that touches a missing column"];

/ ---------------------------------------------------------------------------
/ 3. what a reader makes of it.
/ .
/ This partition is NOT detected. get is lazy, so it attaches like any other, and the failure
/ then belongs to the whole table rather than to the directory that caused it - every partition
/ has to be opened to answer a query that does not name an instrument.
/ .
/ The reader could check each partition against its own .d before accepting it. That was built
/ and then deliberately reverted (5.7): it costs ~45% of a rescan, the transient race that
/ produces this state without a full disk is rare and heals itself within one sweep, and in the
/ permanent case it would trade a loud failure for a reader that keeps answering while silently
/ omitting an instrument. A full disk means capture has already stopped. Queries failing is the
/ correct signal, not a defect to be masked.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  WHAT THE READER DOES WITH IT";

.vtidb.roots:enlist root;
.vtidb.partitioncol:`instrument;
warns:();
system"l ",getenv[`KDBAPPCODE],"/processes/vtidb.q";

check[(`$"I",string broke) in exec instrument from .vtidb.parts`trade;
  "the half-written partition ATTACHES - nothing about it looks wrong to the reader"];
check[not saw "*cannot open*"; "nothing is logged, because nothing failed at open time"];

n:try[{[] count select from trade};enlist(::)];
check[failed n;
  "a whole-database query then FAILS, and the error names the missing file, not the query"];
check[failed try[{[] count select time from trade};enlist(::)];
  "  - including one that never mentions a damaged column: every partition is opened regardless"];

one:try[{[] count select from trade where instrument=`I0};enlist(::)];
check[(not failed one) and rows=one;
  "a SELECTIVE query on a healthy instrument still works - the blast radius is bounded by ",
  "partition elimination, exactly as in vt-damage-test.q"];
check[failed try[{[i] count select from trade where instrument=i};enlist `$"I",string broke];
  "and a selective query on the damaged one fails, which is where an operator would look"];

/ ---------------------------------------------------------------------------
/ 4. is the data still in memory?
/ savetablesbypart upserts every partition and only THEN empties the table, and the pack's
/ override rethrows rather than swallowing. so a failure has to leave the rows where they were.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  IS THE DATA LOST?";

/ free enough room for a couple of partitions but not for all of them, so the save gets part
/ way through and then hits the wall - which is the case that matters. a save that fails on
/ its FIRST partition leaves nothing behind and nothing to reconcile
freeup:{[root;pdir;n] {[pdir;i] system"rm -rf ",1_string pdir i}[pdir] each n; };
freeup[root;pdir] 0 1 2;
targets:100 101 102 103;

buf:raze {[mktab;rows;i] update inst:i from mktab rows}[mktab;rows] each targets;
before:count buf;

/ savetablesbypart's own order: enumerate, upsert every partition, and only THEN empty the
/ table. the pack's upsert override rethrows rather than swallowing, so the error gets out
/ before that last step - which is the whole reason the data survives
saveall:{[root;pdir;targets;t]
  e:.Q.ens[root;t;`sym];
  {[root;pdir;e;i] .[{[p;x] p set x};(.Q.dd[pdir i;`];delete inst from select from e where inst=i);{[er] 'er}]}[root;pdir;e] each targets;
  @[`.;`buf;0#];
  };
res:try[{[f;targets;t] f[targets;t]; `ok}[saveall[root;pdir]];(targets;buf)];
check[failed res; "the save fails part way through - there is not room for all of it"];
check[before=count buf;
  "the rows are STILL IN MEMORY (",string[count buf],") - the error propagates before the ",
  "table is emptied, so the next flush retries them. a disk-full does not lose data"];

written:targets where {[pdir;i] 0<count key pdir i}[pdir] each targets;
check[0<count written;
  "but partitions written before the failure are already on disk (",(.Q.s1 written),")"];
if[count written;
  check[rows=try[{[p] count get .Q.dd[p;`]};enlist pdir first written];
    "  - complete, and readable"]];
-1 "    -> the retry re-upserts the WHOLE buffer, so those partitions get the same rows a";
-1 "       second time. nothing dedupes them. after a disk-full it is the partitions written";
-1 "       BEFORE the failure that need checking, not just the one that reported it.";

/ ---------------------------------------------------------------------------
/ 5. recovery.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  RECOVERY ONCE SPACE IS FREE";

/ the fill loop left every partition from the failure upwards incomplete, not just the one
/ that reported the error - clearing those is the operator's job, and the reader will go on
/ naming them until someone does it
{[pdir;i] system"rm -rf ",1_string pdir i}[pdir] each (broke+1)+til 59-broke;
freeup[root;pdir] 3 4 5,targets;
free:"J"$first system"df -k ",getenv[`VTFULLDIR]," | tail -1 | awk '{print $4}'";
check[0<free; "space is available again (",string[free]," KB)"];

fixed:write[broke;mktab rows];
check[not failed fixed; "the failed partition can simply be written again"];
warns:();
.vtidb.dropcache[];
.vtidb.rebuild[];
check[(`$"I",string broke) in exec instrument from .vtidb.parts`trade;
  "the rewritten partition is attached on the next rebuild, with no restart"];
check[not failed try[{[] count select from trade};enlist(::)];
  "and the database is whole again"];

-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
exit $[fail>0;1;0]
