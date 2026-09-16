/ VT-11: do identical queries return identical answers from the virtual table and from a
/ conventional date-partitioned kdb+ database holding the same data?

.lg.o:{[t;m]}; .lg.w:{[t;m]}; .lg.e:{[t;m]};
.servers.startupdepcycles:{[t;i;c] '"no wdb"};
.servers.gethandlebytype:{[t;m] ()};
.timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};

.vtidb.roots:enlist hsym`$getenv[`SCRATCH],"/vtdb";
/ this script loads the reader directly, so it does NOT pick up appconfig/settings/idb.q -
/ set the exposed partition column explicitly to match the schema this database uses
.vtidb.partitioncol:`sym;
system"l ",getenv[`KDBAPPCODE],"/processes/vtidb.q";
h:hopen `$"::",$[count getenv`PORT;getenv`PORT;"6099"];

pass:0; fail:0; ordr:0;

/ canonical form, so row ORDER is not mistaken for a wrong answer:
/ unkey, rename the partition column to the schema's name, sort by every column
/ in-process, the virtual table hands back symbol columns as unresolved ENUMERATIONS (20h)
/ where a conventional partitioned select resolves them to symbols (11h). Values are equal
/ and over IPC both send plain symbols, so this is representation, not a wrong answer.
desym:{[t]
  d:flip t;
  e:where 20h=type each d;
  $[count e; flip @[d;e;value]; t]
  };

norm:{[t]
  if[not type[t] in 98 99h; :t];
  if[99h=type t; t:0!t];
  / no rename needed any more: the reader now exposes the partition column under the
  / schema's own name (§5.3), so both sides agree
  / column order differs between the two layouts; that is not a wrong answer
  t:desym t;
  t:(asc cols t) xcols t;
  $[count cols t; (cols t) xasc t; t]
  };

cmp:{[lbl;vq;hq]      / NOT "desc" - q keyword, gives 'nyi on application
  a:@[{norm value x};vq;{(`ERROR;x)}];
  b:@[{norm h x};hq;{(`ERROR;x)}];
  exact:a~b;
  / already normalised, so a mismatch here is a real difference
  $[exact;
    [pass+:1; -1 "  PASS  ",lbl];
    [fail+:1; -1 "  FAIL  ",lbl;
              -1 "          vt : ",-3!$[98h=type a;3#a;a];
              -1 "          hdb: ",-3!$[98h=type b;3#b;b]]];
  };

-1 "comparing the virtual table against a conventional date-partitioned kdb+ database";
-1 "";

cmp["total row count";
    "count select from trade";
    "count select from trade"];

cmp["count by date";
    "select n:count i by date from trade";
    "select n:count i by date from trade"];

cmp["filter on the partition column";
    "select from trade where sym=`AMD";
    "select from trade where sym=`AMD"];

cmp["filter on partition column + date";
    "select from trade where date=2026.01.01, sym=`AMD";
    "select from trade where date=2026.01.01, sym=`AMD"];

cmp["filter on a data column";
    "select from trade where side=`BUY";
    "select from trade where side=`BUY"];

cmp["combined partition and data filter";
    "select from trade where sym=`XAUUSD, side=`SELL";
    "select from trade where sym=`XAUUSD, side=`SELL"];

cmp["in on a list of instruments";
    "select from trade where sym in `AMD`MSFT`XAUUSD";
    "select from trade where sym in `AMD`MSFT`XAUUSD"];

cmp["sum aggregate";
    "select total:sum price from trade";
    "select total:sum price from trade"];

cmp["group by the partition column";
    "select n:count i, total:sum price by sym from trade";
    "select n:count i, total:sum price by sym from trade"];

cmp["group by date and a data column";
    "select n:count i by date, side from trade";
    "select n:count i by date, side from trade"];

cmp["min / max / avg";
    "select mn:min price, mx:max price, av:avg price from trade";
    "select mn:min price, mx:max price, av:avg price from trade"];

cmp["distinct on the partition column";
    "distinct select sym from trade";
    "distinct select sym from trade"];

cmp["select specific columns";
    "select time, side, price from trade where sym=`AAPL";
    "select time, side, price from trade where sym=`AAPL"];

cmp["time-range filter";
    "select from trade where time within (2026.01.01D00:00; 2026.01.01D23:59)";
    "select from trade where time within (2026.01.01D00:00; 2026.01.01D23:59)"];

cmp["dot notation on a temporal column";
    "select n:count i by time.hh from trade";
    "select n:count i by time.hh from trade"];

cmp["empty result - instrument that does not exist";
    "select from trade where sym=`ZZZZZZ";
    "select from trade where sym=`ZZZZZZ"];

cmp["weighted average";
    "select wa:size wavg price by sym from trade";
    "select wa:size wavg price by sym from trade"];

cmp["fby";
    "select from trade where price=(max;price) fby sym";
    "select from trade where price=(max;price) fby sym"];

cmp["count distinct";
    "select nd:count distinct sym from trade";
    "select nd:count distinct sym from trade"];

hclose h;
-1 "";
-1 (40#"-");
-1 "  ",string[pass]," matched, ",string[fail]," differed";
-1 (40#"-");
exit $[fail>0;1;0];
