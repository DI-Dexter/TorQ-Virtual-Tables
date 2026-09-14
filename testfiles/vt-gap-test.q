/ What happens when a partition is missing one table?
/ .
/ This is the evidence behind §4.6 and step 5 of §10. It breaks the writer's
/ fill-then-notify ordering by hand - removing a table directory from one date - and shows
/ what a reader actually does with the result.
/ .
/ Run it with the stack having captured at least one date:
/   cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-gap-test.q
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

/ enough of the TorQ framework for vtidb.q to load standalone
.lg.o:{[t;m]}; .lg.w:{[t;m]}; .lg.e:{[t;m]};
.servers.startupdepcycles:{[t;i;c] '"no wdb in this test"};
.servers.gethandlebytype:{[t;m] ()};
.timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};

live:getenv`KDBDB;
scratch:"/tmp/vt-gap-test-",string .z.i;      / .z.i is this process id
reader:getenv[`KDBAPPCODE],"/processes/vtidb.q";

/ two identical dates, so a gap can be put in either the first or the last
src:first asc key[hsym`$live] where key[hsym`$live] like "[0-9][0-9][0-9][0-9].*";
if[null src; -1 "no partitions under ",live," - start the stack first"; exit 77];
system"rm -rf ",scratch;
system"mkdir -p ",scratch;
system"cp ",live,"/sym ",scratch,"/";
system"cp -r ",live,"/",(string src)," ",scratch,"/2026.01.01";
system"cp -r ",live,"/",(string src)," ",scratch,"/2026.01.02";
-1 "scratch database : ",scratch;

/ the gap: remove the populated table from the SECOND date, exactly what a notify-before-fill
/ writer would leave behind
system"rm -rf ",scratch,"/2026.01.02/trade";
-1 "removed          : 2026.01.02/trade";
-1 "";

.vtidb.roots:enlist hsym`$scratch;
r:@[{system"l ",x; `ok};reader;{`$"FAILED: ",x}];

-1 "RESULT";
-1 (56#"-");
-1 "  reader load              : ",$[r~`ok;"LOADED - no error";string r];
if[not r~`ok; exit 1];
-1 "  tables attached          : ",.Q.s1 key .vtidb.parts;
-1 "  dates for trade          : ",.Q.s1 asc distinct exec date from .vtidb.parts`trade;
-1 "  count select from trade : ",.Q.s1 value"count select from trade";
-1 "";
-1 "  the table answers queries. the answer is missing a whole date, with no warning.";
-1 "";

/ and the recovery: a restored directory needs a rebuild, which is what the sweep provides
system"cp -r ",live,"/",(string src),"/trade ",scratch,"/2026.01.02/trade";
-1 "  directory restored on disk, before rebuild : ",.Q.s1 value"count select from trade";
.vtidb.rebuild[];
-1 "  after one rebuild (what the sweep does)    : ",.Q.s1 value"count select from trade";
-1 "";
-1 "  so the damage is bounded by the sweep interval, not permanent.";

system"rm -rf ",scratch;
exit 0
