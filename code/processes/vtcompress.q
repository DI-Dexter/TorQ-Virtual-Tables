// Virtual-table capture pack : compression process
// see docs/virtual-table-capture-pack.md §4.4 and §7
//
// Replaces code/processes/compression.q: same job - walk the tree, compress anything older
// than minage, exit - but first corrects the directory classifier, which cannot see a
// date+instrument layout.
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

// The size gate. A column file already inside one filesystem block frees nothing when
// compressed and only adds decompression work to every read; at this layout a third of all
// files are in that state and free 0% of disk (§7.2). 0 disables the gate, as stock does.
minfilesize:@[value;`minfilesize;4096];
if[count e:getenv`VTCMP_MINFILESIZE; minfilesize:"J"$e];

// Stock hdbstructure classifies a path by depth and knows only partition/table/column and
// table/column. A partbyattr column file sits one deeper, so it matches neither, `table` stays
// null, and showcomp drops every row - the job succeeds and compresses nothing. Adding the
// extra depth folds the instrument level away, so per-column rules keep working unchanged.
//
// Must be applied here, not in appconfig/settings/compression.q: settings load before
// code/common/compress.q, so an override there is overwritten by the stock definition.
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
  system"l ",getenv[`TORQAPPHOME],"/code/processes/vtcompress-report.q";
  exit 0];

.cmp.compressfromtable[.cmp.scope];
.cmp.summarystats[];
.lg.o[`compression;"finished compression"];
exit 0
