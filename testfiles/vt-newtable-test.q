/ Does a table that appears mid-life get picked up? (§5.3)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-newtable-test.q
/ .
/ The reader does not read the schema. It discovers its table list from the tree, by taking
/ `key` of a date directory - which is deliberate, so that adding a table to database.q needs
/ no change here. This checks that it works, and that the consequences are understood.
/ .
/ It looks at the LIVE partition, not at every date. Scanning all of history on every rebuild
/ cost 2.6 ms of a 4.2 ms rebuild at 250 dates and grew with retention for ever, to notice
/ something that happens once in a deployment's life. A new table appears where the writer is
/ writing, so that is where it is looked for. The cost is a real limitation and the last
/ section pins it down: a table added to a date that has already rolled needs a dropcache,
/ which is the same rule 6.1 already states for a directory added to a past date.
/ .
/ The interesting part is not discovery but COVERAGE. A table added part-way through a
/ database's life legitimately has fewer dates than the others, and §4.6's gap check compares
/ date coverage across tables to catch a partition written without one of its tables. A
/ genuinely new table therefore looks exactly like that failure, and is reported as one -
/ every rebuild, for as long as the older dates are attached.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

/ enough of the TorQ framework for vtidb.q to load standalone
.lg.o:{[t;m]}; .lg.w:{[t;m] warns,:enlist m}; .lg.e:{[t;m] errs,:enlist m};
.servers.startupdepcycles:{[t;i;c] '"no wdb in this test"};
.servers.gethandlebytype:{[t;m] ()};
.timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};
warns:(); errs:();

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

live:getenv`KDBDB;
s:"/tmp/vt-newtable-",string .z.i;
d0:2026.01.01; d1:2026.01.02;

src:first asc key[hsym`$live] where key[hsym`$live] like "[0-9][0-9][0-9][0-9].*";
if[null src; -1 "  no partitions under ",live," - start the stack first"; exit 77];

system"rm -rf ",s; system"mkdir -p ",s;
system"cp ",live,"/sym ",s,"/";
{[live;src;s;d] system"cp -r ",live,"/",(string src)," ",s,"/",string d}[live;src;s] each d0,d1;

.vtidb.roots:enlist hsym`$s;
.vtidb.partitioncol:`sym;
system"l ",getenv[`KDBAPPCODE],"/processes/vtidb.q";
.vtidb.current:d1;                        / d1 is the partition the writer is filling
.vtidb.dropcache[]; .vtidb.rebuild[];

before:asc key .vtidb.parts;
-1 "";
-1 "  scratch        ",s;
-1 "  tables at start ",.Q.s1 before;
-1 "  dates          ",.Q.s1 asc distinct raze .vtidb.coverage[];
-1 "";

/ ---------------------------------------------------------------------------
/ a new table appears, on the LATER date only - which is what "added mid-life" looks like
r:hsym`$s;
load .Q.dd[r;`sym];
newtab:`signal;
insts:`AAPL`AMD`MSFT;
{[r;d1;newtab;i]
  t:([]time:3#.z.p; strength:3?1f; flag:3#`live);
  .Q.dd[.Q.dd[.Q.dd[.Q.dd[r;`$string d1];newtab];i];`] set .Q.en[r;t]
  }[r;d1;newtab] each insts;
-1 "  created        ",(string d1),"/",(string newtab),"/ for ",.Q.s1 insts;

warns:();
.vtidb.rebuild[];
after:asc key .vtidb.parts;

-1 "";
-1 "  tables now     ",.Q.s1 after;
-1 "";

check[newtab in after; "the new table is discovered from the tree, with no config change"];
check[3=count .vtidb.parts newtab; "all three of its partitions are attached"];
check[112h=type value newtab; "it is a virtual table like the others"];

n:.[{[t] count value "select from ",string t};enlist newtab;{`$"ERROR: ",x}];
/ NOTE 3*3=n would parse as 3*(3=n). spell the expected number out.
check[9=n; "and it is queryable - ",(.Q.s1 n)," rows across 3 instruments"];
check[(enlist d1)~asc distinct exec date from .vtidb.parts newtab;
  "it covers only the date it appeared on, as it should"];

/ ---------------------------------------------------------------------------
-1 "";
check[any warns like "*coverage gap*";
  "EXPECTED FALSE ALARM: 4.6's coverage check reports it as a gap"];
{-1 "         ",x} each warns where warns like "*coverage gap*";
-1 "";
-1 "  That warning is correct by its own rules and wrong in intent. The check exists to catch";
-1 "  a partition written without one of its tables, and a table added mid-life is";
-1 "  indistinguishable from that on disk. It will repeat for as long as the older dates are";
-1 "  attached. Worth knowing before adding a table to a live database - the alternative,";
-1 "  suppressing it, would silence the failure it was built for.";
-1 "";
/ ---------------------------------------------------------------------------
/ the limitation that buys the flat rebuild: a table appearing on a date that has already
/ rolled is not looked for, because the reader only scans the live partition
/ ---------------------------------------------------------------------------
-1 "  A TABLE ADDED TO A DATE THAT HAS ALREADY ROLLED";

older:`archive;
{[r;d0;older;i]
  t:([]time:3#.z.p; strength:3?1f; flag:3#`live);
  .Q.dd[.Q.dd[.Q.dd[.Q.dd[r;`$string d0];older];i];`] set .Q.en[r;t]
  }[r;d0;older] each insts;

.vtidb.rebuild[]; .vtidb.rebuild[];
check[not older in key .vtidb.parts;
  "it is NOT discovered by a rebuild - the live partition is the only one scanned"];
.vtidb.dropcache[];
.vtidb.rebuild[];
check[older in key .vtidb.parts;
  "dropcache[] finds it, which is the recovery path 6.1 already prescribes for any change ",
  "made to a date that has rolled"];
-1 "";

-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
system"rm -rf ",s;
exit $[fail>0;1;0]
