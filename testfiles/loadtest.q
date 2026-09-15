/ VT-12 load test, measured end to end from one process.
/ .
/ Publishes a burst of trades to the tickerplant, then polls the IDB until every row is
/ visible. That measures the whole chain - feed, tickerplant, writer, disk, reader - rather
/ than just how fast we can fill the tickerplant's queue.
/ .
/ Configured by environment: LOADROWS, LOADPAIRS, LOADBATCH.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

getn:{[k;d] $[count v:getenv k; "J"$v; d] };
rows:getn[`LOADROWS;200000];
pairs:getn[`LOADPAIRS;50];
batch:getn[`LOADBATCH;1000];

/ ports come from KDBBASEPORT, as selftest.q does. hardcoding them means a run against a
/ throwaway stack on another base silently drives the DEFAULT stack instead, and writes its
/ synthetic instruments into that database.
tpport:`$"::",getenv[`KDBBASEPORT],":feed:pass";
idbport:`$"::",string[30+"J"$getenv`KDBBASEPORT],":idb:pass";
tp:@[hopen;tpport;{[e] -1 "no tickerplant on ",string[tpport],": ",e; exit 1}];
idb:@[hopen;idbport;{[e] -1 "no idb on ",string[idbport],": ",e; exit 1}];

insts:`$"P",/:string til pairs;
conds:" 89ABCEGJKLNOPRTWZ";
exch:"NOL";
mkbatch:{[n]
  (n?insts; "f"$1+n?1000; "i"$1+n?1000; n?0b; n?conds; n?exch; n?`buy`sell)
  };

/ NOTE on a completely empty database the reader defines no tables at all, so this query
/ is a value error rather than 0. Trap it - and see the finding in §12.3.
cnt:{[idb] @[idb;"count select from trade";{[e] 0}] };
count0:cnt idb;
nb:rows div batch;

-1 "  publishing ",(string nb*batch)," rows in batches of ",string batch;
t0:.z.p;
{[tp;b;i] neg[tp](".u.upd";`trade;mkbatch b); if[0=i mod 50; tp"1+1"]; }[tp;batch] each til nb;
tp"1+1";                                          / everything is now in the tickerplant
tsent:.z.p;

/ poll until the reader can see every row. rebuild first each time, so new instrument
/ directories are picked up without waiting for the sweep.
target:count0+nb*batch;
deadline:.z.p+0D00:05;
seen:{[idb;target;deadline]
  while[(.z.p<deadline) and target>c:cnt idb;
    idb".vtidb.rebuild[]";
    ];
  c
  }[idb;target;deadline];
t1:.z.p;

secs:{`float$(x)%1000000000};
-1 "";
-1 "  offered to tickerplant : ",(string `long$(nb*batch)%secs tsent-t0)," rows/sec  (",(string tsent-t0),")";
-1 "  end to end to reader   : ",(string `long$(nb*batch)%secs t1-t0)," rows/sec  (",(string t1-t0),")";
-1 "  rows visible / target  : ",(string seen)," / ",string target;
-1 "  all rows captured      : ",string seen>=target;
-1 "";

np:idb"count .vtidb.parts[`trade]";
-1 "  partition dirs         : ",string np;
-1 "  rows per partition     : ",string `long$seen%np;

pc:string idb".vtidb.partitioncol";
one:first idb"1#exec ",pc," from .vtidb.parts`trade";
q1:"select from trade where ",pc,"=`",string one;
idb q1;
u:{[idb;q] t:.z.p; r:idb q; (`long$(.z.p-t)%1000; count r) }[idb];
r:u q1;
-1 "  selective query        : ",(string r 0)," us for ",(string r 1)," rows";
r:u"select n:count i by ",pc," from trade";
-1 "  group by instrument    : ",(string `long$(r 0)%1000)," ms";
r:u"select total:sum price from trade";
-1 "  full aggregate         : ",(string `long$(r 0)%1000)," ms";
r:u".vtidb.rebuild[]";
-1 "  reader rebuild         : ",(string `long$(r 0)%1000)," ms";
hclose tp; hclose idb;
exit 0
