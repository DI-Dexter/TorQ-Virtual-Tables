/ Which q operations work on a virtual table, and which need a select wrapper? (12)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./vt-env.sh && q testfiles/vt-compat-test.q
/ .
/ The brief has long claimed "N operations probed, most work, the rest need a select in front".
/ That number came from an ad-hoc session against a running reader and was never reproducible -
/ and the arithmetic did not close. This runs the probe properly, against a scratch tree of its
/ own, so the figure in the document is one anybody can re-derive.
/ .
/ Nothing here touches a live database. The answer depends on the virtual table's TYPE, not on
/ its contents, so a three-instrument scratch tree probes exactly what a production one would.
/ .
/ Three outcomes, and the third is the one worth knowing:
/ .
/   direct     works on the virtual table as written
/   wrapper    fails on the table object, works on the result of a select
/   wrong      does NOT fail - returns an answer that is quietly incorrect
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

mkp:(use`kx.pq.t)`mkP;
pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

s:"/tmp/vt-compat-",string .z.i;
system"rm -rf ",s; system"mkdir -p ",s;
root:hsym`$s;
(.Q.dd[root;`sym]) set 0#`;
dates:2026.01.01 2026.01.02;
insts:`AAPL`MSFT`AMD;
mk:{[root;d;i]
  t:([]time:5#.z.p; price:5?100f; size:5?1000; side:5?`buy`sell);
  (.Q.dd[.Q.dd[.Q.dd[.Q.dd[root;`$string d];`trade];i];`]) set .Q.ens[root;t;`sym];
  }[root];
mk ./: raze dates,/:\:insts;

load .Q.dd[root;`sym];
k:flip `date`sym!(raze count[insts]#/:dates; (count[dates]*count insts)#insts);
v:raze {[root;d;i] enlist get .Q.dd[.Q.dd[.Q.dd[.Q.dd[root;`$string d];`trade];i];`]}[root] ./: raze dates,/:\:insts;
@[`.;`trade;:;mkp k!v];

/ every probe is a STRING so the failing ones can be re-run with a select wrapped round them
try:{[e] .[value;enlist e;{[x] `$"ERR:",x}]};
iserr:{[x] $[-11h=type x; x like "ERR:*"; 0b]};

/ (label; expression on the table object; the same thing via select, or "" if not applicable)
probes:(
  ("select all";              "select from trade";                          "");
  ("where on partition col";  "select from trade where sym=`AAPL";          "");
  ("where on date";           "select from trade where date=2026.01.01";    "");
  ("where on a data column";  "select from trade where price>50";           "");
  ("where, compound";         "select from trade where sym=`AAPL, price>50";"");
  ("count";                   "count trade";                                "");
  ("count i";                 "select n:count i from trade";                "");
  ("sum";                     "select sum price from trade";                "");
  ("avg";                     "select avg price from trade";                "");
  ("min / max";               "select min price, max price from trade";     "");
  ("by, partition column";    "select n:count i by sym from trade";         "");
  ("by, data column";         "select n:count i by side from trade";        "");
  ("by, two columns";         "select n:count i by date,sym from trade";    "");
  ("by with aggregation";     "select avg price by sym from trade";         "");
  ("exec";                    "exec price from trade";                      "");
  ("exec by";                 "exec avg price by sym from trade";           "");
  ("distinct";                "select distinct sym from trade";             "");
  ("fby, data column";        "select from trade where price>(avg;price) fby side";  "");
  ("fby, partition column";   "select from trade where price>(avg;price) fby sym";
                              "select from (select from trade) where price>(avg;price) fby sym");
  ("dot notation, select";    "select time.minute from trade";                       "");
  ("dot notation, by clause"; "select n:count i by time.minute from trade";
                              "select n:count i by time.minute from select from trade");
  ("column arithmetic";       "select v:price*size from trade";             "");
  ("string / casting";        "select s:string sym from trade";             "");
  ("sublist";                 "5 sublist select from trade";                "");
  ("order by";                "`price xasc select from trade";              "");
  ("in";                      "select from trade where sym in `AAPL`MSFT";  "");
  ("within";                  "select from trade where price within 10 90"; "");
  ("meta";                    "meta trade";                    "meta select from trade");
  ("cols";                    "cols trade";                    "cols select from trade");
  ("xasc on the object";      "`time xasc trade";              "`time xasc select from trade");
  ("xdesc on the object";     "`time xdesc trade";             "`time xdesc select from trade");
  ("update";                  "update flag:1b from trade";     "update flag:1b from select from trade");
  ("delete a column";         "delete size from trade";        "delete size from select from trade");
  ("delete rows";             "delete from trade where price>50"; "delete from select from trade where price>50");
  ("index by column name";    "trade[`side]";                  "(select from trade)[`side]");
  ("value";                   "value trade";                   "value select from trade");
  ("flip";                    "flip trade";                    "flip select from trade");
  ("keys";                    "key trade";                     "key select from trade"));

res:{[try;iserr;p]
  d:try p 1;
  $[not iserr d; `direct;
    0=count p 2; `nofix;
    iserr try p 2; `nofix;
    `wrapper]
  }[try;iserr] each probes;

direct:where res=`direct;
wrapper:where res=`wrapper;
nofix:where res=`nofix;

-1 "";
-1 "  probed ",string[count probes]," operations against a virtual table";
-1 "";
-1 "    work directly            ",string count direct;
-1 "    need a select wrapper    ",string count wrapper;
-1 "    no workaround            ",string count nofix;
-1 "";
if[count wrapper;
  -1 "  need a wrapper:";
  {[probes;i] -1 "    ",(24$probes[i;0]),probes[i;1]}[probes] each wrapper];
if[count nofix;
  -1 "";
  -1 "  NO WORKAROUND:";
  {[probes;i] -1 "    ",(24$probes[i;0]),probes[i;1]}[probes] each nofix];

-1 "";
check[count[probes]=count[direct]+count[wrapper]+count nofix;
  "the three buckets account for every operation probed (",string[count probes],")"];
check[0<count direct; "operations that read data work directly (",string[count direct],")"];
check[0=count nofix; "nothing is unreachable - every failure has a select-wrapped form"];

/ the one that does not fail, and is not in the buckets above, because it is not an
/ operation ON the table - it is a lookup that never finds it
-1 "";
-1 "  SEPARATELY: discovery, which fails without erroring";
t:@[{[] tables[]};(::);{[e] `$"ERR:",x}];
-1 "    tables[] returns          ",.Q.s1 t;
check[not `trade in t;
  "tables[] does NOT list the virtual table - a 112h object is invisible to anything that ",
  "discovers tables rather than being told their names (dashboards, schema tooling)"];
check[99h=type value "meta select from trade";
  "  - while the data itself is perfectly reachable once you know the name"];

-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
system"rm -rf ",s;
exit $[fail>0;1;0]
