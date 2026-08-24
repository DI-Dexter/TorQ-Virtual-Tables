/ End-to-end self test for the virtual-table capture pack.
/ .
/ Publishes a brand new symbol to the tickerplant and checks that it travels all the
/ way through to the IDB: writer creates a partition directory, notifies, reader rebuilds,
/ the rows come back through the virtual table, and the partition column is NOT in the files.
/ .
/ Run it with ./selftest.sh while the stack is up.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

tpport:`$"::",getenv[`KDBBASEPORT],":feed:pass";
idbport:`$"::",string[30+"J"$getenv`KDBBASEPORT],":idb:pass";

pass:0; fail:0;
/ WARNING the first parameter is NOT called "desc" - that is a q keyword, and using it as a
/ parameter name makes the function raise 'nyi when applied
check:{[msg;ok;detail]
  if[ok; pass::pass+1; -1 "  PASS  ",msg; :()];
  fail::fail+1;
  -1 "  FAIL  ",msg," -- ",detail;
  };

-1 "connecting to the tickerplant and the idb...";
tp:@[hopen;tpport;{'"no tickerplant on ",string[tpport],": ",x}];
h:@[hopen;idbport;{'"no idb on ",string[idbport],": ",x}];

/ a fresh instrument each run, so this really does create a NEW partition directory.
/ WARNING seed from the clock first - every q process starts with the same rng seed, so
/ without this the "random" instrument is identical on every run
system "S ",string "i"$.z.t;      / .z.t is ms since midnight - .z.n overflows an int
inst:`$"ZZ",5?.Q.A;
-1 "test symbol: ",string inst;

/ wait until the reader actually has the trade table. on a brand new database it has no
/ tables at all until the writer's first flush, so "count select from trade" is a value
/ error rather than 0 - see §12.3. without this wait the test fails spuriously when run
/ immediately after a wipe.
/ the reader exposes the partition column under a configurable name (§5.3), so ask it rather
/ than hardcoding one - this test has to work whatever the schema calls it
pc:string h".vtidb.partitioncol";
hastrade:{[h] @[{[x] x"count select from trade"; 1b};h;{[e] 0b}] };
/ WARNING do not name the limit "maxs" - it is a q keyword (running maximum) and using it
/ as a parameter gives 'match when the function is applied
waitready:{[h;limit]
  n:0;
  while[(n<limit) and not hastrade h; system"sleep 1"; n+:1];
  hastrade h
  };
if[not waitready[h;20];
  -1 "  FAIL  reader has no trade table after 20s - is the writer running?"; exit 1];

before:h"count select from trade";
partsbefore:h"count .vtidb.parts[`trade]";
n:3;

-1 "publishing ",string[n]," rows...";
do[n;
  tp(".u.upd";`trade;(enlist inst;enlist 100f;enlist 10i;enlist 0b;
                      enlist " ";enlist "N";enlist`buy))];

/ the writer flushes every second and the reader rebuilds on notification; 3s is ample
system"sleep 3";

-1 "";
-1 "results:";

after:h"count select from trade";
check["rows reached the idb";after>=before+n;"before ",string[before]," after ",string after];

/ NOTE assert that OUR instrument is now in the catalogue, not that the count rose by exactly
/ one: the demo feed introduces symbols of its own, so an exact-count assertion fails
/ spuriously on a freshly started stack.
partsafter:h"count .vtidb.parts[`trade]";
haspart:h"(`",(string inst),") in exec ",pc," from .vtidb.parts`trade";
check["a new partition directory was picked up";haspart and partsafter>partsbefore;
  "instrument present: ",(string haspart),", partitions ",string[partsbefore],"->",string partsafter];

got:h"select from trade where ",pc,"=`",string inst;
check["the new symbol is queryable";n=count got;"got ",string[count got]," rows"];
check["the partition column comes back as a column";inst~first got[`$pc];.Q.s1 got];

/ the whole point of the design: the partition column must NOT be stored in the files
p:h"first exec path from .vtidb.parts[`trade] where ",pc,"=`",string inst;
ondisk:@[{cols get x};p;{`FAILED_TO_READ}];
check["the partition column is NOT in the files";not `sym in ondisk;.Q.s1 ondisk];
check["the data columns are";7=count ondisk;.Q.s1 ondisk];

/ appends to an EXISTING partition directory must become visible.
/ NOTE assert on this instrument's own rows, not on the global count or the global partition
/ count: the demo feed publishes concurrently and introduces new instruments of its own, so a
/ global assertion fails spuriously on a freshly started stack. The stronger claim - that no
/ rebuild is needed at all - is measured under controlled conditions in §5.2, not here.
mine:{[h;inst] h"count select from trade where ",pc,"=`",string inst};
a:mine[h;inst];
do[n; tp(".u.upd";`trade;(enlist inst;enlist 101f;enlist 20i;enlist 0b;
                          enlist " ";enlist "N";enlist`sell))];
system"sleep 3";
b:mine[h;inst];
check["appends to an existing partition are visible";b>=a+n;
  "rows for ",(string inst),": ",string[a],"->",string b];

hclose tp; hclose h;

-1 "";
-1 (40#"-");
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 (40#"-");
exit $[fail>0;1;0];
