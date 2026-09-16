/ Simple sample for testing the legacy-data claims. All in memory, no disk.
/ run:  \l testfiles/vt-sample-legacy.q

vt:use`kx.pq.t;

/ two days of a legacy hdb: one table per date, sym stored INSIDE the table
day1:([]sym:`AMD`AAPL`AMD; price:1.08 1.26 1.09; size:100 200 300);
day2:([]sym:`AMD`AAPL;        price:1.10 1.25;      size:400 500);

/ the truth: 5 rows total, 3 AMD, 2 AAPL
truth:day1,day2;

/ option 0 - key on date only                        (recommended)
v0:vt.mkP ([]date:2020.01.01 2020.01.02)!(day1;day2);

/ option 1 - replicated links, one key row per (date;sym)
v1:vt.mkP ([]date:2020.01.01 2020.01.01 2020.01.02 2020.01.02;
           sym :`AMD`AAPL`AMD`AAPL)!(day1;day1;day2;day2);

/ option 2 - null / wildcard sym
v2:vt.mkP ([]date:2020.01.01 2020.01.02; sym:2#`)!(day1;day2);

/ option 3 - nested list of syms
v3:vt.mkP ([]date:2020.01.01 2020.01.02;
           sym :(`AMD`AAPL;`AMD`AAPL))!(day1;day2);

/ option 3 but with deliberate NONSENSE in the key - proves the key is ignored
bad:vt.mkP ([]date:2020.01.01 2020.01.02;
            sym :(`AAA`BBB;`CCC`DDD))!(day1;day2);

-1 "truth: ",string[count truth]," rows, AMD=",
   string[count select from truth where sym=`AMD];
-1 "";
-1 "count select from ... where sym=`AMD   (should be 3):";
-1 "  v0  (date only)    : ",string count select from v0  where sym=`AMD;
-1 "  v1  (replicated)   : ",string count select from v1  where sym=`AMD;
-1 "  v2  (null key)     : ",string count select from v2  where sym=`AMD;
-1 "  v3  (nested key)   : ",string count select from v3  where sym=`AMD;
-1 "  bad (nonsense key) : ",string count select from bad where sym=`AMD;
-1 "";
-1 "select sum size by sym from truth:"; show select sum size by sym from truth;
-1 "... from v1 (duplicated):";          show select sum size by sym from v1;
-1 "... from v3:";                       show select sum size by sym from v3;
-1 "";
-1 "v1 in full - the duplication:";
show select date,sym,price,size from v1 where sym=`AMD;
