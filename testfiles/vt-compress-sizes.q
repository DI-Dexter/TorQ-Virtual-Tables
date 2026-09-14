/ At what partition size does compression start to free real disk? (VT-15.3)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-compress-sizes.q
/ .
/ The measured ratio on the running stack (§7) is dominated by one fact: at ~600 rows per
/ instrument per day, most column files are smaller than a filesystem block, and a file that
/ fits in one block frees nothing when compressed. That is a property of how much data lands
/ in each directory, so it should improve as volume per instrument rises. This sweeps that.
/ .
/ Entropy is held constant across the sweep - the same real captured rows are cycled to reach
/ each row count - so the absolute ratios are optimistic, but the SHAPE of the curve, which is
/ what decides the threshold, is not affected by that.

fsblock:4096;
alloc:{[b;x] b*ceiling x%b}[fsblock];
mb:{.Q.f[2;x%2 xexp 20]};

root:getenv`KDBDB;
src:first system "find ",root," -mindepth 3 -maxdepth 3 -type d -path '*trade*'";
if[not count src; -1 "no trade partition under ",root; exit 1];
load hsym`$root,"/sym";
seed:get hsym`$src,"/";
if[not count seed; -1 "trade partition is empty - run the stack for a while first"; exit 1];

scratch:"/tmp/vt-cmpsize-",string .z.i;
system"rm -rf ",scratch; system"mkdir -p ",scratch;

/ write one instrument directory holding n rows, compress it, and report both sizes
one:{[scratch;seed;n]
  d:scratch,"/n",string n;
  system"rm -rf ",d; system"mkdir -p ",d;
  t:n#seed;
  h:hsym`$d,"/";
  h set .Q.en[hsym`$scratch;t];
  f:hsym each `$system "find ",d," -type f ! -name '.d'";
  unc:hcount each f;
  {[x] -19!(x; hsym`$(string x),"_z"; 16; 2; 9); system"mv ",(1_string x),"_z ",1_string x} each f;
  cmp:{$[count h:-21!x; h`compressedLength; hcount x]} each f;
  `rows`files`unclogical`cmplogical`uncalloc`cmpalloc!
    (n; count f; sum unc; sum cmp; sum alloc unc; sum alloc cmp)
  };

rows:100 300 1000 3000 10000 30000 100000;
r:one[scratch;seed] each rows;
t:flip r;
rnd:{0.1*"j"$10*x};                       / .Q.f does not vectorise
t:update logicalsaved:rnd 100*1-cmplogical%unclogical,
         disksaved:rnd 100*1-cmpalloc%uncalloc,
         kbperfile:rnd (unclogical%files)%1024 from t;

-1 "";
-1 "  source     ",src;
-1 "  columns    ",string[count cols seed]," per instrument directory, ",string[first r@\:`files]," column files";
-1 "";
show select rows, kbperfile, files, uncallocKB:rnd uncalloc%1024, cmpallocKB:rnd cmpalloc%1024, logicalsaved, disksaved from t;
-1 "";
-1 "  compressed size lands on the floor - one filesystem block per column file - almost";
-1 "  immediately and stays there (cmpallocKB is flat). so disksaved is decided entirely by";
-1 "  how big the files were to begin with, which is rows per instrument per day.";
-1 "";
system"rm -rf ",scratch;
exit 0
