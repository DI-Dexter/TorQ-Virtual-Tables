// VT-15.2 / VT-15.3 : does compression break a live reader, and does it pay?
//
// run against a running stack:  ./compress.sh --test
//
// the reader is never told compression happened. it keeps the same handle, the same open
// views, and is not sent a rollover. if its answers change, §7's caveat is real and end of
// day must keep dropping the reader's cache - which is what makes VT-17 impossible. if they
// do not change, the caveat is wrong and end of day can be made flat.

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

logical:{[d] "J"$first system "du -sk --apparent-size ",d," | cut -f1"};
alloc:{[d] "J"$first system "du -sk ",d," | cut -f1"};
pctsaved:{[b;a] $[0=b; 0n; 100*1-a%b]};

idbport:`$"::",string[30+"J"$getenv`KDBBASEPORT],":idb:pass";
h:@[hopen;idbport;{'"no reader on ",string[idbport],": ",x}];
pcol:h".vtidb.partitioncol";

// the target is the oldest complete date - compression must never touch the live one
dates:h"asc distinct raze .vtidb.coverage[]";
if[2>count dates; -1 "  need at least two dates - run the stack across a day boundary first"; exit 77];
d:first dates;
dir:getenv[`KDBDB],"/",string d;

// one row per instrument per table: row count and time bounds. changes if any column file
// stops resolving, or resolves to different bytes
fp:{[h;pcol;d;t] h "0!select cnt:count i, ft:first time, lt:last time by ",
  string[pcol]," from ",string[t]," where date=",string d};

-1 "";
-1 "  reader     ",string idbport;
-1 "  partition  ",string[d]," of ",string[count dates]," present; live is ",string last dates;
-1 "";

// a selective single-instrument query, the case the whole layout exists to make fast.
// compression is not free on read: every block touched has to be inflated first
inst:first h "exec ",string[pcol]," from .vtidb.parts[`trade] where date=",string d;
/ NOTE n#f[x] replicates ONE result n times - it does not run f n times. the index argument
/ is what forces a fresh application per sample
sel:{[h;pcol;d;inst;n] h ({[qry;n] `long$min {[qry;i] t:.z.p; value qry; `long$(.z.p-t)%1000}[qry] each til n};
  "select from trade where date=",string[d],", ",string[pcol],"=`",string[inst];n)};
lat:sel[h;pcol;d;inst];

// start from a known state so the test is repeatable: decompress anything a previous run
// left behind. -19! with algo 0 inflates; the reader is not told, which is itself a check
files:hsym each `$system "find ",dir," -type f ! -name '.d'";
was:sum {0<count -21!x} each files;
if[was; -1 "  ",string[was]," files left compressed by an earlier run - decompressing first";
  {[f] -19!(f; t:hsym`$(string f),"_z"; 16; 0; 0); system"mv ",(1_string t)," ",1_string f} each files];

tabs:h"key .vtidb.parts";
before:fp[h;pcol;d] each tabs;
latbefore:lat 200;
lb:logical dir; ab:alloc dir;
compbefore:sum {0<count -21!x} each files;

-1 "  before     ",string[sum raze {exec cnt from x} each before]," rows in ",string[count files]," column files";
-1 "             ",string[lb]," kB logical, ",string[ab]," kB allocated, ",string[compbefore]," already compressed";
-1 "";
-1 "  compressing - reader stays up, no rollover sent";

t0:.z.p;
system getenv[`TORQAPPHOME],"/compress.sh > /dev/null 2>&1";
-1 "  took       ",string .z.p-t0;
-1 "";

after:fp[h;pcol;d] each tabs;
latafter:lat 200;
la:logical dir; aa:alloc dir;
compafter:sum {0<count -21!x} each files;

check[before~after;
  "reader returns identical results through the same handle, with no rollover"];
check[compafter>compbefore;
  "files are genuinely compressed (",string[compbefore]," -> ",string[compafter]," of ",string[count files],")"];
check[0=count system "find ",dir," -name '*_kdbtempzip'";
  "no temporary files left behind"];
check[0<sum raze {exec cnt from x} each after;
  "the partition still holds rows, so the comparison above is not vacuous"];

// read one leaf cold, in this process, to prove the files are not merely cached in the reader
leaf:first system "find ",dir," -mindepth 2 -maxdepth 2 -type d";
cold:@[{get hsym`$x,"/"};leaf;{`$"ERROR: ",x}];
check[98h=type cold; "a cold process can open a compressed partition directly"];

-1 "";
-1 "  after      ",string[la]," kB logical, ",string[aa]," kB allocated";
-1 "  saved      ",.Q.f[1;pctsaved[lb;la]]," % logical, ",.Q.f[1;pctsaved[ab;aa]]," % allocated";
-1 "";
-1 "  read cost  single-instrument select, min of 200: ",
   string[latbefore]," us -> ",string[latafter]," us  (",
   .Q.f[1;100*-1+latafter%latbefore]," %)";
-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
hclose h;
exit $[fail>0;1;0]
