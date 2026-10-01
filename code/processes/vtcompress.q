// Virtual-table capture pack : compression process
// see docs/virtual-table-capture-pack.md §4.4 and §7
//
// Replaces code/processes/compression.q: same job - walk the tree, compress anything older
// than minage, exit - but first corrects the directory classifier. §4.4
//
//   ./compress.sh              compress
//   ./compress.sh --dry-run    report what would be compressed, change nothing

\d .cmp

inputcsv:@[value;`inputcsv;.proc.getconfigfile["compressionconfig.csv"]];
hdbpath:@[value;`hdbpath;`:hdb];
maxage:@[value;`maxage;365];
dryrun:`dryrun in key .proc.params;

// the age tier lives in the csv as minage. VTCMP_CONFIG points at a different csv, which is
// how ./compress.sh --test exercises the job against a database only a couple of days old
if[count e:getenv`VTCMP_CONFIG; inputcsv:e];

// The size gate. A file already inside one filesystem block frees nothing when compressed.
// 0 disables the gate, as stock does. §7.2
minfilesize:@[value;`minfilesize;4096];
if[count e:getenv`VTCMP_MINFILESIZE; minfilesize:"J"$e];

// Stock hdbstructure classifies a path by depth and does not know about the instrument level.
// Must be applied here, not in settings: those load before code/common/compress.q. §4.4
hdbstructure:{
  t:([]fullpath:(raze/)traverse x);
  base:count "/" vs string x;
  t:update splitcount:count each split from update split:"/" vs' string fullpath,column:`,table:`,partition:(count t)#enlist"" from t;
  / date partitioned : partition/table/column
  t:update partition:split[;base],table:`$split[;base+1],column:`$split[;base+2] from t where splitcount=base+3;
  / partbyattr : partition/table/instrument/column
  t:update partition:split[;base],table:`$split[;base+1],column:`$split[;base+3] from t where splitcount=base+4;
  / splayed : table/column
  t:update table:`$split[;base],column:`$split[;base+1] from t where splitcount=base+2;
  t:update partition:{$[not all null r:"D"$'x;r;not all null r:"M"$'x;r;"I"$'x]}[partition] from t;
  $[14h=type t`partition; t:update age:.z.D - partition from t;
    13h=type t`partition; t:update age:(`month$.z.D) - partition from t;
    t:update age:{$[all x within 1000 3000; x - `year$.z.D;(count x)#0Ni]}[partition] from t];
  delete splitcount,split from t
  };

// The --dry-run report: total bytes in scope, not just the file count. §7.2
dryrunreport:{[t]
  fsblock:4096;                                     // ext4 default: the floor on any file's disk usage
  alloc:{[b;x] b*ceiling x%b}[fsblock];             // bytes actually allocated for a file of x bytes
  s:asc t`currentsize;
  pct:{[s;p] s `long$(count[s]-1)*p%100}[s];
  mb:{.Q.f[2;x%2 xexp 20]};
  / hcount reports a compressed file's UNCOMPRESSED length, so currentsize alone cannot tell
  / whether the job has already run - ask each file's header instead
  done:sum {0<count -21!x} each t`fullpath;
  -1 "";
  -1 "  database   ",string .cmp.hdbpath;
  -1 "  config     ",.cmp.inputcsv;
  -1 "  age tier   partitions older than ",string[exec first compressage from t]," days";
  -1 "  size gate  files of ",string[.cmp.minfilesize]," bytes or less are skipped: ",
     string[.cmp.toosmall]," excluded";
  -1 "";
  -1 "  in scope   ",string[count t]," files, ",string[count distinct t`partition]," partitions, ",
     string[count distinct t`table]," tables";
  -1 "  to do      ",string[count[t]-done]," files (",string[done]," already compressed, which the job skips)";
  -1 "";
  -1 "  the sizes below are logical - what the columns hold - so they do not change once the";
  -1 "  job has run. they describe what compression has to work with, not what is on disk now.";
  -1 "";
  -1 "  file size  min ",string[first s],"  p50 ",string[pct 50],"  p90 ",string[pct 90],"  max ",string[last s]," bytes";
  -1 "  under 4 kB ",string[sum s<fsblock]," of ",string[count s]," files (",string[`long$100*avg s<fsblock],"%)";
  -1 "";
  -1 "  logical    ",mb[sum s]," MB     <- bytes the columns hold";
  -1 "  allocated  ",mb[sum alloc s]," MB     <- what those bytes cost on disk uncompressed";
  -1 "  floor      ",mb[fsblock*count s]," MB     <- one block per file, unavoidable";
  -1 "  headroom   ",mb[(sum alloc s)-fsblock*count s]," MB     <- the most compression can ever free";
  -1 "";
  -1 "  by table";
  show 0!select files:count i, logicalmb:"F"$mb sum currentsize, underblock:sum currentsize<fsblock by table from t;
  -1 "";
  };

\d .

if[not count key hsym .cmp.hdbpath;
  .lg.e[`compression;err:"invalid database path ",string .cmp.hdbpath]; 'err];

.cmp.scope:.cmp.showcomp[hsym .cmp.hdbpath;.cmp.inputcsv;.cmp.maxage];

// apply the size gate. done here rather than in the csv because compressionconfig.csv rules
// are per table and per column, and this depends on how much data landed in one directory
.cmp.toosmall:0;
if[.cmp.minfilesize>0;
  .cmp.toosmall:exec count i from .cmp.scope where currentsize<=.cmp.minfilesize;
  .cmp.scope:select from .cmp.scope where currentsize>.cmp.minfilesize;
  if[.cmp.toosmall; .lg.o[`compression;"size gate: skipping ",string[.cmp.toosmall],
    " files of ",string[.cmp.minfilesize]," bytes or less - they cannot free a block"]]];

if[not count .cmp.scope;
  .lg.o[`compression;"nothing in scope - either the tree is empty, or every partition is younger than minage"];
  exit 0];

.lg.o[`compression;"in scope: ",string[count .cmp.scope]," files across ",
  string[count distinct .cmp.scope`partition]," partitions"];

if[.cmp.dryrun;
  .cmp.dryrunreport .cmp.scope;
  exit 0];

.cmp.compressfromtable[.cmp.scope];
.cmp.summarystats[];
.lg.o[`compression;"finished compression"];
exit 0
