// dry-run report for the weekend compression job (§7, VT-15).
// loaded by vtcompress.q when --dry-run is passed; reads .cmp.scope.
//
// The interesting number is not how many files are in scope but how big they are: a column
// file already inside one filesystem block cannot get smaller on disk however well its bytes
// compress.

\d .cmprep

t:.cmp.scope;
fsblock:4096;                             // ext4 default: the floor on any file's disk usage
alloc:{[b;x] b*ceiling x%b}[fsblock];     // bytes actually allocated for a file of x bytes
s:asc t`currentsize;
pct:{[s;p] s `long$(count[s]-1)*p%100}[s];
mb:{.Q.f[2;x%2 xexp 20]};

// hcount reports a compressed file's UNCOMPRESSED length, so currentsize alone cannot tell
// you whether the job has already run. ask each file's header instead
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

\d .
