/ probe of kx.pq.t virtual-table semantics - evidence for docs/virtual-table-capture-pack.md
/ section 9. NOTE a line containing only "/" opens a multi-line comment block in q - every
/ comment line here must carry text after the slash.
/ run:
/   QHOME=~/.kx/q QLIC=~/.kx QPATH=~/.kx/mod ~/.kx/bin/q testfiles/vt-probe.q
/ method: leaf 2 is a "poison" value (an int, not a table). any attempt to query it
/ throws, so "THREW" proves the engine read that leaf; a clean result proves it pruned.
/ leaf 1 must be a real table - mkP introspects the first leaf for its column list.

.pq.t:use`kx.pq.t;

l1:([]time:2#2026.08.03D12:00; sym:2#`AMD; px:1 2f);
l2:([]time:2#2026.08.03D12:00; sym:2#`AAPL; px:3 4f);
day:([]time:4#2026.08.03D12:00; sym:`AMD`AAPL`AMD`AAPL; px:10 20 30 40f);
poison:42;

try:{[d;f] -1 ""; -1 d; show @[f;::;{"THREW: ",x}]; };

-1 "=== 1. pruning on a virtual column that does NOT shadow a leaf column ===";
vt1:.pq.t.mkP ([]date:2026.08.03 2026.08.04)!(l1;poison);
try["1a  where date=2026.08.03            -> expect CLEAN (pruned)";{select from vt1 where date=2026.08.03}];
vt2:.pq.t.mkP ([]date:2#2026.08.03; instrument:`AMD`AAPL)!(l1;poison);
try["1b  where instrument=`AMD         -> expect CLEAN (pruned)";{select from vt2 where instrument=`AMD}];

-1 "";
-1 "=== 2. pruning on a virtual column that DOES shadow a leaf column ===";
vt3:.pq.t.mkP ([]date:2#2026.08.03; sym:`AMD`AAPL)!(l1;poison);
try["2a  where sym=`AMD                -> expect THREW (no pruning, all leaves read)";{select from vt3 where sym=`AMD}];

-1 "";
-1 "=== 3. correctness of the shadowed case, one leaf per instrument (greenfield) ===";
vt4:.pq.t.mkP ([]date:2#2026.08.03; sym:`AMD`AAPL)!(l1;l2);
try["3a  where sym=`AMD                -> expect px 1 2 only, sym column twice";{select from vt4 where sym=`AMD}];
try["3b  select sum px by sym             -> expect AMD 3, AAPL 7";{select sum px by sym from vt4}];

-1 "";
-1 "=== 4. replicated links: many key rows -> ONE shared leaf (backward compat) ===";
vt5:.pq.t.mkP ([]date:2#2026.08.03; instrument:`AMD`AAPL)!(day;day);
try["4a  distinct name, where instrument=`AMD -> WRONG: returns AAPL rows too";{select from vt5 where instrument=`AMD}];
vt6:.pq.t.mkP ([]date:2#2026.08.03; sym:`AMD`AAPL)!(day;day);
try["4b  shadowed name, where sym=`AMD        -> WRONG: each row duplicated per key row";{select from vt6 where sym=`AMD}];

-1 "";
-1 "=== 5. min/max statistics columns, named 9<col>9min / 9<col>9max ===";
k7:flip (`date,`$("9px9min";"9px9max"))!(2#2026.08.03; 1 3f; 2 4f);
vt7:.pq.t.mkP k7!(l1;poison);
try["5a  where px<2.5                     -> expect CLEAN (stats pruned leaf2)";{select from vt7 where px<2.5}];
try["5b  where px<=2.0                    -> expect CLEAN";{select from vt7 where px<=2.0}];
try["5c  where px>2.5                     -> expect THREW (leaf2 is the real match)";{select from vt7 where px>2.5}];
try["5d  where px=1.0                     -> expect THREW (= not supported)";{select from vt7 where px=1.0}];
try["5e  where px within 1 2              -> expect THREW (within not supported)";{select from vt7 where px within 1 2}];
try["5f  no constraint                    -> expect THREW";{select from vt7}];
-1 "";
-1 "5g  9-prefixed columns are hidden from the result (see 5a output: no 9px9min column)";

-1 "";
-1 "=== 6. statistics on a SYMBOL column ===";
k8:flip (`date,`$("9sym9min";"9sym9max"))!(2#2026.08.03; `AMD`AAPL; `AMD`AAPL);
vt8:.pq.t.mkP k8!(l1;poison);
try["6a  where sym>=`AMD, sym<=`AMD -> expect THREW (symbols unsupported)";{select from vt8 where sym>=`AMD, sym<=`AMD}];
-1 "";
-1 "  why: qc identifies which argument is the column by testing which one is a symbol";
-1 "  atom, so a symbol VALUE is indistinguishable from a column name and it gives up:";
show ([]case:`symbol`numeric; args:((`sym;`AMD);(`px;2.5)); istypesymbol:(-11h=type each (`sym;`AMD);-11h=type each (`px;2.5)));
-1 "  the engine requires 10b (column identified); the symbol case gives 11b.";


-1 "";
-1 "=== 7. null statistic means keep the partition ===";
k9:flip (`date,`$("9px9min";"9px9max"))!(2#2026.08.03; 1 0n; 2 0n);
vt9:.pq.t.mkP k9!(l1;poison);
try["7a  where px<2.5, leaf2 stats null   -> expect THREW (null => keep => safe)";{select from vt9 where px<2.5}];

-1 "";
-1 "=== 8. nested virtual key columns (backward-compat option 3) ===";
k10:([]date:2026.08.03 2026.08.04; instruments:(`AMD`AAPL;`MSFT`AUDUSD));
vt10:.pq.t.mkP k10!(day;poison);
try["8a  can mkP be built with a nested key column?              -> yes";{.pq.t.mkP k10!(day;poison); `built}];
try["8b  where instruments=`AMD                               -> THREW, = unsupported on nested";{select from vt10 where instruments=`AMD}];
try["8c  where any each instruments=`AMD                      -> prunes, but leaf unconstrained";{select from vt10 where any each instruments=`AMD}];
-1 "";
-1 "  8d  the nested key value is RECYCLED POSITIONALLY across leaf rows.";
-1 "      leaf below is AMD,AMD,AAPL,AAPL - watch the 'instruments' label:";
day8:([]sym:`AMD`AMD`AAPL`AAPL; px:10 20 30 40f);
vt10b:.pq.t.mkP k10!(day8;poison);
show select date,instruments,sym,px from vt10b where date=2026.08.03;
-1 "      rows 2 and 3 are mislabelled. with a 3-element list it wraps around.";

exit 0
