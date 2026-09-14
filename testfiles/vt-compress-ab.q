/ Does the size gate actually buy anything? (VT-15, §7.3)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-compress-ab.q
/ .
/ The gate skips column files that fit inside one filesystem block, on the grounds that they
/ free no disk. The open question is whether skipping them also costs less to read - a query
/ touches every column of an instrument, so leaving the small ones uncompressed might save
/ decompression work, or might be swamped by the large ones that are still compressed.
/ .
/ Run against a live stack. Reports the MINIMUM latency as well as the median: the box is
/ doing other things, and a minimum over many runs is the robust estimator here.

n:1000;

idbport:`$"::",string[30+"J"$getenv`KDBBASEPORT],":idb:pass";
h:@[hopen;idbport;{'"no reader on ",string[idbport],": ",x}];
pcol:h".vtidb.partitioncol";
d:first h"asc distinct raze .vtidb.coverage[]";
dir:getenv[`KDBDB],"/",string d;
inst:first h "exec ",string[pcol]," from .vtidb.parts[`trade] where date=",string d;

files:hsym each `$system "find ",dir," -type f ! -name '.d'";
ncomp:{[f] sum {0<count -21!x} each f}[files];

decompress:{[files]
  {[f] if[count -21!f;
    -19!(f; t:hsym`$(string f),"_z"; 16; 0; 0);
    system"mv ",(1_string t)," ",1_string f]} each files;
  };

/ same query the layout exists to make fast, run in the reader
/ NOTE n#f[x] replicates ONE result n times - it does not run f n times. the index argument
/ is what forces a fresh application per sample
time:{[h;pcol;d;inst;n] h ({[qry;n] r:asc {[qry;i] t:.z.p; value qry; `long$(.z.p-t)%1000}[qry] each til n;
    (first r; r `long$0.5*count r)};
  "select from trade where date=",string[d],", ",string[pcol],"=`",string[inst];n)};
run:time[h;pcol;d;inst];

go:{[dir;files;decompress;run;n;lbl;gate]
  decompress files;
  if[not null gate;
    system"VTCMP_MINFILESIZE=",string[gate]," VTCMP_CONFIG=",getenv[`KDBAPPCONFIG],
      "/testfiles/compressionconfig-test.csv ",getenv[`TORQAPPHOME],"/compress.sh > /dev/null 2>&1"];
  c:sum {0<count -21!x} each files;
  a:"J"$first system "du -sk ",dir," | cut -f1";
  r:run n;
  `state`compressed`allocKB`minus`medus!(lbl; c; a; r 0; r 1)
  };

-1 "";
-1 "  partition  ",string[d],"   instrument ",string inst;
-1 "  query      select from trade where date=…, ",string[pcol],"=`",string[inst];
-1 "  samples    ",string[n]," per state, reporting min and median";
-1 "";

res:go[dir;files;decompress;run;n] ./: ((`uncompressed;0N); (`gated;4096); (`ungated;0));
show flip res;
-1 "";
hclose h;
exit 0
