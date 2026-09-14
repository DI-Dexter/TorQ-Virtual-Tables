/ Does compression pay on a date+instrument tree? (VT-15.3)
/ .
/ Run after ./compress.sh, against real captured data:
/     cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-compress-ratio.q
/ .
/ Reads every compressed column file's own header, which carries both the compressed and the
/ uncompressed length, so no data has to be regenerated or re-compressed to measure it.
/ .
/ The question is not "how well do these bytes compress" - they compress very well - but
/ "how much disk does that free". A file is allocated in whole filesystem blocks, so a column
/ that already fits in one block cannot get smaller however well it compresses. Splitting by
/ instrument makes column files small, which is exactly where that floor bites.

fsblock:4096;
alloc:{[b;x] b*ceiling x%b}[fsblock];
mb:{.Q.f[2;x%2 xexp 20]};

root:getenv`KDBDB;
files:hsym each `$system "find ",root," -type f ! -name '.d' ! -name 'sym'";
if[not count files; -1 "nothing under ",root; exit 1];

/ -21! returns an empty dictionary for a file that is not compressed - those carry no
/ uncompressed length to compare against, so they are counted and then excluded
hdr:{[f] -21!f} each files;
done:where 0<count each hdr;
skipped:count[files]-count done;
hdr:hdr done;
t:([]file:files done; comp:hdr@\:`compressedLength; unc:hdr@\:`uncompressedLength);
t:select from t where unc>0;
if[not count t; -1 "  no compressed files under ",root," - run ./compress.sh first"; exit 1];

/ what the file actually costs on disk now, versus what it cost before
t:update allocnow:alloc comp, allocwas:alloc unc from t;

-1 "";
-1 "  ",string[count t]," compressed column files under ",root;
-1 "  ",string[skipped]," uncompressed files skipped (the live partition, which minage protects)";
-1 "";
-1 "  logical    ",mb[sum t`unc]," MB -> ",mb[sum t`comp]," MB   (",.Q.f[1;100*1-(sum t`comp)%sum t`unc]," % saved)";
-1 "  on disk    ",mb[sum t`allocwas]," MB -> ",mb[sum t`allocnow]," MB   (",.Q.f[1;100*1-(sum t`allocnow)%sum t`allocwas]," % saved)";
-1 "";

/ bucket by the size the file had BEFORE compression - that is the number a capacity plan has
bucket:{[x] $[x<1024;`$"   <1 kB"; x<4096;`$" 1-4 kB"; x<16384;`$" 4-16 kB"; x<65536;`$"16-64 kB";`$"  >64 kB"]};
t:update sizeband:bucket each unc from t;

-1 "  by original file size:";
-1 "";
show `sizeband xasc 0!select
  files:count i,
  logicalsaved:"F"$.Q.f[1;100*1-(sum comp)%sum unc],
  disksaved:"F"$.Q.f[1;100*1-(sum allocnow)%sum allocwas],
  blockswas:(sum allocwas)%fsblock,
  blocksnow:(sum allocnow)%fsblock
  by sizeband from t;

-1 "";
-1 "  a file under 4 kB occupies one block before and one block after: its logical saving is";
-1 "  real but frees nothing. that band is where instrument-splitting puts most column files.";
-1 "";
exit 0
