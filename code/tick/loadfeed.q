/ Load generator for VT-12. Publishes batched trades to the tickerplant as fast as it can,
/ then reports what it managed to send.
/ .
/ The normal feed (code/tick/feed.q) publishes a few rows every 200ms, which exercises
/ correctness but tells you nothing about throughput. This one is for volume.
/ .
/ Configured by environment:
/   LOADROWS   total rows to publish        (default 1000000)
/   LOADBATCH  rows per publish             (default 1000)
/   LOADPAIRS  size of symbol universe      (default 50)
/   LOADSYNC   sync-ping every N batches, to apply backpressure (default 50)
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

\d .load

getn:{[k;d] $[count v:getenv k; "J"$v; d] };

rows:getn[`LOADROWS;1000000];
batch:getn[`LOADBATCH;1000];
pairs:getn[`LOADPAIRS;50];
syncevery:getn[`LOADSYNC;50];

/ a synthetic symbol universe. plain uppercase names, so the writer's directory-name
/ sanitiser has nothing to mangle (see 2.3)
insts:`$"P",/:string til pairs;
conds:" 89ABCEGJKLNOPRTWZ";
exch:"NOL";
sides:`buy`sell;

/ one batch of column vectors, in the order .u.upd expects. time is added by the tickerplant.
mkbatch:{[n]
  (n?insts; "f"$1+n?1000; "i"$1+n?1000; n?0b; n?conds; n?exch; n?sides)
  };

run:{[]
  h:.servers.gethandlebytype[`segmentedtickerplant;`any];
  if[not count h; .lg.e[`load;"no tickerplant"]; :()];
  nb:rows div batch;
  .lg.o[`load;"publishing ",(string rows)," rows in ",(string nb)," batches of ",string batch];
  t0:.z.p;
  / async publish, with a periodic sync ping so the tickerplant can apply backpressure
  / rather than letting our queue grow without limit
  {[h;b;syncevery;i]
    neg[h](".u.upd";`trade;mkbatch b);
    if[0=i mod syncevery; h"1+1"];
    }[h;batch;syncevery] each til nb;
  h"1+1";                                / final sync: everything is in the tickerplant
  el:.z.p-t0;
  .lg.o[`load;"sent ",(string nb*batch)," rows in ",(string el)," -> ",
              (string `long$(nb*batch)%(`float$el)%1000000000)," rows/sec offered"];
  .lg.o[`load;"LOADDONE"];
  };

\d .

.servers.startupdepcycles[`segmentedtickerplant;5;0W];
.load.run[];
