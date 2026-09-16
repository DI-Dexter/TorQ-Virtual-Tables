/ What does on-disk damage to one partition actually do? (§4.6)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-damage-test.q
/ .
/ §4.6 established that a MISSING table directory is served as a silently absent date. This
/ asks the next question: what about a directory that is present but damaged? Three kinds,
/ because they behave three different ways and only one of them is loud:
/ .
/   truncated column   the partition attaches and silently returns FEWER ROWS - the table is
/                      cut to its shortest column. no warning. this is the dangerous one.
/                      note it is specific to UNCOMPRESSED columns: a compressed one has a
/                      metadata header that kdb+ checks, so the same damage raises instead
/ .
/   missing .d         the reader cannot type the directory, logs "skipped 1 unreadable
/                      partition(s)" and leaves it out. that instrument then reads as absent
/ .
/   corrupt column     any query that opens the directory errors, loudly, with the file path
/ .
/ The blast radius is the useful part: a SELECTIVE query on a healthy instrument is unaffected,
/ because the damaged directory is never opened. Whole-database queries fail - including ones
/ that do not name the damaged column, since they still have to open every directory.
/ .
/ Runs entirely on a scratch copy. Nothing here touches the live database.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

/ enough of the TorQ framework for vtidb.q to load standalone
.lg.o:{[t;m]}; .lg.w:{[t;m] warns,:enlist m}; .lg.e:{[t;m] errs,:enlist m};
.servers.startupdepcycles:{[t;i;c] '"no wdb in this test"};
.servers.gethandlebytype:{[t;m] ()};
.timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};
warns:(); errs:();

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };
try:{[f;a] .[f;a;{`$"ERROR: ",x}]};
/ NOTE the query text already says "count select …", so this must NOT count again - count of
/ an atom is 1, which made every result look like a single row
cnt:{[q] try[{[x] value x};enlist q]};

live:getenv`KDBDB;
s:"/tmp/vt-damage-",string .z.i;
src:first asc key[hsym`$live] where key[hsym`$live] like "[0-9][0-9][0-9][0-9].*";
if[null src; -1 "  no partitions under ",live," - start the stack first"; exit 77];

system"rm -rf ",s; system"mkdir -p ",s;
system"cp ",live,"/sym ",s,"/";
system"cp -r ",live,"/",(string src)," ",s,"/2026.01.01";

d:s,"/2026.01.01/trade";
insts:key hsym`$d;
if[6>count insts; -1 "  need at least 6 instruments to damage three and keep healthy ones"; exit 77];

trunc:string insts 0;
nodotd:string insts 1;
garbage:string insts 2;
healthy:string insts 5;

whole:cnt "count select from trade";                / before any damage, for comparison

/ the source partition may already be compressed - vt-compress-test compresses everything
/ older than a day in var/db and leaves it that way, so a second run of the suite copies a
/ compressed partition here. that matters: a compressed column carries a metadata header
/ which kdb+ validates, so truncating one RAISES "bad meta data in file" where truncating an
/ uncompressed one short-reads silently. the silent case is the dangerous one and the one
/ under test, so rewrite the target column plain and assert against a known state.
tp:hsym`$d,"/",trunc,"/price";
if[count -21!tp;
  .z.zd:(17;0;0);                                  / algo 0 - write it back uncompressed
  (hsym`$d,"/",trunc,"/price.plain") set get tp;
  system"x .z.zd";
  system"mv ",d,"/",trunc,"/price.plain ",d,"/",trunc,"/price"];

system"truncate -s 40 ",d,"/",trunc,"/price";
system"rm ",d,"/",nodotd,"/.d";
system"dd if=/dev/urandom of=",d,"/",garbage,"/time bs=200 count=1 2>/dev/null";

-1 "";
-1 "  scratch    ",s;
-1 "  damaged    ",trunc," (truncated price), ",nodotd," (no .d), ",garbage," (corrupt time)";
-1 "  healthy    ",healthy;
-1 "";

.vtidb.roots:enlist hsym`$s;
.vtidb.partitioncol:`sym;
system"l ",getenv[`KDBAPPCODE],"/processes/vtidb.q";
.vtidb.current:2026.01.02;
.vtidb.dropcache[]; .vtidb.rebuild[];

attached:count .vtidb.parts`trade;
-1 "  attached   ",string[attached]," of ",string[count insts]," directories";
-1 "";

/ ---------------------------------------------------------------------------
check[attached=count[insts]-1;
  "the .d-less directory is excluded; the other two are attached"];
check[any warns like "*unreadable partition*";
  "and its exclusion is logged, not silent"];

ntrunc:cnt "count select from trade where sym=`",trunc;
check[$[-7h=type ntrunc; ntrunc>0; 0b];         / $[] short-circuits, `and` does not
  "KNOWN, AND SILENT: a truncated column attaches and returns ",string[ntrunc]," rows"];
check[not any warns like "*",trunc,"*";
  "  - with no warning naming it. shortest column wins, quietly"];

check[0=cnt "count select from trade where sym=`",nodotd;
  "the excluded directory reads as absent - 0 rows, no error"];

check[-11h=type cnt "count select from trade where sym=`",garbage;
  "a corrupt column ERRORS when its directory is opened"];

/ ---------------------------------------------------------------------------
-1 "";
nhealthy:cnt "count select from trade where sym=`",healthy;
check[$[-7h=type nhealthy; nhealthy>0; 0b];
  "a selective query on a healthy instrument is unaffected (",string[nhealthy]," rows)"];
check[(-7h=type cnt "count select from trade where date=2026.01.01, sym=`",healthy);
  "  - and stays unaffected with the date constrained too"];

check[-11h=type cnt "count select n:count i by sym from trade";
  "a whole-table query fails, because it must open the corrupt directory"];
check[-11h=type cnt "count select from trade where price>0";
  "  - even one that never names the corrupt column"];

-1 "";
-1 "  Partition elimination is what limits the damage: the queries this layout exists to";
-1 "  make fast are the ones that keep working. What needs watching is the truncated";
-1 "  column - it is the only one of the three that answers, and answers wrongly.";
-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
system"rm -rf ",s;
exit $[fail>0;1;0]
