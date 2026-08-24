// Virtual-table capture pack : compression process
// see docs/virtual-table-capture-pack.md §4.4 and §7
//
// replaces code/processes/compression.q. same job - walk the tree, compress anything older
// than minage, exit - but it first corrects the directory classifier, which cannot see a
// date+instrument layout.
//
//   ./compress.sh              compress
//   ./compress.sh --dry-run    report what would be compressed, change nothing

\d .cmp

inputcsv:@[value;`inputcsv;.proc.getconfigfile["compressionconfig.csv"]];
hdbpath:@[value;`hdbpath;`:hdb];
maxage:@[value;`maxage;365];
dryrun:@[{[x] `dryrun in key .proc.params};::;0b];

// the age tier lives in the csv as minage. VTCMP_CONFIG points at a different csv, which is
// how ./compress.sh --test exercises the job against a database only a couple of days old
if[count e:getenv`VTCMP_CONFIG; inputcsv:e];

// the size gate. a file is allocated in whole filesystem blocks, so a column file that
// already fits inside one block frees nothing when compressed - it only adds decompression
// work to every read. measured: at this layout a third of all column files are in that
// state, and their bands free 0% of disk (§7.2). skip them.
// 0 disables the gate and compresses everything, which is the stock behaviour.
minfilesize:@[value;`minfilesize;4096];
if[count e:getenv`VTCMP_MINFILESIZE; minfilesize:"J"$e];

// stock hdbstructure classifies a path purely by how deep it is, and knows only two shapes:
// partition/table/column and table/column. a partbyattr column file sits one level deeper,
// at partition/table/instrument/column, so it matches neither, `table` stays null, and
// showcomp's "delete from pathstab where table in `" then drops every row - the job runs
// successfully and compresses nothing. adding the extra depth folds the instrument level
// away, so per-column rules in compressionconfig.csv keep working unchanged.
//
// this has to be applied here rather than in appconfig/settings/compression.q: settings load
// before code/common/compress.q, so an override there is overwritten by the stock definition.
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
