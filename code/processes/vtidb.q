/ Virtual-table capture pack : IDB reader
/ .
/ Implements section 5 of docs/virtual-table-capture-pack.md.
/ .
/ Reads the capture database in place. There is no load, no copy, no partitioned
/ database and no RDB: each table is a kx.pq.t virtual table whose partitions are the
/ date/instrument directories the WDB writes, opened as live views. History and the
/ current day are the same objects, so one process answers both.
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
/ the name the partition column is exposed under, and the name used in the catalogue.
/ the reader cannot derive this: the column is not stored on disk, which is the point of the
/ design (§2.2). set it to whatever the source schema calls the parted column, so that client
/ queries read the same as they would against a conventional database.
partitioncol:@[value;`partitioncol;`instrument];
wdbtypes:@[value;`wdbtypes;`wdb];
wdbcheckcycles:@[value;`wdbcheckcycles;3];
wdbconnsleepintv:@[value;`wdbconnsleepintv;5];

/ ---------------------------------------------------------------------------
/ state
/ ---------------------------------------------------------------------------
current:0Nd;                             / the partition the writer is currently filling
symsize:0;                               / total size of the sym files at the last load
parts:(`$())!();                         / table -> catalogue of (date;<partitioncol>;path)
opened:(`$())!();                        / table -> opened live views, one per parts row.
                                         / NOTE not called "views" - that is a q keyword
lastgap:(`$())!();                       / table -> dates missing at the last check (4.6)

/ ---------------------------------------------------------------------------
/ the enumeration domain.
/ symbol columns in a partition are enumerations against $KDBDB/sym, so the domain
/ has to cover a directory's values BEFORE that directory is opened, or the symbols
/ resolve to the wrong values. same check stock TorQ's idb.q makes.
/ ---------------------------------------------------------------------------
/ every enumeration domain file in the tree. anything at a root that is a file rather than a
/ date directory is one: a stack written with .Q.ens[dir;t;`symb] leaves `symb` here, not `sym`.
/ discovering them rather than assuming `sym` is what lets two stacks keep separate domains
/ without colliding (§8.3.1).
symfiles:{[]
  raze {[r]
    k:key r;
    k:k where not k like "*.*";           / drops date directories and par.txt alike:
                                          / a domain file is named like an identifier
    f:.Q.dd[r;] each k;
    f where {x~key x} each f              / a directory keys to its contents, a file to itself
    } each roots
  };

/ `load` binds a global named after the FILE, so two roots can keep independent domains as
/ long as they are named differently - each column file records which domain it belongs to and
/ resolves through that one. what is not safe is two roots using the same NAME for different
/ content: one load wins and the other root's symbols then resolve wrongly, and silently (§8.3.1).
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

/ ---------------------------------------------------------------------------
/ 5.4 - the enumeration domain can grow with NO directory appearing.
/ .
/ a new value in a data symbol column - a new src, a new venue code - is appended to the
/ domain file by the writer and lands in an existing partition. no directory is created, so
/ the writer sends nothing (4.1 is edge-triggered on new directories), and the reader's
/ in-memory domain is then short by one entry. the rows are visible immediately, as any
/ append is, but that column reads as NULL until the domain is reloaded. silently.
/ .
/ this is why the domain gets its own timer rather than waiting for the rebuild sweep:
/ checking is one hcount per root, cheap enough to run every second, where a rebuild is
/ ~10 ms and has no reason to run that often.
/ ---------------------------------------------------------------------------
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

/ which tables to build.
/ .
/ discovering these from the tree rather than configuring them means a table added to
/ database.q needs no change here. Doing it by scanning EVERY date on every rebuild does not:
/ that is a readdir per date, so the cost grows with retention for ever, and it is paid on
/ every sweep to notice something that happens once in a deployment's life. Measured at 250
/ dates it was 2.6 ms of a 4.2 ms rebuild - the last cost in this reader still proportional to
/ history, which is what 8.2 removed everywhere else.
/ .
/ A new table can only appear where the writer is writing, so once anything is known, only the
/ live partition needs looking at. The cold path still scans everything, because a table that
/ has STOPPED receiving data exists only in history and would never be found on the live date.
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

/ open one partition, tolerating a directory that is mid-creation
/ .
/ NOTE this does NOT catch a directory whose .d names columns that are not on disk. get is
/ lazy, so such a partition attaches cleanly and even counts, and then breaks every query that
/ touches a missing column - for the whole table, since all partitions must be opened. That is
/ a real state (a full disk leaves one behind; every new partition passes through it while
/ being written) and it is deliberately not guarded here. See 5.7 for the measurement and the
/ reasoning: the transient race is rare and self-healing, and in the permanent case a loud
/ failure is worth more than a reader that keeps answering while quietly omitting an
/ instrument. testfiles/vt-diskfull-test.q pins down what actually happens.
open:{[p] @[get;p;{[p;e] .lg.w[`vtidb;"cannot open ",string[p],": ",e]; ::}[p]]};

/ can this date still gain a directory? only the live partition can. once a date has
/ rolled its directory list never changes again, so its catalogue and its opened views
/ can be reused instead of rescanned - which is what keeps rebuild off the critical path.
/ a null current (before the writer has been found) forces a full scan.
/ vectorised deliberately: "mutable each" on an empty list yields an untyped () which
/ then breaks the boolean and in build.
mutable:{[d] $[null current; count[d]#1b; d>=current] };

/ which partition is the writer filling?
/ .
/ getting this wrong is not cosmetic. a date classified immutable is CACHED and never
/ rescanned, so believing the live date has already rolled freezes it: every instrument that
/ starts trading afterwards is on disk, absent from every query, and nothing is logged -
/ there is no error to log, the reader simply stopped looking.
/ .
/ .z.D is the wrong answer, and wrong in the ordinary case rather than an exotic one. Whenever
/ .eodtime.rolltimeoffset is non-zero - any business day that does not end at midnight in
/ rolltimezone - the writer goes on filling YESTERDAY for offset hours after .z.D has advanced. A reader that comes up in that window without
/ a writer to ask (the writer is down, or the reader started first) would freeze the live
/ partition for the rest of the day.
/ .
/ The latest date on disk is a lower bound the writer cannot contradict: it cannot be filling
/ a date older than the newest directory it has itself created. So take the writer's answer
/ when we have one, but never let it sit behind the disk. That needs no connection tracking
/ and degrades correctly when the writer dies after telling us once.
/ .
/ NOTE max ignores nulls, which is what makes this work before any writer has been found.
livepart:{[ds] $[count ds; max current,"D"$string last ds; current] };

/ discard the whole cache, so the next rebuild rescans every date. the manual recovery path
/ for a change this reader cannot see by itself - a directory added to a PAST date (§6.1).
/ not needed after compression: §7.1 measured that a rename-over is picked up immediately,
/ because a trailing-slash view holds no inode to go stale on.
dropcache:{[] parts::(`$())!(); opened::(`$())!(); };

/ forget specific dates, keeping the rest of the cache, so the next rebuild rescans just
/ those. this is what makes end of day O(instruments) rather than O(history): the date that
/ just closed needs one final scan, and nothing older does.
/ parts and opened are row-aligned and must be filtered together.
dropdates:{[ds]
  if[not count ds; :()];
  {[ds;t]
    k:where not parts[t][`date] in ds;
    parts[t]:parts[t] k;
    opened[t]:opened[t] k;
    }[ds] each key parts;
  };

/ ---------------------------------------------------------------------------
/ build one virtual table.
/ immutable dates already held are reused as-is; only the live date and any date not
/ yet seen are scanned and opened. rescanning all of history on every tick is what made
/ rebuild linear in days as well as instruments (§8.2).
/ the global has to land in the ROOT namespace so clients can write "select from
/ trade" - `t set ...` inside a \d block defines .vtidb.t instead
/ ---------------------------------------------------------------------------
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

/ ---------------------------------------------------------------------------
/ §4.6 - the incomplete-partition failure is SILENT: a table whose directory is missing for
/ some date simply serves that date as absent, with no error (measured in §4.6). Nothing
/ else surfaces it, so compare coverage across tables and say so in the log.
/ .
/ the writer creates a directory for every table in every partition, so in a healthy
/ database every table covers exactly the same dates. a strict subset means a partition was
/ created without one of its tables - which is the failure this reader cannot detect any
/ other way.
/ ---------------------------------------------------------------------------
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

/ ---------------------------------------------------------------------------
/ §5.2 - appends need no work at all. every partition is a live view, so rows the
/ writer appends are visible the moment they land. The ONLY event a reader has to
/ react to is a DIRECTORY APPEARING - a new instrument, or the next date.
/ called by the wdb when it creates one (§4.1), and by the backstop timer.
/ ---------------------------------------------------------------------------
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

/ called by the wdb at end of day (§4.2). no data moves; a new date is just new directories.
/ .
/ the ONLY date whose catalogue can still be wrong here is the one that just closed: the
/ writer's final flush of the day may have created directories the reader has not scanned
/ yet. so forget that one date and let rebuild pick it up, and keep every older date.
/ .
/ dropping the WHOLE cache here - which is what this used to do - made end of day a full
/ rescan of history, ~47 us per directory, and it was the last cost that grew with retention.
/ the justification for it (compression needs a genuine re-open) was measured false in §7.1.
/ .
/ NOTE the drop has to happen BEFORE current moves. once current is the new date, the date
/ that just closed reads as immutable and build would reuse its stale catalogue instead.
rollover:{[pt]
  .lg.o[`vtidb;"rollover to ",string pt];
  dropdates enlist current;
  current::pt;
  loadsym[];
  rebuild[];
  };

/ ---------------------------------------------------------------------------
/ startup
/ ---------------------------------------------------------------------------

/ find the writer. it is NOT required - without it the sweep keeps the reader current -
/ but registering with it turns new-partition latency from <sweep> into <1s
/ NOTE the arguments go in @'s second slot, not into a projection: @[f[a;b];::;h] applies
/ f OUTSIDE the trap, so a failure there is never caught
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
