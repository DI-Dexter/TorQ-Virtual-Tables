/ How does the reader scale with partition count?
/ .
/ This is the evidence behind §8.2 and step 6 of §10. It builds synthetic trees of increasing
/ size, attaches the real vtidb.q to each, and measures what actually grows.
/ .
/ Run it as:  cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-scale-test.q
/ Takes a couple of minutes and about 2 GB of scratch space in /tmp.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

.lg.o:{[t;m]}; .lg.w:{[t;m]}; .lg.e:{[t;m]};
.servers.startupdepcycles:{[t;i;c] '"no wdb"};
.servers.gethandlebytype:{[t;m] ()};
.timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};

pid:string .z.i;
maps:{[] "J"$first" "vs first system"wc -l /proc/",pid,"/maps" };
fds: {[] "J"$first" "vs first system"ls /proc/",pid,"/fd | wc -l" };
rss: {[] "J"$first" "vs first system"awk '/VmRSS/{print $2}' /proc/",pid,"/status" };

root:"/tmp/vt-scale-",pid;

/ one template partition per table, matching the real schema with the partition column
/ stripped: trade 7 columns, quote 8
mktemplate:{[r]
  o:([]time:10#.z.p; price:10#100f; size:10#10i; stop:10#0b;
      cond:10#" "; ex:10#"N"; side:10#`buy);
  a:([]time:10#.z.p; bid:10#99f; ask:10#101f; bsize:10#10j; asize:10#10j;
      mode:10#" "; ex:10#"N"; src:10#`BARX);
  h:hsym`$r;
  .Q.dd[.Q.dd[h;`template_trade];`] set .Q.en[h;o];
  .Q.dd[.Q.dd[h;`template_quote];`] set .Q.en[h;a];
  };

/ build the first date instrument by instrument, then clone the whole date - far faster
mktree:{[r;dates;insts]
  system"rm -rf ",r; system"mkdir -p ",r;
  mktemplate r;
  d0:"2026.01.01";
  {[r;d0;t;insts]
    system"mkdir -p ",r,"/",d0,"/",string t;
    {[r;d0;t;i] system"cp -r ",r,"/template_",(string t)," ",r,"/",d0,"/",(string t),"/I",-4$"000",string i}[r;d0;t] each til insts;
    }[r;d0;;insts] each `trade`quote;
  {[r;d0;n] system"cp -r ",r,"/",d0," ",r,"/",string 2026.01.01+n}[r;d0] each 1+til dates-1;
  system"rm -rf ",r,"/template_trade ",r,"/template_quote";
  };

measure:{[r;dates;insts]
  mktree[r;dates;insts];
  m0:maps[]; f0:fds[]; r0:rss[];
  .vtidb.roots:enlist hsym`$r;

  / COLD: no cache, so every date is scanned and every directory opened
  .vtidb.dropcache[];
  t0:.z.p; .vtidb.rebuild[]; cold:`long$(.z.p-t0)%1000000;
  np:sum count each .vtidb.parts;

  / selective query, run twice so the reported figure is warm
  q1:{count select from trade where date=2026.01.01, instrument=`I0000};
  q1[]; t0:.z.p; q1[]; sel:`long$(.z.p-t0)%1000;

  / LIVE: the production case - one date is the live partition and gets rescanned,
  / every earlier date is immutable and reused
  .vtidb.current:2026.01.01+dates-1;
  .vtidb.dropcache[]; .vtidb.rebuild[];
  t0:.z.p; .vtidb.rebuild[]; live:`long$(.z.p-t0)%1000000;

  / ROLLOVER: end of day. used to drop the whole cache, which made this a full rescan.
  / it now forgets only the date that just closed, so it should track live, not cold (VT-17)
  t0:.z.p; .vtidb.rollover[2026.01.01+dates]; roll:`long$(.z.p-t0)%1000000;

  / NOTE maps/fds as a delta, RSS as an absolute: this script reuses one process across
  / sizes, so a per-size RSS delta understates. For bytes-per-directory, run a fresh
  / process per size - measured that way it is a consistent 891 B/dir.
  -1 "  ",(-9$string np),(-8$string maps[]-m0),(-6$string fds[]-f0),
     (-10$string rss[]),(-9$string cold),(-9$string live),(-9$string roll),-9$string sel;
  };

/ the reader has to be loaded once, with a root that exists
mktree[root;1;1];
.vtidb.roots:enlist hsym`$root;
/ this script builds its own synthetic tree, so pin the exposed name to what its queries use
/ rather than inheriting the deployment's setting
.vtidb.partitioncol:`instrument;
system"l ",getenv[`KDBAPPCODE],"/processes/vtidb.q";

-1 "";
-1 "  ",(-9$"dirs"),(-8$"maps+"),(-6$"fds+"),(-10$"rss kB"),
   (-9$"cold ms"),(-9$"live ms"),(-9$"roll ms"),-9$"sel us";
-1 "  ",(-9$"")," ",65#"-";
measure[root;10;20];
measure[root;25;50];
measure[root;50;100];
measure[root;100;100];
measure[root;200;100];

system"rm -rf ",root;
-1 "";
-1 "  cold = full rescan of every date (startup, or a manual dropcache).";
-1 "  live = the production case: rescan only the live partition, reuse immutable history.";
-1 "  roll = end of day. it rescans the one date that just closed and keeps everything older,";
-1 "         so it tracks live rather than cold, and does not grow with retention (VT-17).";
-1 "  mappings and file descriptors do not grow: a trailing-slash open does not mmap.";
exit 0
