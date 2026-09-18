/ Two writers over one root: the scoped pre-replay delete, and the live-partition guard (§8.3.2)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-multiwriter-test.q
/ .
/ Both behaviours exist because a second writer breaks an assumption the stock code is entitled
/ to make with one:
/ .
/   clearwdbdata deletes the WHOLE date directory before replaying its log. With two writers
/   that deletes the other stack's day - measured at 579 rows, silently.
/ .
/   livepart takes the newest date on disk. The first stack to create tomorrow makes today
/   immutable, and every directory the other writer adds to today afterwards is never seen.
/ .
/ Both are off unless .wdb.multiwriter / .vtidb.multiwriter are set, so the first check in each
/ half is that a single-writer stack is untouched.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

scratch:"/tmp/vt-multiwriter-",string .z.i;
root:scratch,"/db";
pt:2026.01.01;
mk:{[p] system"mkdir -p ",p};
mk each root,/:("/2026.01.01/trade/",/:("AAPL";"MSFT";"BARC";"VOD")),
                ("/2026.01.01/quote/",/:("AAPL";"MSFT";"BARC";"VOD"));

/ ---------------------------------------------------------------------------
/ the writer half - enough framework for vtwritemulti.q to load standalone
/ ---------------------------------------------------------------------------
.lg.o:{[t;m]}; .lg.w:{[t;m] warns,:enlist m}; .lg.e:{[t;m] '"unexpected .lg.e: ",m};
warns:();
.os.deldir:{[p] deleted,:enlist p; system"rm -rf ",p;};
.os.md:{[p] system"mkdir -p ",p;};
deleted:();
.proc.procname:`wdb1;
.wdb.savedir:hsym`$root;
.wdb.getpartition:{[] 2026.01.01};
.wdb.vtdirname:{[x] first x};
.wdb.vtupserttopartition:{[dir;t;d;p;et;e;w] `stock};
.wdb.vtsavetodisk:{[] `stock};

stockdeldir:.os.deldir;
.wdb.multiwriter:0b;
system"l ",getenv[`KDBAPPCODE],"/wdb/vtwritemulti.q";
check[.os.deldir~stockdeldir; "multiwriter off: .os.deldir is not wrapped"];
check[.wdb.vtupserttopartition[`;`trade;();pt;`sym;enlist `AAPL;`]~`stock;
      "multiwriter off: the upsert is the stock one"];

/ now the same file with the flag on
.wdb.multiwriter:1b;
system"l ",getenv[`KDBAPPCODE],"/wdb/vtwritemulti.q";
check[not .os.deldir~stockdeldir; "multiwriter on: .os.deldir is wrapped"];

/ this writer owns AAPL and MSFT; another writer owns BARC and VOD
.wdb.vtupserttopartition[`;`trade;();pt;`sym;enlist `AAPL;`];
.wdb.vtupserttopartition[`;`trade;();pt;`sym;enlist `MSFT;`];
.wdb.vtsavetodisk[];
check[(asc .wdb.vtowned pt)~`AAPL`MSFT; "the manifest records the directories this writer wrote"];
check[not ()~key hsym`$root,"/.vtowner/wdb1_2026.01.01"; "the manifest is written to disk"];
(hsym`$root,"/.vtowner/wdb2_2026.01.01") set `BARC`VOD;

/ the delete clearwdbdata issues, against the partition root
deleted:();
.os.deldir root,"/2026.01.01";
check[(asc key hsym`$root,"/2026.01.01/trade")~`BARC`VOD;
      "scoped delete: this writer's instruments are gone, the other writer's remain"];
check[(asc key hsym`$root,"/2026.01.01/quote")~`BARC`VOD;
      "scoped delete: it covers every table in the partition, not just the first"];
check[not ()~key hsym`$root,"/2026.01.01"; "the partition directory itself survives"];

/ a delete of anything else must pass straight through
deleted:();
mk root,"/2026.01.01/trade/ZZZZ";
.os.deldir root,"/2026.01.01/trade/ZZZZ";
check[()~key hsym`$root,"/2026.01.01/trade/ZZZZ"; "a non-partition delete passes through to stock"];

/ no manifest for the partition, but another writer owns directories here
hdel hsym`$root,"/.vtowner/wdb1_2026.01.01";
.wdb.vtowned:(`date$())!();
warns:();
.os.deldir root,"/2026.01.01";
check[not ()~key hsym`$root,"/2026.01.01/trade/BARC"; "no manifest + another writer: deletes NOTHING"];
check[any warns like "REFUSING*"; "no manifest + another writer: the refusal is logged"];

/ ...and with no other writer at the root, the stock full delete is correct
hdel hsym`$root,"/.vtowner/wdb2_2026.01.01";
.os.deldir root,"/2026.01.01";
check[()~key hsym`$root,"/2026.01.01"; "no manifest + no other writers: stock full delete"];

/ ---------------------------------------------------------------------------
/ the reader half - the live-partition guard
/ ---------------------------------------------------------------------------
mk each (root,"/2026.01.01/trade/AAPL"; root,"/2026.01.02/trade/AAPL");
answers:2026.01.01 2026.01.02;             / what each "writer" reports
port:1+rand 20000+10000;
/ a stand-in writer that answers .wdb.getpartition. NOTE the script comes BEFORE the flags
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
.vtidb.current:0Nd;
.vtidb.multiwriter:0b;
check[2026.01.02=.vtidb.livepart ds; "multiwriter off: livepart is the newest date on disk"];

.vtidb.multiwriter:1b;
.vtidb.writertimeout:500;
.vtidb.wconn:(`$())!();
check[2026.01.01=.vtidb.livepart ds;
      "multiwriter on: held at the date a writer is still filling, not the newest on disk"];
check[1=count .vtidb.livepartitions[];
      "a writer that cannot be reached does not constrain the live partition"];

/ rollover announced while that writer is still on the earlier date
.vtidb.current:2026.01.01;
rebuilt:0;
origrebuild:.vtidb.rebuild; .vtidb.rebuild:{[] rebuilt+::1; 0};
.vtidb.rollover 2026.01.02;
check[2026.01.01=.vtidb.current; "rollover: current is NOT advanced while a writer is behind"];
check[rebuilt>0; "rollover: it rescans instead of closing the date"];

/ once every writer has rolled, it advances
(hsym`$scratch,"/w.q") 0: enlist ".wdb.getpartition:{[] 2026.01.02};";
.vtidb.wconn:(`$())!();
/ pkill exits non-zero when nothing matched, and system throws on that
stop:{[p] h:@[hopen;(`$":localhost:",string p;300);0Ni]; if[not null h; @[h;"exit 0";()]]; };
stop port; system"sleep 0.3";
system srv; system"sleep 1";
.vtidb.loadsym:{[]};
.vtidb.rollover 2026.01.02;
check[2026.01.02=.vtidb.current; "rollover: it advances once every writer has rolled"];

stop port;
-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
system"rm -rf ",scratch;
exit $[fail>0;1;0]
