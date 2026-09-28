/ Market-data feed, following the Finance Starter Pack generator.
/ .
/ Publishes trades and quotes for a small equity universe, with skewed volumes so partition
/ sizes vary the way they do in real data.
/ .
/ Configured by environment:
/   REPLAYINTERVAL   time between publishes (default 200ms)
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

REPLAYINTERVAL:@[value;`REPLAYINTERVAL;0D00:00:00.200];

/ the instrument universe. Stack i of n takes every instrument whose index is congruent to
/ i-1 mod n, so the slices are disjoint by arithmetic rather than by two lists being kept
/ apart. §8.3
/ .
/ stackid, nstacks and universe are declared in appconfig/settings/feed.q - which sits inside
/ \d .feed - so the process file can set them.
universe:@[value;`.feed.universe;`AMD`AIG`AAPL`DELL`DOW`GOOG`HPQ`INTC`IBM`MSFT,
                                 `BARC`HSBA`LLOY`NWG`STAN`VOD`BP`SHEL`GSK`AZN];
vtslice:{[u;id;n]
  if[n<=1; :u];
  if[not count r:u where (id-1)=(til count u) mod n;
    .lg.e[`feed;"stack ",string[id]," of ",string[n]," has no instruments - the universe ",
                "holds only ",string[count u]]];
  r
  };
syms:@[value;`syms;vtslice[universe;@[value;`.feed.stackid;1];@[value;`.feed.nstacks;1]]];
/ starting price per instrument. The stock ten are hand-picked; a configured universe of a
/ different length gets spread-out deterministic prices instead, so only the symbols need setting.
px:@[value;`px;33 27 84 12 20 72 36 51 42 29f];
if[not count[px]=count syms; px:10+`float$(7*til count syms) mod 90];
modes:" ABHILNORYZ";                      / quote mode
conds:" 89ABCEGJKLNOPRTWZ";               / trade condition
exch:"NONNONONNN";                        / exchange, one per symbol
srcs:`BARX`GETGO`SUN`DB;
sides:`buy`sell;

cnt:count syms;
maxtrades:15;                             / max trades per tick
quotespertrade:5;

/ WARNING every q process starts on the same rng seed, so without this the "random" feed is
/ byte-identical on every run - which quietly makes a load test measure the same data twice
system "S ",string "i"$.z.t;              / .z.t is ms since midnight; .z.n overflows an int

/ weights skew how often each symbol appears and how large its sizes are, so partitions do
/ not all come out the same size
weight:0.1*1+neg[cnt]?2*cnt;
volmap:syms!neg[cnt]?weight;
bidmap:syms!neg[cnt]?weight;
askmap:syms!neg[cnt]?weight;

/ a weighted index list: symbols with a higher weight appear in it more often
skew:{[weights;items] raze weights#'neg[count items]?items};
weighted:skew[`long$weight*10;til cnt];

pi:acos -1;
normalrand:{[n] (cos 2*pi*n?1f)*sqrt neg 2*log n?1f};
rnd:{[x] 0.01*floor 0.5+x*100};
vol:{[n] 10+`int$n?90};

/ a batch of correlated prices: each symbol random-walks from where it left off
qx:qb:qa:qp:();
qn:0;
batch:{[n]
  d:exp 0.001*normalrand n;
  qx::n?weighted;
  qb::rnd n?1.0;
  qa::rnd n?1.0;
  idx:where each qx=/:til cnt;
  s:px*prds each d idx;
  qp::n#0.0;
  (qp raze idx):rnd raze s;
  px::last each s;
  qn::0;
  };

len:10000;
batch len;

/ column vectors in the order .u.upd expects. time is added by the tickerplant
mktrade:{[n]
  if[not (qn+n)<count qx; batch len];
  i:qx m:qn+til n; qn+:n;
  (syms i; qp m; `int$volmap[syms i]*n?99; 1=n?20; n?conds; exch i; n?sides)
  };

mkquote:{[n]
  if[not (qn+n)<count qx; batch len];
  i:qx m:qn+til n; p:qp m; qn+:n;
  (syms i; p-qb m; p+qa m; `long$bidmap[syms i]*vol n; `long$askmap[syms i]*vol n;
   n?modes; exch i; n?srcs)
  };

/ 8.3.2 - which tickerplant to publish to. ` takes whichever one is found first, which is right
/ with one stack and a coin toss with two. Declared in appconfig/settings/feed.q so the process
/ file's extras column can override it (-.feed.tickerplantname stp2).
tpname:@[value;`.feed.tickerplantname;`];

/ Resolve the handle on every publish rather than caching one at startup: a cached handle dies
/ with the tickerplant, and .servers reconnecting updates its own table, not a copy of it.
/ Both branches return an empty int list rather than a null handle, because send tests count
/ and `first` on an empty column would give 0Ni, which counts 1.
tphandle:{[]
  if[null tpname; :.servers.gethandlebytype[`segmentedtickerplant;`any]];
  r:.servers.getservers[`procname;tpname;()!();1b;1b];
  $[count r; first exec w from r; 0#0Ni]
  };

send:{[]
  tp:tphandle[];
  if[not count tp; :()];                 / tickerplant down - the next tick tries again
  $[rand 2;
    tp(".u.upd";`trade;mktrade 1+rand maxtrades);
    tp(".u.upd";`quote;mkquote 1+rand quotespertrade*maxtrades)];
  };

/ wait for the tickerplant to be available before starting the timer
.servers.startupdepcycles[`segmentedtickerplant;10;0W];

-1 "Feed: ",string[cnt]," symbols, publishing every ",
   string[`long$REPLAYINTERVAL%0D00:00:00.001]," ms";

.timer.repeat[.proc.cp[];0Wp;REPLAYINTERVAL;(`send;`);"Publish feed"];
