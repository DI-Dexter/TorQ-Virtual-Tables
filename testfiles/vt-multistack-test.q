/ Can one reader serve two capture stacks? (§8.3, VT-16)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./vt-env.sh && q testfiles/vt-multistack-test.q
/ .
/ .vtidb.roots is a list, so the scan and the virtual table already handle several trees. The
/ blocker was the enumeration domain: symbol columns are indices into a file at the root, the
/ reader loads it with `load`, and `load` binds a global named after the FILE. Two stacks that
/ both call theirs `sym` collide - one wins and the other's symbols resolve to the wrong values,
/ silently.
/ .
/ Three configurations, all of which a deployment could arrive at:
/   separate  domains named `sym` and `symb`      -> independent stacks, one reader
/   colliding both named `sym`, different content -> must be caught, not served
/   shared    both named `sym`, same content      -> stacks coordinated on one domain
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

/ enough of the TorQ framework for vtidb.q to load standalone
.lg.o:{[t;m]}; .lg.w:{[t;m]}; .lg.e:{[t;m] errs,:enlist m};
.servers.startupdepcycles:{[t;i;c] '"no wdb in this test"};
.servers.gethandlebytype:{[t;m] ()};
.timer.enabled:0b; .timer.repeat:{[a;b;c;d;e]}; .proc.cp:{[] .z.P};
errs:();

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

live:getenv`KDBDB;
scratch:"/tmp/vt-multistack-",string .z.i;
d:2026.01.01;
tab:`trade;
col:`side;                                / a symbol column held INSIDE the files

src:first asc key[hsym`$live] where key[hsym`$live] like "[0-9][0-9][0-9][0-9].*";
if[null src; -1 "no partitions under ",live," - start the stack first"; exit 77];
load hsym`$live,"/sym";

/ read the live tree once and strip the enumeration: .Q.ens will not take a mapped table,
/ and each root has to be re-enumerated against its own domain anyway
deenum:{[t] flip {$[20h<=abs type x; value x; x]} each flip select from t};
p:.Q.dd[.Q.dd[hsym`$live;src];tab];
ls:{[deenum;p;i] (i; deenum get .Q.dd[.Q.dd[p;i];`])}[deenum;p] each key p;
if[3>count ls; -1 "need at least 3 instruments in ",string tab; exit 77];
half:`long$0.5*count ls;

/ split in two, because the shared-domain case has to put a symlink in place between the
/ mkdir and the first write - mkroot's rm -rf would otherwise delete it
mkdirs:{[scratch;nm]
  system"rm -rf ",scratch,"/",string nm; system"mkdir -p ",scratch,"/",string nm;
  hsym`$scratch,"/",string nm
  };
writeleaves:{[r;d;tab;dom;ls]
  {[r;d;tab;dom;l] .Q.dd[.Q.dd[.Q.dd[.Q.dd[r;`$string d];tab];l 0];`] set .Q.ens[r;l 1;dom]
    }[r;d;tab;dom] each ls;
  r
  };
mkroot:{[mkdirs;writeleaves;scratch;d;tab;nm;dom;ls]
  writeleaves[mkdirs[scratch;nm];d;tab;dom;ls]
  }[mkdirs;writeleaves];

/ roots are config, not runtime state, so a change of roots is a restart in production.
/ here it means reloading the domains by hand - symchanged only watches file SIZE
useroots:{[rs] errs::(); .vtidb.roots:rs; .vtidb.loadsym[]; .vtidb.dropcache[]; .vtidb.rebuild[]; };
q:{[s] value s};

system"rm -rf ",scratch; system"mkdir -p ",scratch;
a:mkroot[scratch;d;tab;`a;`sym ; half#ls];
b:mkroot[scratch;d;tab;`b;`symb; (half _ ls)];

.vtidb.roots:enlist a;
system"l ",getenv[`KDBAPPCODE],"/processes/vtidb.q";
pc:.vtidb.partitioncol;
.vtidb.current:d+1;

-1 "";
-1 "  scratch  ",scratch;
-1 "  root a   ",(.Q.s1 key a)," (",string[half]," instruments)";
-1 "  root b   ",(.Q.s1 key b)," (",string[count[ls]-half]," instruments)";
-1 "";

/ ---------------------------------------------------------------------------
-1 "  SEPARATE DOMAINS - two independent stacks, one reader";
useroots (a;b);
-1 "    domains found      ",.Q.s1 {last ` vs x} each .vtidb.symfiles[];
-1 "    partitions         ",.Q.s1 count each .vtidb.parts;

check[(`sym`symb)~asc {last ` vs x} each .vtidb.symfiles[];
  "both domains are discovered - the reader no longer assumes every root calls it `sym"];
check[0=count errs; "no collision reported: the names differ, so nothing is overwritten"];
check[count[ls]=count .vtidb.parts tab;
  "every partition from both roots is attached (",string[count ls],")"];

r:q"select n:count i by ",string[pc]," from ",string[tab]," where date=",string d;
check[count[ls]=count r; "grouping by the PARTITION column is correct across both roots"];
check[11h=abs type key[r]pc; "  - because it comes from directory names, not from a domain"];

/ the expectation has to come from the leaves actually ATTACHED, not from all of ls: a value
/ that only occurs in the half that went to root b is not reachable from (a;c)
distinctin:{[col;ls] asc distinct raze {[col;l] distinct l[1] col}[col] each ls}[col];
want:distinctin ls;
f:first want;
n1:first exec n from q"select n:count i from ",string[tab]," where date=",string[d],
   ", ",string[col],"=`",string f;
n2:sum raze {[col;f;l] sum l[1][col]=f}[col;f] each ls;
check[n1=n2; "filtering on a cross-domain symbol column is correct (",string[n1]," rows)"];

byv:q"select n:count i by v:value ",string[col]," from ",string[tab]," where date=",string d;
check[want~asc exec v from byv; "grouping via `value` on that column is correct"];

/ the one thing that does NOT unify, asserted so a regression is visible
raw:q"select n:count i by ",string[col]," from ",string[tab]," where date=",string d;
check[count[raw]>count want;
  "KNOWN LIMIT: grouping on the raw column splits per domain (",
  string[count raw]," groups, not ",string[count want],")"];

/ ---------------------------------------------------------------------------
-1 "";
-1 "  COLLIDING DOMAINS - both roots call it `sym, with different contents";
/ the second stack has to hold a symbol the first has never seen, which is what makes the
/ two domains diverge. that is the whole point: independently grown domains assign different
/ indices to the same symbols. give it one of its own
divergent:{[col;ls] @[ls;0;{[col;l] @[l;1;{[col;t] update side:`zzzonlyhere from t}[col]]}[col]]}[col; half _ ls];
c:mkroot[scratch;d;tab;`c;`sym; divergent];
useroots (a;c);
check[any errs like "*WRONG*"; "the unsafe configuration is reported, loudly"];

/ ---------------------------------------------------------------------------
/ the other supported configuration: ONE physical domain, symlinked into each root. this is
/ what "sharing a sym file" has to mean - two copies are the colliding case above, because
/ they diverge the moment either stack sees a symbol the other has not.
/ .
/ NOTE the link has to exist BEFORE the second stack writes. symlinking a domain over a tree
/ whose columns were already enumerated against a different one does not share anything - it
/ reinterprets existing indices against the wrong list, which is the collision case again.
/ so root e is built fresh, with the link in place first.
-1 "";
-1 "  SHARED DOMAIN - one file, symlinked into both roots";
e:mkdirs[scratch;`e];
system"ln -s ",(1_string .Q.dd[a;`sym])," ",1_string .Q.dd[e;`sym];
writeleaves[e;d;tab;`sym; (half _ ls)];

check[0<count system"find ",(1_string .Q.dd[e;`sym])," -maxdepth 0 -type l";
  "the second root's domain is a link to the first root's file"];
check[1=count distinct system"stat -Lc %i ",(1_string .Q.dd[a;`sym])," ",1_string .Q.dd[e;`sym];
  "both roots resolve to one inode, so they cannot drift apart"];

/ a later write through the link must extend that one file, not replace it with a copy
before:hcount .Q.dd[a;`sym];
.Q.dd[.Q.dd[.Q.dd[e;`2026.01.02];tab];`] set .Q.ens[e;([]time:enlist .z.p; side:enlist `zzznew);`sym];
check[0<count system"find ",(1_string .Q.dd[e;`sym])," -maxdepth 0 -type l";
  "writing through the link leaves it a link - .Q.en appends, it does not replace"];
check[before<hcount .Q.dd[a;`sym];
  "and the write landed in the shared file, visible from the other root"];

useroots (a;e);
check[0=count errs; "one domain under one name is safe, and is not reported"];
/ roots a and e together hold exactly the source data, so the expectation is the source's own
/ distinct set - one group per value, not one per domain
wantshared:want;
raw2:q"select n:count i by ",string[col]," from ",string[tab]," where date=",string d;
check[count[wantshared]=count raw2;
  "symbol columns unify: grouping on the raw column is correct (",string[count raw2]," groups)"];

/ ---------------------------------------------------------------------------
/ what a second root costs. same total partitions, one tree versus two, so the only
/ difference measured is the extra root itself
-1 "";
-1 "  COST OF A SECOND ROOT - same data, one tree versus two";
one:mkroot[scratch;d;tab;`one;`sym; ls];
inst:first ls 0;
sel:{[pc;d;tab;inst;n] min {[qry;i] t:.z.p; value qry; `long$(.z.p-t)%1000}
  ["select from ",string[tab]," where date=",string[d],", ",string[pc],"=`",string inst] each til n
  }[pc;d;tab;inst];
bench:{[useroots;sel;rs]
  useroots rs;
  t0:.z.p; .vtidb.rebuild[]; rb:`long$(.z.p-t0)%1000;
  (count[rs]; sum count each .vtidb.parts; rb; sel 200)
  }[useroots;sel];

r1:bench enlist one;
r2:bench (a;b);
-1 "";
-1 "    roots  partitions  rebuild us  select us";
{[r] -1 "    ",(-7$string r 0),(-12$string r 1),(-12$string r 2),-11$string r 3}each (r1;r2);
check[r2[1]=r1 1; "both configurations attach the same number of partitions"];
check[r2[3]<2*r1 3; "a selective query is not materially slower with two roots"];

-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
system"rm -rf ",scratch;
exit $[fail>0;1;0]
