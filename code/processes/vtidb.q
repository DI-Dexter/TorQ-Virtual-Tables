/ Virtual-table capture pack : IDB reader. Section 5 of docs/virtual-table-capture-pack.md.
/ .
/ Reads the capture database in place - no load, no copy, no RDB. Each table is a kx.pq.t
/ virtual table whose partitions are the date/instrument directories the WDB writes, opened as
/ live views, so history and the current day are the same objects and one process answers both.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

/ bind mkP at the root and fully qualified: inside a \d block an undotted name is
/ resolved against that namespace, so this avoids depending on how it resolves
.vtidb.mkp:(use`kx.pq.t)`mkP;

\d .vtidb

/ ---------------------------------------------------------------------------
/ config - defaults here, overridden by appconfig/settings/idb.q
/ ---------------------------------------------------------------------------
roots:@[value;`roots;enlist hsym`$getenv`KDBDB];
tabs:@[value;`tabs;`];
historydays:@[value;`historydays;0W];
sweep:@[value;`sweep;0D00:00:30];
symsweep:@[value;`symsweep;0D00:00:01];
/ the name the partition column is exposed under. Not stored on disk, so it cannot be derived
/ (§2.2): set it to whatever the source schema calls the parted column, so client queries read
/ the same as against a conventional database.
partitioncol:@[value;`partitioncol;`instrument];
wdbtypes:@[value;`wdbtypes;`wdb];
wdbcheckcycles:@[value;`wdbcheckcycles;3];
wdbconnsleepintv:@[value;`wdbconnsleepintv;5];
/ 8.3.2 - ask EVERY writer which partition it is filling, rather than trusting the newest date
/ on disk. Only needed when more than one writer shares a root: with a single writer the two
/ answers agree, and the check costs a round trip per rebuild. Default off.
multiwriter:@[value;`multiwriter;0b];
/ how long to wait for a writer to answer, in ms. One that does not answer in time simply does
/ not constrain the live partition - see livepartitions.
writertimeout:@[value;`writertimeout;1000];

/ ---------------------------------------------------------------------------
/ state
/ ---------------------------------------------------------------------------
current:0Nd;                             / the partition the writer is currently filling
symsize:0;                               / total size of the sym files at the last load
parts:(`$())!();                         / table -> catalogue of (date;<partitioncol>;path)
opened:(`$())!();                        / table -> opened live views, one per parts row.
                                         / NOTE not called "views" - that is a q keyword
lastgap:(`$())!();                       / table -> dates missing at the last check (4.6)
wconn:(`$())!();                         / hpup -> handle, opened with a timeout (8.3.2)

/ The enumeration domain must cover a directory's values before it is opened, or its symbol
/ columns resolve wrongly. Any file at a root - as opposed to a date directory - is a domain,
/ so they are discovered rather than assumed to be `sym; that is what lets stacks keep
/ separate domains (8.3.1).
symfiles:{[]
  raze {[r]
    k:key r;
    k:k where not k like "*.*";           / drops date directories and par.txt alike:
                                          / a domain file is named like an identifier
    f:.Q.dd[r;] each k;
    f where {x~key x} each f              / a directory keys to its contents, a file to itself
    } each roots
  };

/ `load` binds a global named after the FILE, so two roots keep independent domains as long as
/ the names differ. What is unsafe is two roots using the same NAME for different content: one
/ load wins and the other's symbols resolve wrongly, silently (§8.3.1).
loadsym:{[]
  f:symfiles[];
  {@[load;x;{[p;e] .lg.e[`vtidb;"failed to load ",string[p],": ",e]}[x]]} each f;
  / group returns INDICES into f, not the paths themselves
  g:group {last ` vs x} each f;
  {[f;g;n]
    if[1<count distinct @[get;;()] each f g n;
      .lg.e[`vtidb;"two roots both use the enumeration domain `",string[n],"` with different ",
                   "contents - all but one will resolve symbols to the WRONG values. give each ",
                   "stack its own domain name, or share one file. see 8.3.1"]];
    }[f;g] each where 1<count each g;
  };
/ sum of an EMPTY list is () , not 0 - and symsize<>() is () , which fails the $[] in
/ symchanged with a type error. Seeding with 0 keeps this numeric on a database that has
/ no sym file yet, which is what a fresh install always looks like.
symbytes:{[] sum 0,@[hcount;;0] each symfiles[] };
symchanged:{[] $[symsize<>c:symbytes[];[symsize::c;1b];0b] };

/ 5.4 - the domain can grow with no directory appearing, so the writer sends no notification
/ and the new value reads as null until the domain is reloaded. Hence its own timer rather than
/ the rebuild sweep: one hcount per root is cheap enough to run every second.
refreshsym:{[]
  if[symchanged[];
    loadsym[];
    .lg.o[`vtidb;"enumeration domain grew - reloaded"]];
  };

/ ---------------------------------------------------------------------------
/ scanning the tree
/ ---------------------------------------------------------------------------

/ date directories under one root, honouring historydays
datedirs:{[r]
  d:key r;
  if[not count d; :0#`];
  d:d where d like "[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]";
  $[historydays=0W; asc d; asc d where ("D"$string d) >= .z.D - historydays]
  };

/ table names under the given date directories, across every root
scantabs:{[ds]
  distinct raze {[ds;r] raze {[r;d] k:key .Q.dd[r;d]; $[()~k; 0#`; k]}[r] each ds}[ds] each roots
  };

/ Which tables to build, discovered from the tree so a table added to database.q needs no
/ change here. Scanning every date costs a readdir per date and grows with retention, so once
/ anything is known only the live partition is looked at - a new table can only appear where
/ the writer is writing. The cold path still scans everything, because a table that has stopped
/ receiving data exists only in history.
tablelist:{[ds]
  if[not tabs~`; :(),tabs];
  known:key parts;
  if[not count known; :scantabs ds];
  distinct known,scantabs $[null current; ds; enlist `$string current]
  };

empty:flip (`date,partitioncol,`path)!(0#0Nd;0#`;0#`);

/ the (date;<partitioncol>;path) rows for one table on one date under one root.
/ WARNING the trailing ` on the path is what makes the view live - see §5.2. without it
/ each partition is a frozen snapshot and the reader never sees another row
scandate:{[t;r;d]
  p:.Q.dd[.Q.dd[r;d];t];
  if[()~i:key p; :empty];
  flip (`date,partitioncol,`path)!(count[i]#"D"$string d; i; {.Q.dd[.Q.dd[x;y];`]}[p] each i)
  };

/ one table on one date, across every root
scanone:{[t;d] raze scandate[t;;d] each roots };

/ every partition directory NAME currently on disk, across every root. these are symbols
/ (e.g. `2026.08.17), not dates - scandate needs the symbol to build the path
alldates:{[] d:raze datedirs each roots; $[count d; asc distinct d; 0#`] };

/ open one partition, tolerating a directory that is mid-creation. This does not catch a
/ directory whose .d names columns absent from disk: get is lazy, so it attaches and then
/ breaks every query touching that column. Unguarded by decision - see 5.7.
open:{[p] @[get;p;{[p;e] .lg.w[`vtidb;"cannot open ",string[p],": ",e]; ::}[p]]};

/ can this date still gain a directory? Only the live partition can, so a rolled date's
/ catalogue is reused rather than rescanned. A null current forces a full scan.
/ NOTE vectorised deliberately: "mutable each" on an empty list yields an untyped () which
/ breaks the boolean `and` in build.
mutable:{[d] $[null current; count[d]#1b; d>=current] };

/ Which partition is the writer filling? An immutable date is never rescanned, so believing the
/ live date has rolled freezes it, and every instrument starting afterwards is on disk and
/ absent from every query.
/ .
/ .z.D is wrong under a non-zero .eodtime.rolltimeoffset, where the writer fills yesterday for
/ offset hours after .z.D advances. The newest date on disk is a lower bound the writer cannot
/ contradict, so take the writer's answer but never sit behind the disk. max ignores nulls,
/ which is what makes this work before a writer is found.
/ .
/ 8.3 - the handles below are our own, opened with a timeout, rather than the shared .servers
/ ones, which carry none: a writer that is alive but not answering would otherwise block every
/ rebuild. One that times out does not constrain the live partition, which is the safe
/ direction - a lower answer rescans more dates, never fewer.
/ .
/ NOTE .vtidb.wdbtypes is qualified deliberately: inside a select or exec an unqualified name
/ resolves in the root namespace, not the one the function was defined in.
writerhpups:{[]
  @[{[] exec hpup from .servers.SERVERS where proctype in .vtidb.wdbtypes, not null hpup};
    (::);{[e] .lg.w[`vtidb;"could not read .servers.SERVERS: ",e]; 0#`}]
  };

/ credentials, the way .servers does it: a bare :host:port gets USERPASS (or a per-server
/ override) appended. Without this every query is refused, and the trap reads that as
/ "no writers" - a healthy single-writer stack.
writerconn:{[hp]
  u:@[{.servers.USERPASS^.servers.PASSWORDS x};hp;`];
  $[(null u) or 2<sum ":"=string hp; hp; hsym `$(string hp),":",string u]
  };

writerhandle:{[hp]
  if[hp in key wconn; :wconn hp];
  wconn[hp]:@[hopen;(writerconn hp;writertimeout);
              {[hp;e] .lg.w[`vtidb;"cannot reach writer ",string[hp],": ",e]; 0Ni}[hp]];
  wconn hp
  };

/ a timed-out handle is dropped so the next rebuild redials rather than waiting again
livepartitions:{[]
  hps:writerhpups[];
  if[not count hps; :0#0Nd];
  raze {[hp]
    h:writerhandle hp;
    if[null h; :0#0Nd];
    r:@[h;".wdb.getpartition[]";
        {[hp;e] .lg.w[`vtidb;"writer ",string[hp]," did not answer: ",e];
                @[hclose;wconn hp;()]; wconn::hp _ wconn; 0Nd}[hp]];
    $[null r; 0#0Nd; enlist r]
    } each hps
  };

/ with multiwriter off this is the stock rule: the newest date on disk, never behind current.
/ With it on, hold at the EARLIEST partition any writer still has open, so a stack that rolls
/ first cannot make a date immutable while another stack is still writing to it.
livepart:{[ds]
  base:$[count ds; max current,"D"$string last ds; current];
  if[not multiwriter; :base];
  ps:livepartitions[];
  if[not count ps; :base];
  held:min ps,base;
  if[held<base;
    .lg.o[`vtidb;"holding live partition at ",string[held]," - disk shows ",string[base],
                 " but a writer is still filling ",string held]];
  held
  };

/ discard the whole cache so the next rebuild rescans every date. The manual recovery path for
/ a directory added to a PAST date (§6.1). NOT needed after compression: a trailing-slash view
/ holds no inode to go stale on, so a rename-over is picked up immediately (§7.1).
dropcache:{[] parts::(`$())!(); opened::(`$())!(); };

/ forget specific dates, keeping the rest, so the next rebuild rescans only those. This makes
/ end of day O(instruments) rather than O(history). parts and opened are row-aligned and must
/ be filtered together.
dropdates:{[ds]
  if[not count ds; :()];
  {[ds;t]
    k:where not parts[t][`date] in ds;
    parts[t]:parts[t] k;
    opened[t]:opened[t] k;
    }[ds] each key parts;
  };

/ Build one virtual table. Immutable dates already held are reused; only the live date and
/ dates not yet seen are scanned.
/ NOTE the global must land in the ROOT namespace so clients can write "select from trade" -
/ `t set ...` inside a \d block defines .vtidb.t instead.
build:{[t;ds]
  if[not count ds; .lg.w[`vtidb;"no partitions found for ",string t]; :0];
  / ds holds directory NAMES as symbols; the catalogue holds real dates. keep both.
  dsd:"D"$string ds;
  old:$[t in key parts; parts t; empty];
  oldv:$[t in key opened; opened t; ()];
  / keep rows whose date is immutable and still on disk
  keep:where (old[`date] in dsd) and not mutable old`date;
  m:old keep;
  v:oldv keep;
  / everything else gets scanned: the live date, plus any date we do not already hold
  torescan:ds where not dsd in distinct m`date;
  if[count torescan;
    nm:raze scanone[t] each torescan;
    if[count nm;
      nv:open each nm`path;
      ok:where 98h=type each nv;
      if[count[ok]<count nv;
        .lg.w[`vtidb;"skipped ",string[count[nv]-count ok]," unreadable partition(s) of ",string t]];
      m,:nm ok;
      v,:nv ok]];
  if[not count m; .lg.w[`vtidb;"no partitions found for ",string t]; :0];
  parts[t]:m;
  opened[t]:v;
  @[`.;t;:;mkp (flip (`date,partitioncol)!(m`date; m partitioncol))!v];
  count m
  };

/ 4.6 - a table whose directory is missing for some date is served as absent, with no error.
/ The writer creates a directory for every table in every partition, so in a healthy database
/ every table covers the same dates. Compare them and log any difference.
coverage:{[] {asc distinct exec date from x} each parts };

/ WARNING do not name the local "cov" - it is a q keyword (covariance) and shadowing it
/ gives a value error at the assignment itself
checkcoverage:{[]
  bytab:coverage[];
  if[2>count bytab; :()];
  full:asc distinct raze value bytab;
  g:{[full;ds] full except ds}[full] each bytab;
  gaps:(where 0<count each g)#g;
  / only log when the gap set CHANGES - this runs on every sweep
  if[not gaps~lastgap;
    if[count gaps;
      {[t;m] .lg.w[`vtidb;"coverage gap: ",(string t)," has no data for ",(.Q.s1 m),
                          " - other tables do. see 4.6"]}'[key gaps;value gaps]];
    if[(0=count gaps) and count lastgap;
      .lg.o[`vtidb;"coverage gaps cleared - all tables cover the same dates"]];
    lastgap::gaps];
  gaps
  };

/ §5.2 - appends need no work: every partition is a live view, so rows are visible the moment
/ they land. The ONLY event a reader reacts to is a DIRECTORY APPEARING - a new instrument or
/ the next date. Called by the wdb when it creates one (§4.1), and by the backstop timer.
rebuild:{[]
  if[symchanged[]; loadsym[]];           / must precede any open: the enum domain grew
  before:count each parts;
  ds:alldates[];                         / one directory read per root, shared by every table
  current::livepart ds;                  / never let the live partition sit behind the disk
  build[;ds] each tablelist ds;
  after:count each parts;
  if[not before~after; .lg.o[`vtidb;"partitions ",(.Q.s1 before)," -> ",.Q.s1 after]];
  checkcoverage[];                       / 4.6 - the silent failure needs a voice
  after
  };

/ Called by the wdb at end of day (4.2). No data moves; a new date is just new directories.
/ .
/ Only the date that just closed can still be wrong - the writer's final flush may have created
/ directories not yet scanned - so forget that one and keep every older date.
/ NOTE the drop must happen BEFORE current moves, or the closed date reads as immutable and
/ build reuses its stale catalogue.
rollover:{[pt]
  / 8.3 - one writer announcing the new day does not mean every writer has rolled. Advancing
  / here would freeze a date another stack is still filling. Rescan instead, and let a later
  / rollover, or the sweep through livepart, advance once the others have caught up.
  if[multiwriter;
    ps:livepartitions[];
    if[count ps;
      newc:min ps,pt;
      if[newc<=current;
        .lg.o[`vtidb;"rollover to ",string[pt]," announced, but a writer is still on ",
                     string[newc]," - holding and rescanning instead of closing it"];
        rebuild[];
        :()];
      pt:newc]];
  .lg.o[`vtidb;"rollover to ",string pt];
  dropdates enlist current;
  current::pt;
  loadsym[];
  rebuild[];
  };

/ ---------------------------------------------------------------------------
/ startup
/ ---------------------------------------------------------------------------

/ Find the writer. NOT required - the sweep keeps the reader current without it - but
/ registering turns new-partition latency from <sweep> into <1s.
/ NOTE the arguments go in @'s second slot, not a projection: @[f[a;b];::;h] applies f OUTSIDE
/ the trap, so a failure there is never caught.
findwdb:{[]
  h:@[{[a] .servers.startupdepcycles . a; .servers.gethandlebytype[first a;`any]};
     (wdbtypes;wdbconnsleepintv;wdbcheckcycles);
     {[e] .lg.w[`vtidb;"no wdb: ",e]; ()}];
  if[not count h;
    .lg.w[`vtidb;"running without a wdb - the live partition is taken from disk, and new ",
                 "partitions will be picked up by the ",string[sweep]," sweep"];
    :()];
  w:first h;
  / a failed read leaves current where livepart put it. it must NOT fall back to .z.D - see
  / livepart for why that freezes the live partition for the rest of the day
  pt:@[w;(value;`.wdb.currentpartition);{[e] .lg.w[`vtidb;"could not read the wdb partition: ",e]; 0Nd}];
  if[not null pt; current::pt];
  @[w;(`.servers.registerfromdiscovery;`idb;0b);{.lg.e[`vtidb;"registration with the wdb failed: ",x]}];
  .lg.o[`vtidb;"registered with the wdb, current partition ",string current];
  };

init:{[]
  .lg.o[`vtidb;"scanning roots ",.Q.s1 roots];
  loadsym[];
  symsize::symbytes[];
  / current is left null: the first rebuild sets it from disk (livepart), and findwdb below
  / replaces it with the writer's own answer if there is a writer to ask
  n:rebuild[];                            / cache is empty, so this one scans everything
  .lg.o[`vtidb;"attached ",(.Q.s1 n)," across ",(.Q.s1 count distinct raze {exec date from x} each value parts)," date(s)"];
  findwdb[];                              / replaces current with the writer's actual partition
  if[.timer.enabled;
    .timer.repeat[.proc.cp[];0Wp;sweep;(`.vtidb.rebuild;`);"virtual table sweep - backstop for a missed wdb notification"];
    .timer.repeat[.proc.cp[];0Wp;symsweep;(`.vtidb.refreshsym;`);"enumeration domain check - 5.4"]];
  .lg.o[`vtidb;"initialised"];
  };

\d .

/ tables[] does not see virtual tables - they are type 112h, not 98h - so the attribute
/ has to come from our own catalogue
.proc.getattributes:{`partition`tables!(.vtidb.current;key .vtidb.parts)};

.vtidb.init[];
