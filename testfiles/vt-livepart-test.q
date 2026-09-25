/ The live-partition guard: one reader, several writers, separate roots (§8.3)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-livepart-test.q
/ .
/ The reader caches every date before `current` as immutable and never rescans it, which is
/ what keeps the catalogue cheap as history grows. With ONE writer that is safe, because that
/ writer is the only process that can still add a directory to the live date.
/ .
/ With several writers it is not, and SEPARATE ROOTS DO NOT FIX IT: a reader attaches every
/ root and holds ONE live partition across the lot, so the first stack to create tomorrow
/ makes today immutable for every stack - and every directory the slower writer adds to today
/ afterwards is never seen. Not lost on disk; invisible to queries, with nothing logged.
/ .
/ The guard asks every writer which partition it is filling and holds at the earliest answer.
/ It has to sit on BOTH paths that assign current - the rollover announcement and the periodic
/ rebuild, which recomputes from disk - or the sweep quietly undoes what rollover refused.
/ .
/ .vtidb.multiwriter is off unless set, so the first check is that a single-writer stack is
/ untouched. setenv.sh sets it from the process file whenever VTSTACKS>1.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

scratch:"/tmp/vt-livepart-",string .z.i;
root:scratch,"/db1";
mk:{[p] system"mkdir -p ",p};
mk each (root,"/2026.01.01/trade/AAPL"; root,"/2026.01.02/trade/AAPL");

.lg.o:{[t;m]}; .lg.w:{[t;m]}; .lg.e:{[t;m] '"unexpected .lg.e: ",m};

/ a stand-in writer that answers .wdb.getpartition, plus a second one that never answers
port:1+rand 20000+10000;
srv:{[scratch;port] "q ",scratch,"/w.q -p ",string[port]," -q &"}[scratch;port];
(hsym`$scratch,"/w.q") 0: enlist ".wdb.getpartition:{[] 2026.01.01};";
system srv;
system"sleep 1";

.timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};
.servers.startupdepcycles:{[t;i;c] '"no wdb"}; .servers.gethandlebytype:{[t;m] ()};
.servers.SERVERS:([] procname:`wdb1`wdb2; proctype:`wdb`wdb;
                     hpup:(`$":localhost:",string port; `$":localhost:1"));
.vtidb.roots:enlist hsym`$root;
.vtidb.partitioncol:`sym;
system"l ",getenv[`KDBAPPCODE],"/processes/vtidb.q";

ds:`$string 2026.01.01 2026.01.02;

/ ---- one writer: the stock rule, newest date on disk ----
.vtidb.current:0Nd;
.vtidb.multiwriter:0b;
check[2026.01.02=.vtidb.livepart ds; "multiwriter off: livepart is the newest date on disk"];

/ ---- several writers: held at the earliest partition any of them still has open ----
.vtidb.multiwriter:1b;
.vtidb.writertimeout:500;
.vtidb.wconn:(`$())!();
check[2026.01.01=.vtidb.livepart ds;
      "multiwriter on: held at the date a writer is still filling, not the newest on disk"];
check[1=count .vtidb.livepartitions[];
      "a writer that cannot be reached does not constrain the live partition"];

/ ---- the rollover path ----
.vtidb.current:2026.01.01;
rebuilt:0;
origrebuild:.vtidb.rebuild; .vtidb.rebuild:{[] rebuilt+::1; 0};
.vtidb.rollover 2026.01.02;
check[2026.01.01=.vtidb.current; "rollover: current is NOT advanced while a writer is behind"];
check[rebuilt>0; "rollover: it rescans instead of closing the date"];

/ ---- the REBUILD path, which is the one that is easy to miss ----
/ rollover refused above. If the guard were only on that path, the next sweep would recompute
/ current from disk, find 2026.01.02 there, and advance anyway - undoing the refusal within
/ one sweep interval and turning a hard failure into an intermittent one.
.vtidb.current:2026.01.01;
.vtidb.wconn:(`$())!();
check[2026.01.01=.vtidb.livepart ds;
      "rebuild: the sweep does NOT drag current past a writer that is still behind"];

/ ---- once every writer has rolled, it advances ----
(hsym`$scratch,"/w.q") 0: enlist ".wdb.getpartition:{[] 2026.01.02};";
.vtidb.wconn:(`$())!();
stop:{[p] h:@[hopen;(`$":localhost:",string p;300);0Ni]; if[not null h; @[h;"exit 0";()]]; };
stop port; system"sleep 0.3";
system srv; system"sleep 1";
.vtidb.loadsym:{[]};
.vtidb.rollover 2026.01.02;
check[2026.01.02=.vtidb.current; "rollover: it advances once every writer has rolled"];
.vtidb.wconn:(`$())!();
check[2026.01.02=.vtidb.livepart ds; "rebuild: and the sweep agrees once they have"];

stop port;
-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
system"rm -rf ",scratch;
exit $[fail>0;1;0]
