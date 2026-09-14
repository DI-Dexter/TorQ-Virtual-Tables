/ What does a query see when it arrives at the worst possible moment? (5.2, 5.3)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-inflight-test.q
/ .
/ Every other test in this directory starts from a world that is standing still: the data is
/ already written, the catalogue is already built, and only then does anything get asked. That
/ is not how this database is read. The whole point of the design is that the writer appends to
/ the same directories a client is querying, with no copy and no handover, so the interesting
/ question is what a query returns when it lands in the middle of something.
/ .
/ Three moments, and they fail - or do not - for different reasons:
/ .
/   mid-append    the writer is extending the column files of a partition this query is
/                 reading. columns are extended ONE AT A TIME, so between them the partition
/                 genuinely has columns of different lengths on disk
/ .
/   mid-rebuild   the reader is replacing the virtual table while a client asks for it
/ .
/   ill-formed    the catalogue built, but the partitions it points at cannot be read together
/ .
/ The first is the one that ought to worry you, because nothing in the design prevents it and
/ there is no lock anywhere. The answer turns out to be the same rule that makes on-disk
/ truncation silent in vt-damage-test.q - a splayed table is cut to its SHORTEST column - only
/ here that rule is what saves it: a short read is a consistent PREFIX, never a torn row.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };
try:{[f;a] .[f;a;{[e] `$"ERR:",e}]};
iserr:{[x] -11h=type x};

s:"/tmp/vt-inflight-",string .z.i;
system"rm -rf ",s; system"mkdir -p ",s;

/ ---------------------------------------------------------------------------
/ 1. the rule, established without a race.
/ a directory whose columns are different lengths is exactly what the writer leaves behind
/ between one column's append and the next. build one deliberately and read it.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  RAGGED PARTITION - columns of different lengths, no race involved";

r1:hsym`$s,"/static";
.Q.dd[r1;`] set ([]a:til 1000; b:2*til 1000; c:1000#`long$7);
system"truncate -s ",string[8*400]," ",(1_string .Q.dd[r1;`b]);   / b now holds 400 of 1000

v1:get .Q.dd[r1;`];
lens:value count each flip v1;
n1:try[{[x] count select from x};enlist v1];
cons:try[{[x] count select from x where b<>2*a};enlist v1];

-1 "    column lengths on disk  ",.Q.s1 lens;
-1 "    rows served             ",.Q.s1 n1;
check[1<count distinct lens; "the partition really is ragged on disk"];
check[not iserr n1; "a ragged partition still reads - no error, which is why this is quiet"];
check[n1=min lens; "it is cut to its SHORTEST column (",string[n1]," rows, not ",string[max lens],")"];
check[(not iserr cons) and 0=cons;
  "and the rows it does return are internally consistent - a PREFIX, not a torn row"];

/ ---------------------------------------------------------------------------
/ 2. the same thing under a real race.
/ one process appends, another holds a live view - the object .vtidb.opened holds - and reads
/ it as fast as it can. the raggedness above is now transient, appearing and closing again
/ within microseconds, so this measures how often a reader actually lands in it and, far more
/ importantly, whether landing in it can ever produce a WRONG row rather than a short read.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  MID-APPEND - one process appending, another reading the live view";

r2:hsym`$s,"/race";
.Q.dd[r2;`] set ([]a:`long$(); b:`long$(); c:`long$());

wq:s,"/appender.q";
(hsym`$wq) 0: (
  "p:.Q.dd[hsym`$getenv`DIR;`];";
  "{[p;i] p upsert ([]a:100#i; b:100#2*i; c:100#`long$i)}[p] each til \"J\"$getenv`ROUNDS;";
  "exit 0");
system"DIR=",(1_string r2)," ROUNDS=8000 q ",wq," </dev/null >/dev/null 2>&1 &";
system"sleep 0.1";

v2:get .Q.dd[r2;`];
one:{[try;v;i]
  cnts:try[{[x] value count each flip x};enlist v];
  t:try[{[x] select from x};enlist v];
  (cnts; try[{[x] count x};enlist t]; try[{[x] count select from x where b<>2*a};enlist t])
  }[try;v2];
res:one each til 5000;

cs:res[;0];
ragged:sum {$[7h=type x; 1<count distinct x; 0b]} each cs;
errd:sum iserr each res[;2];
torn:sum {$[-7h=type x; 0<x; 0b]} each res[;2];
ns:res[;1] where -7h=type each res[;1];

-1 "    reads                   5000";
-1 "    landed mid-append       ",string ragged;
-1 "    rows seen               ",(string min ns)," .. ",string max ns;
check[0<ragged; "reads really did land between two column appends (",string[ragged]," of 5000)"];
check[0=errd; "not one of them errored"];
check[0=torn; "not one of them returned a row where b<>2*a - no torn rows, ever"];
check[ns~asc ns; "and the row count a reader sees only ever goes up"];
-1 "    -> no lock is needed on the read path. a query that lands mid-append is short,";
-1 "       never wrong, and the next query sees the rest.";

/ ---------------------------------------------------------------------------
/ 3. mid-rebuild.
/ rebuild REPLACES the global a client is querying. a client that caught it half-done would
/ see a table whose catalogue and contents disagree. this runs a real reader process with
/ rebuild on a 3ms timer while new directories keep appearing underneath it, and has a client
/ ask - in ONE message, so the answer is a single instant - for three numbers that must agree.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  MID-REBUILD - a client querying while the reader replaces the table";

root:hsym`$s,"/live";
system"mkdir -p ",(1_string root);
(.Q.dd[root;`sym]) set 0#`;
d:2026.01.01;
mkinst:{[root;d;i]
  t:([]time:10#.z.p; price:10?100f; side:10?`buy`sell);
  .Q.dd[.Q.dd[.Q.dd[.Q.dd[root;`$string d];`trade];`$"I",string i];`] set .Q.ens[root;t;`sym];
  }[root;d];
mkinst each til 20;

port:1+rand 2000;
port+:20000;
rq:s,"/reader.q";
(hsym`$rq) 0: (
  ".lg.o:{[t;m]}; .lg.w:{[t;m]}; .lg.e:{[t;m]};";
  ".servers.startupdepcycles:{[t;i;c] '\"nowdb\"};";
  ".servers.gethandlebytype:{[t;m] ()};";
  ".timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};";
  ".vtidb.roots:enlist hsym`$getenv`ROOT;";
  ".vtidb.partitioncol:`instrument;";
  "system \"l \",getenv[`KDBAPPCODE],\"/processes/vtidb.q\";";
  ".vtidb.current:2026.01.01;";
  "rebuilds:0;";
  "started:.z.p;";
  "/ three numbers that MUST agree, answered in one message so they share one instant";
  "probe:{[] (count select from trade; count .vtidb.parts`trade;";
  "  count distinct exec instrument from select instrument from trade)};";
  "aligned:{[] all {count[.vtidb.parts x]=count .vtidb.opened x} each key .vtidb.parts};";
  "/ the timer both rebuilds and enforces a deadline, so a stuck client cannot orphan this";
  ".z.ts:{[] .vtidb.rebuild[]; rebuilds::rebuilds+1; if[0D00:01<.z.p-started; exit 0]};";
  "system \"p \",getenv`PORT;";
  "system \"t \",getenv`TICK;");
system"ROOT=",(1_string root)," PORT=",string[port]," TICK=3 q ",rq," </dev/null >",s,"/reader.log 2>&1 &";
system"sleep 1.5";

h:@[hopen;`$":localhost:",string port;0Ni];
if[null h; -1 "  could not reach the reader - see ",s,"/reader.log"; exit 1];

/ a churner adding directories underneath the reader, so rebuild has real work to do
cq:s,"/churn.q";
(hsym`$cq) 0: (
  "root:hsym`$getenv`ROOT;";
  "{[root;i]";
  "  t:([]time:10#.z.p; price:10?100f; side:10?`buy`sell);";
  "  .Q.dd[.Q.dd[.Q.dd[.Q.dd[root;`2026.01.01];`trade];`$\"I\",string i];`] set .Q.ens[root;t;`sym];";
  "  system\"sleep 0.05\";";
  "  }[root] each 20+til 40;";
  "exit 0");
system"ROOT=",(1_string root)," q ",cq," </dev/null >/dev/null 2>&1 &";

lat:();
obs:();
{[h;i]
  t0:.z.p;
  r:.[h;enlist"probe[]";{[e] `$"ERR:",e}];
  lat,::`long$(.z.p-t0)%1000;
  obs,::enlist r;
  } [h] each til 1500;

bad:sum iserr each obs;
good:obs where not iserr each obs;
disagree:sum {not x[1]=x[2]} each good;
rows:{x 0} each good;
partc:{x 1} each good;

-1 "    queries                 ",string count obs;
-1 "    rebuilds meanwhile      ",string h"rebuilds";
-1 "    partitions             ",(string min partc)," -> ",string max partc;
-1 "    latency us  median     ",string med lat;
-1 "                max        ",string max lat;
check[0=bad; "no query errored while the table was being replaced underneath it"];
check[0=disagree;
  "no query ever saw the catalogue and the served table disagree (",string[count good]," answers)"];
check[rows~asc rows; "row counts seen by the client only go up - no query read a half-built table"];
check[max[partc]>min partc; "and the table really was growing while they ran (",
  string[min partc]," -> ",string[max partc]," partitions)"];
check[h"aligned[]"; "parts and opened are still row-aligned after ",(string h"rebuilds")," rebuilds"];
/ assert on the MEDIAN, not the max. the tail here is the operating system - the worst single
/ query has been seen anywhere from 22ms to 1.2s on the same code, purely with machine load -
/ so asserting on it tests the box rather than the design
check[(med lat)<50000;
  "median query latency stays inside a rebuild's cost (",string[`long$med lat]," us)"];
-1 "    the worst single query in this run was ",string[max lat]," us. that figure is the OS,";
-1 "    not the design, and it moves by an order of magnitude with load.";
-1 "    -> q's main loop is the lock. rebuild is one message, a query is another, and they";
-1 "       cannot interleave. the cost of a rebuild is paid as QUEUING, which is why rebuild";
-1 "       being O(new directories) rather than O(history) matters to readers, not just to";
-1 "       the writer (8.2).";
@[h;"exit 0";::];
@[hclose;h;::];

/ ---------------------------------------------------------------------------
/ 4. the catalogue built, and the query still cannot be answered.
/ mkP does not validate what it is handed. both of these build cleanly and fail - or silently
/ mislead - only when someone asks. worth pinning down, because it says where to look when a
/ virtual table that "built fine" will not answer.
/ ---------------------------------------------------------------------------
-1 "";
-1 "  ILL-FORMED CATALOGUE - built without complaint, wrong at query time";

mkp:(use`kx.pq.t)`mkP;
b:hsym`$s,"/bits"; system"mkdir -p ",1_string b;
.Q.dd[.Q.dd[b;`x];`] set ([]a:til 3);
.Q.dd[.Q.dd[b;`y];`] set ([]a:3+til 3);
vx:get .Q.dd[.Q.dd[b;`x];`]; vy:get .Q.dd[.Q.dd[b;`y];`];

/ the same (date;instrument) twice - what two roots capturing one instrument would produce
dup:flip `date`instrument!(2#d; `AAPL`AAPL);
rd:try[{[mkp;k;v] mkp[k!v]}[mkp];(dup;(vx;vy))];
check[not iserr rd; "duplicate (date;instrument) keys do not fail the build"];
if[not iserr rd;
  @[`.;`dupt;:;rd];
  check[6=count select from dupt;
    "KNOWN LIMIT: both directories are served under one key - 6 rows, not 3. two stacks ",
    "capturing the same instrument DOUBLE COUNT, silently. see 8.3"]];

/ partitions whose columns differ - the 9.3 state, reached by adding a column to one leaf
.Q.dd[.Q.dd[b;`y];`] set ([]a:3+til 3; extra:3#1);
vy2:get .Q.dd[.Q.dd[b;`y];`];
mix:flip `date`instrument!(2#d; `AAPL`MSFT);
rm:try[{[mkp;k;v] mkp[k!v]}[mkp];(mix;(vx;vy2))];
check[not iserr rm; "mismatched columns across partitions do not fail the build either"];
if[not iserr rm;
  @[`.;`mixt;:;rm];
  check[iserr try[{[] count select from mixt};()];
    "they fail at QUERY time - which is why 9.3 shows up as a broken reader, not a broken write"];
  check[iserr try[{[] count select a from mixt};()];
    "  - and even selecting a column BOTH partitions have still errors"]];

-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
system"rm -rf ",s;
exit $[fail>0;1;0]
