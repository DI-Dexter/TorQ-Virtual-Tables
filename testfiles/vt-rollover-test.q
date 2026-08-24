/ Does end of day still see everything, now that it no longer rescans history? (VT-17)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./vt-env.sh && q testfiles/vt-rollover-test.q
/ .
/ rollover used to call dropcache[], so correctness at end of day was free - every date was
/ rescanned. It now forgets only the date that just closed. That is safe only if the drop
/ happens BEFORE current moves forward: once current is the new date, the closing date reads
/ as immutable and build would reuse its catalogue as-is.
/ .
/ This builds a scratch tree, creates a directory the reader has not scanned, rolls over, and
/ checks the rows are there. Written to FAIL against the naive version of this change - simply
/ deleting the dropcache[] call - which loses that last directory silently and for good.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

/ enough of the TorQ framework for vtidb.q to load standalone
.lg.o:{[t;m]}; .lg.w:{[t;m]}; .lg.e:{[t;m]};
.servers.startupdepcycles:{[t;i;c] '"no wdb in this test"};
.servers.gethandlebytype:{[t;m] ()};
.timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

live:getenv`KDBDB;
scratch:"/tmp/vt-rollover-",string .z.i;
d0:2026.01.01; d1:2026.01.02; d2:2026.01.03;

src:first asc key[hsym`$live] where key[hsym`$live] like "[0-9][0-9][0-9][0-9].*";
if[null src; -1 "no partitions under ",live," - start the stack first"; exit 77];

system"rm -rf ",scratch; system"mkdir -p ",scratch;
system"cp ",live,"/sym ",scratch,"/";
{[live;src;scratch;d] system"cp -r ",live,"/",(string src)," ",scratch,"/",string d}[live;src;scratch] each d0,d1;

.vtidb.roots:enlist hsym`$scratch;
system"l ",getenv[`KDBAPPCODE],"/processes/vtidb.q";
pc:.vtidb.partitioncol;

/ d1 is the live partition, d0 is closed history
.vtidb.current:d1;
.vtidb.dropcache[]; .vtidb.rebuild[];

-1 "";
-1 "  scratch    ",scratch;
-1 "  dates      ",.Q.s1 asc distinct raze .vtidb.coverage[];
-1 "  live       ",string .vtidb.current;
-1 "";

tabs:key .vtidb.parts;
newi:`ZZLATE;

/ the writer's last flush of the day: a brand new instrument directory on the live date, with
/ no notification, so the reader's catalogue does not know about it yet.
/ the donor must come from the SAME table - a virtual table cannot span two column layouts,
/ and seeding one table's directory from another's gives a value error on the missing column
{[scratch;d1;newi;t]
  donor:first exec path from .vtidb.parts[t] where date=d1;
  system"cp -r ",(1_string donor)," ",scratch,"/",(string d1),"/",(string t),"/",string newi
  }[scratch;d1;newi] each tabs;
-1 "  created    ",(string d1),"/*/",(string newi)," on disk, reader NOT told";

/ two different questions, and conflating them is a trap here: a table can be attached and
/ still have no rows (a table can be idle in a short run). check the catalogue for every
/ table, and the rows only for one that actually holds some.
attached:{[pc;newi;t] newi in .vtidb.parts[t] pc};
rows:{[pc;newi;t] 0<count value "select from ",string[t]," where ",string[pc],"=`",string newi};
withdata:first tabs where {[t] 0<count value "select from ",string t} each tabs;

check[not any attached[pc;newi] each tabs; "the new directory is invisible before any rebuild, as expected"];

/ end of day arrives before the reader ever rescanned the live date
.vtidb.rollover[d2];

-1 "";
-1 "  rolled to  ",string .vtidb.current;
-1 "";

check[all attached[pc;newi] each tabs;
  "the late directory is attached after rollover (all ",string[count tabs]," tables)"];
check[rows[pc;newi;withdata];
  "and its rows come back through the virtual table (",string[withdata],")"];

check[d0 in exec date from .vtidb.parts[first tabs]; "closed history is still attached"];
check[d1 in exec date from .vtidb.parts[first tabs]; "the date that just closed is still attached"];

/ history must have been REUSED, not rescanned: its opened views are the same objects
before:.vtidb.opened[first tabs] where d0=.vtidb.parts[first tabs]`date;
.vtidb.rebuild[];
after:.vtidb.opened[first tabs] where d0=.vtidb.parts[first tabs]`date;
check[before~after; "an ordinary rebuild reuses history rather than reopening it"];

/ and a second rollover must not lose the date it just closed either
.vtidb.rollover[d2+1];
check[d1 in exec date from .vtidb.parts[first tabs]; "a second rollover keeps everything attached"];

-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
system"rm -rf ",scratch;
exit $[fail>0;1;0]
