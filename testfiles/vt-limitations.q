/ ============================================================================
/ Virtual tables in kdb-x: what works, and what does not
/ ============================================================================
/ Self-contained demonstration. Builds its own database, needs no TorQ.
/ .
/ run:
/   QHOME=~/.kx/q QLIC=~/.kx QPATH=~/.kx/mod:<dir containing mp.q> \
/     ~/.kx/bin/q testfiles/vt-limitations.q
/ .
/ mp.q is Jonathon McMurray's multipart module (DataIntellect). It writes a
/ database partitioned on several dimensions and loads it back as a virtual
/ table. Everything below is about the virtual table layer underneath it,
/ kx.pq.t, which ships with the kdb-x parquet module.
/ .
/ NOTE a line containing only "/" opens a block comment in q - every comment
/ line here carries text after the slash.
/ ============================================================================

system"c 40 200";
.mp:use`mp;
vt:use`kx.pq.t;

hdr :{-1"";-1 (76#"=");-1 x;-1 (76#"=");};
sub :{-1"";-1 "--- ",x," ",(70-count x)#"-";};
note:{-1 "    ",x;};
try :{[d;f] -1""; -1 "  ",d; r:@[f;::;{`$"THREW: ",x}]; $[-11h=type r;-1 "    ",string r;show r]; };
ok  :{[d;f] v:@[{(1b;x[])};f;{(0b;x)}]; -1 (58$"  ",d),$[v 0;"ok";"FAILS: ",v 1]; };

base:"/tmp/vtlimits";
db:hsym`$base;
system"rm -rf ",base;
.mp.create[db;([]column:`date`sym; datatype:"DS")];

mk:{[d;s;n] ([]date:n#d; sym:n#s; time:n#(.z.p+til n); px:n?100f; sz:n?1000i)};
.mp.addparts[db;`quote;.Q.en[db;raze mk[2026.08.03;;50] each `AMD`AAPL]];
.mp.addparts[db;`trades;.Q.en[db;raze mk[2026.08.03;;50] each `AMD`AAPL]];
.mp.loaddb[db];

/ ============================================================================
hdr"PART 1  -  what virtual tables do well";
/ ============================================================================

sub"1.1  the partition columns are removed from the data on disk";
note"on-disk layout is  <date>/<sym>/<table>/<columns>";
try["cols of one leaf splay on disk";{cols get hsym`$base,"/2026.08.03/AMD/quote"}];
note"date and sym are NOT stored - they are implied by the directory path.";
note"that is what makes filtering on them free, and it is the single most";
note"important design decision in the module.";

sub"1.2  filters on partition columns prune whole directories";
try["select from quote where sym=`AMD";{5 sublist select date,sym,px from quote where sym=`AMD}];
note"only the AMD directory is read. AAPL is never opened.";

sub"1.3  appends are visible with no reload, even across processes";
note"a leaf opened as `get `:path/` (WITH a trailing slash) stays live.";
lp:hsym`$base,"/2026.08.03/AMD/quote/";
note"rows before append : ",string count select from quote where sym=`AMD;
lp upsert .Q.en[db;select time,px,sz from mk[2026.08.03;`AMD;10]];
note"rows after  append : ",string count select from quote where sym=`AMD;
note"no reload was performed. this is what lets a writer and readers run";
note"concurrently without coordination.";

/ ============================================================================
hdr"PART 2  -  correctness risks";
/ ============================================================================
note"these produce WRONG ANSWERS rather than errors. none of them announce";
note"themselves. this is the section that matters.";

day:([]time:4#2026.08.03D12:00; sym:`AMD`AAPL`AMD`AAPL; px:10 20 30 40f);
l1 :([]time:2#2026.08.03D12:00; sym:2#`AMD; px:1 2f);
poison:42;   / not a table: any query against it throws, proving it was read

sub"2.1  a partition column that ALSO exists in the data stops pruning";
note"mp avoids this by stripping the column. EXISTING kdb+ databases cannot -";
note"a legacy date-partitioned hdb stores sym inside the table. so this is the";
note"blocker for querying an existing estate through a virtual table.";
try["virtual col named `instrument, not in the leaf -> prunes (poison never read)";
    {vx:vt.mkP ([]date:2#2026.08.03; instrument:`AMD`AAPL)!(l1;poison);
     select from vx where instrument=`AMD}];
try["virtual col named `sym, which IS in the leaf -> does NOT prune";
    {vy:vt.mkP ([]date:2#2026.08.03; sym:`AMD`AAPL)!(l1;poison);
     select from vy where sym=`AMD}];
note"identical query, identical data. only the column NAME differs.";
note"when the name collides the constraint is pushed to every leaf instead of";
note"being used to select leaves, so the whole database is scanned.";

sub"2.2  mapping many partition keys onto one shared table: wrong both ways";
note"this is how you would attach an existing date-partitioned hdb partition:";
note"many (date,sym) keys all pointing at the same whole-day table.";
try["distinct name -> returns EVERY sym, all labelled AMD";
    {va:vt.mkP ([]date:2#2026.08.03; instrument:`AMD`AAPL)!(day;day);
     select from va where instrument=`AMD}];
try["shadowed name -> correct syms, but every row DUPLICATED per key row";
    {vb:vt.mkP ([]date:2#2026.08.03; sym:`AMD`AAPL)!(day;day);
     select from vb where sym=`AMD}];
try["no constraint at all -> 8 rows out of a 4-row table";
    {vb:vt.mkP ([]date:2#2026.08.03; sym:`AMD`AAPL)!(day;day);
     select sym,px from vb}];
note"with 10,000 instruments sharing a day partition that is a 10,000x row";
note"amplification, silently.";
try["writing BOTH constraints by hand gives the right answer";
    {va:vt.mkP ([]date:2#2026.08.03; instrument:`AMD`AAPL)!(day;day);
     select from va where instrument=`AMD, sym=`AMD}];
note"so the engine can already compute it correctly - it just cannot be reached";
note"from a single constraint. that is the fix we are asking KX for.";

sub"2.3  nested partition values are silently scrambled";
note"one key row holding a LIST of instruments - the compact way to describe";
note"a legacy partition. mkP accepts it and then mis-attributes the rows.";
day2:([]sym:`AMD`AMD`AAPL`AAPL; px:10 20 30 40f);
try["leaf is AMD,AMD,AAPL,AAPL - compare 'instruments' against 'sym'";
    {k:([]date:2026.08.03 2026.08.04; instruments:(`AMD`AAPL;`MSFT`AUDUSD));
     vn:vt.mkP k!(day2;poison);
     select date,instruments,sym,px from vn where date=2026.08.03}];
note"rows 2 and 3 are attributed to the wrong instrument. the nested value is";
note"cycled positionally across the rows rather than held constant. with a";
note"3-element list against 4 rows it wraps around.";
note"the output is a well-formed table of plausible symbols. nothing indicates";
note"it is wrong.";

sub"2.4  new partitions are silently invisible until an explicit reload";
note"rows before adding a new instrument : ",string count select from quote;
.mp.addparts[db;`quote;.Q.en[db;mk[2026.08.03;`MSFT;7]]];
note"USDJPY written to the quote table on disk.";
note"rows now, no reload                 : ",string count select from quote;
try["select from quote where sym=`MSFT  -> empty, not an error";
    {select from quote where sym=`MSFT}];
note"appends are live (1.3) but NEW partitions are not. in a capture system a";
note"new instrument arriving intraday is invisible until someone reloads.";

sub"2.5  a partition present for one table but not another breaks the reload";
note"USDJPY has quote but has not traded yet - a completely normal state for";
note"any real feed. reloading now:";
try["  .mp.loaddb[db]";{.mp.loaddb[db]; `reloaded}];
note"the whole database fails to load, not just the missing table. every";
note"partition value must exist for every table.";
note"standard kdb+ solves this with .Q.chk, which creates the empty table";
note"directories. there is no equivalent here.";
note"";
note"creating the missing directory by hand and retrying:";
(hsym`$base,"/2026.08.03/USDJPY/trades/") set .Q.en[db;select time,px,sz from 0#mk[2026.08.03;`MSFT;1]];
try["  .mp.loaddb[db]";{.mp.loaddb[db]; `reloaded}];
note"rows after reload                   : ",string count select from quote;

/ ============================================================================
hdr"PART 3  -  ordinary q operations that do not work";
/ ============================================================================
note"virtual tables are not drop-in replacements for tables. a client library,";
note"dashboard or analyst script written against normal kdb+ will hit these.";
-1"";

ok["meta quote";                              {meta quote}];
ok["cols quote";                              {cols quote}];
ok["quote[`px]              (index by column)";{quote`px}];
ok["`px xasc quote          (sort)";          {`px xasc quote}];
ok["exec distinct sym from quote   (virtual col)";{exec distinct sym from quote}];
ok["update px2:2*px from quote";              {update px2:2*px from quote}];
ok["delete px from quote";                    {delete px from quote}];
ok["select by time.minute      (dot notation)";{select sum px by time.minute from quote}];
ok["select by 5 xbar time.minute";             {select sum px by 5 xbar time.minute from quote}];
-1"";
note"for contrast, these all work:";
ok["count quote";                             {count quote}];
ok["select from quote where sym=`AMD";     {select from quote where sym=`AMD}];
ok["select distinct sym from quote";          {select distinct sym from quote}];
ok["exec px from quote        (leaf col)";    {exec px from quote}];
ok["select sum px by sym from quote";         {select sum px by sym from quote}];
ok["aj[`sym`time;trades;quote]";              {aj[`sym`time;select from trades;select from quote]}];
ok["lj";                                       {(select from trades) lj 2!select from quote}];
ok["10 sublist quote";                        {10 sublist quote}];

/ ============================================================================
hdr"PART 4  -  partition-pruning hints: present but unusable for symbols";
/ ============================================================================
note"the module supports per-partition min/max statistics, via hidden virtual";
note"columns named 9<col>9min and 9<col>9max. they work - for numeric columns.";

kn:flip (`date,`$("9px9min";"9px9max"))!(2#2026.08.03; 1 3f; 2 4f);
vnum:vt.mkP kn!(l1;poison);
try["numeric: where px<2.5    -> prunes, poison never read";{select from vnum where px<2.5}];
try["numeric: where px=1.0    -> NOT pruned, = is unsupported";{select from vnum where px=1.0}];

ks:flip (`date,`$("9sym9min";"9sym9max"))!(2#2026.08.03; `AMD`AAPL; `AMD`AAPL);
vsym:vt.mkP ks!(l1;poison);
try["symbol : where sym>=`AMD, sym<=`AMD  -> NOT pruned";
    {select from vsym where sym>=`AMD, sym<=`AMD}];
note"the engine works out which side of the constraint is the column name by";
note"asking which one is a symbol. for `sym>=`AMD` both sides are symbols,";
note"so it cannot tell them apart and gives up.";
show ([]constraint:("px<2.5";"sym>=`AMD");
       bothsidessymbol:(0b;1b);
       hintusable:(1b;0b));
note"symbol columns are the commonest partition key in kdb+, so in practice the";
note"hint mechanism is unavailable exactly where it is most wanted.";

/ ============================================================================
hdr"SUMMARY";
/ ============================================================================
-1"";
show ([]
  area:("partition pruning";"live appends";"legacy data";"shared partitions";
        "nested keys";"new partitions";"q compatibility";"pruning hints");
  status:(`works;`works;`BLOCKED;`WRONG;`WRONG;`reload;`partial;`unusable);
  detail:(
    "free filtering on partition columns; big speedup vs splay";
    "readers see writers with no reload, cross-process";
    "a column in both the key and the data stops all pruning";
    "many keys -> one table gives mislabelled or duplicated rows";
    "nested partition values are cycled positionally, mis-attributing rows";
    "appends are live but new partitions need an explicit reload";
    "meta, cols, xasc, update, delete, dot notation all fail";
    "min/max hints exist but cannot be used on symbol columns"));

-1"";
-1"The three marked BLOCKED/WRONG are correctness issues, not performance ones,";
-1"and all three trace to a single behaviour: when a column name exists in both";
-1"the virtual key and the underlying data, the constraint is applied in only";
-1"one place instead of both. Fixing that resolves all three.";
-1"";
-1"Everything in PART 1 is available today and needs no changes.";

exit 0
