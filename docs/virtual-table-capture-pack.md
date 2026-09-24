# TorQ Virtual-Table Capture Pack — Architecture

A minimal TorQ capture stack that writes date+instrument partitioned data once and never
moves it again. History and live data are the same files; virtual tables are what make
those files queryable.

This pack is standalone. It is an application overlay onto a TorQ checkout, in the same way
the FX positions POC is — and it carries its own copy of the Finance Starter Pack's `trade`
and `quote` schema and feed, so nothing outside it has to exist.

Reference points, in the versions this was built and checked against: TorQ 5.2.12 and 5.2.15
(`$TORQHOME`), the kdb-x `kx.pq.t` module (`$QPATH/kx/pq/t.k`), Jonathon McMurray's `mp`
multipart module, and the
[No-RDB Starter Pack](https://github.com/DataIntellectTech/TorQ-No-RDB-Starter-Pack) — see §11.

Two companion scripts reproduce the evidence behind the decisions below:
`testfiles/vt-probe.q` (query-engine behaviour) and `testfiles/vt-limitations.q` (a presentable
summary of what does and does not work).

---

## 0. Design decisions and why

Every choice here was made against a specific alternative that was tried and rejected. If
you are picking this up cold, read this table first — most of the document is the evidence
behind one of these rows.

| decision | the alternative | why we chose this |
|---|---|---|
| **Strip the partition column from the files** | leave `sym` in the data, as TorQ's `partbyattr` does | a column stored inside the files can never be used to skip directories — the engine opens the files to check it instead. Leaving `sym` in means `where sym=X` scans the entire database, and you have paid the small-files cost for nothing. §2.2, §4.5 |
| **Partition by date + instrument** | date only, as a normal HDB does | instrument becomes a directory, so a selective lookup is a directory lookup rather than a scan. This is the whole point of the design, and it only pays off given the row above. §4.2 |
| **No EOD sort** | sort and apply `p#` nightly, as the No-RDB pack does | `p#` exists to make rows for one instrument contiguous. Directory structure already achieves that, cannot go stale under append, and needs no maintenance. §4.2 |
| **Open files with a trailing slash** | plain `get`, then re-read on every flush | a trailing slash gives a *live* view that tracks appends, verified across processes. Without it every reader must re-open every file it holds, every second. This removes most of the refresh machinery. §5.2 |
| **Rebuild only when a directory appears** | rebuild on every write | appends are already visible via the row above, so the only event a reader must react to is a *new* directory — a few times a day, not once a second. §5.3 |
| **Writer creates every table's directory** | let readers cope with gaps | measured: a reader given a partition missing one table does not error — it serves that table with the whole date absent, silently, until its next rebuild. Cheap to prevent on write, invisible on read. §4.6 |
| **Legacy data partitioned by date only** | replicated links, or a nested list of instruments | both were tried. Replicated links duplicate every row once per instrument; nested lists and nulls are simply ignored. Neither can reduce what is read, because all the entries point at the same file. §9.2 |
| **Separate table names for old and new formats** | one table spanning both | a virtual table reads its column list from the first file only and assumes the rest match. Mixing formats silently drops rows or returns the wrong instrument. §9.3 — this is the one genuine blocker |

---

## 1. Process inventory

| proctype | procname | port | role | status |
|---|---|---|---|---|
| `discovery` | `discovery1` | 6001 | service discovery | unchanged |
| `segmentedtickerplant` | `stp1` | 6000 | capture, log roll | unchanged |
| `wdb` | `wdb1` | 6005 | date+instrument partitions, 1s flush | **config + 5 overrides** (§4.1, 4.2, 4.5, 4.6, 4.7) |
| `idb` | `idb1..n` | 6030+ | virtual table over the whole tree | **new implementation** |
| `feed` | `feed1` | 6014 | dummy feed | unchanged |
| `compression` | `cmp1` | 6040 | weekend column compression; not started with the stack (`startwithall=0`), binds its port only while running | **replaced** (`vtcompress.q`) |

Deleted relative to the Finance Starter Pack: `rdb`, `hdb`, `sort`, `gateway`, sort workers.

There is no RDB (the WDB's 1s flush makes on-disk data fresh enough), no HDB (the same tree
serves both), no gateway (one process already spans all dates), and no sort/merge
(the write layout *is* the final layout).

---

## 2. The on-disk contract

Everything hinges on what `partbyattr` actually writes. From
`code/processes/wdb.q:135-154` (`upserttopartition`), the directory is built as:

```q
directory:` sv .Q.par[dir;pt;tablename],(`$"_"^.Q.an .Q.an?"_" sv string `TORQNULLSYMBOL^ensuresymlist[expt]),`
```

which produces:

```
$KDBWDB/
  sym                          <- enumeration domain (.Q.en target)
  2026.08.03/
    trade/
      AMD/   time price size stop cond ex side .d
      AAPL/  time price size stop cond ex side .d
    quote/
      AMD/
  2026.08.04/
    ...
```

Three consequences, all of which drive the rest of the design:

**2.1 This is not a q partitioned database.** `$KDBWDB/2026.08.03/trade/` contains
directories, not column files, and has no `.d`. `\l $KDBWDB` will not load it. In stock TorQ
this is fine because `partbyattr` is a *staging* format that only becomes queryable after the
EOD merge (`wdb.q:451`, `endofdaymerge`). We are deleting the merge, so something else has to
make the tree queryable. That something is the virtual table. This is the single reason the
whole design needs `kx.pq.t` rather than being a config change.

**2.2 The partition column is written into the files, and it must not be.** This is the
single most important correction to make to stock TorQ, so it is worth being precise about.

`upserttopartition` writes `r:?[tabdata;<sym constraint>;0b;()]` — the full row, `sym`
column included. So every file directory carries a `sym` column whose value is constant and
equal to the directory name it sits in.

That looks like harmless redundancy. It is not. When you query, the engine decides for each
condition in the `where` clause whether it can answer it from the **directory names** (in
which case it skips directories it doesn't need) or whether it must **open the files** and
check. The rule is simply: *if the column is stored inside the files, open the files*.

So with `sym` written into the data, `` where sym=`AMD `` opens every instrument
directory in the database and filters each one down to all-or-nothing. The answer is
correct, but the instrument partitioning has bought you exactly nothing — while still
costing you the file count of §8.1 and the rebuild cost of §8.2. That is strictly worse
than a plain date-partitioned database.

Remove the column and the same query becomes a directory lookup. This is what Jonathon
McMurray's `mp` module does on write:

```q
/ exclude partkey cols from saved data (these will be virtual cols)
selcols:{x!x} cols[data] except key partkey;
```

and it is why his benchmark reports 42ms against 778ms for a standard splay with `g#`.

The fix for our WDB is in §4.5. Note that the column is not lost — it is still queryable,
because the directory name supplies it.

**2.3 Directory names are lossy, and the consequence is worse than "interleaved".** `.Q.an?`
maps non-alphanumeric characters to `"_"`, so `BRK-B` and `BRK_B` produce the same directory
name. Earlier drafts of this document described the result as the two instruments' rows
interleaving. Measured (`testfiles/vt-collision-test.q`), it is sharper than that:

```
publishing 4 rows for `ZZ-PQCA and 6 for `ZZ_PQCA

directories created : ,`ZZ_PQCA          <- one, not two
rows for `ZZ-PQCA   : 0                  <- 4 published, none returned
rows for `ZZ_PQCA   : 10                 <- 6 published, 10 returned
```

**One instrument becomes completely unqueryable** — its rows are on disk, under the other
instrument's name — and **the other silently absorbs them**, returning more rows than were ever
published for it. Both answers are wrong and neither errors.

This is the one failure mode the writer cannot detect for itself: by the time it holds a
directory name, the character that distinguished the two instruments is already gone. Detecting
it would mean keeping a sanitised-to-original map and rejecting a second original that lands on
an existing name.

For plain uppercase tickers it never fires. For identifiers containing `.`, `-` or `/` it does,
on the first collision. If the universe can contain those, hash or escape the value before it
reaches the parted column.

---

## 3. Configuration

### 3.1 `appconfig/process.csv`

```
host,port,proctype,procname,U,localtime,g,T,w,load,startwithall,extras,qcmd
localhost,{KDBBASEPORT}+1,discovery,discovery1,${TORQAPPHOME}/appconfig/passwords/accesslist.txt,1,0,,,${KDBCODE}/processes/discovery.q,1,,q
localhost,{KDBBASEPORT},segmentedtickerplant,stp1,${TORQAPPHOME}/appconfig/passwords/accesslist.txt,1,0,,,${KDBCODE}/processes/segmentedtickerplant.q,1,-schemafile ${TORQAPPHOME}/database.q -tplogdir ${KDBTPLOG},q
localhost,{KDBBASEPORT}+5,wdb,wdb1,${TORQAPPHOME}/appconfig/passwords/accesslist.txt,1,1,,,${KDBCODE}/processes/wdb.q,1,,q
localhost,{KDBBASEPORT}+30,idb,idb1,${TORQAPPHOME}/appconfig/passwords/accesslist.txt,1,1,60,4000,${KDBAPPCODE}/processes/vtidb.q,1,-s 8,q
localhost,{KDBBASEPORT}+31,idb,idb2,${TORQAPPHOME}/appconfig/passwords/accesslist.txt,1,1,60,4000,${KDBAPPCODE}/processes/vtidb.q,1,-s 8,q
localhost,{KDBBASEPORT}+14,feed,feed1,,1,0,,,${KDBAPPCODE}/tick/feed.q,1,,q
```

IDBs are stateless and identical — replicate by adding rows. `-s 8` per the "heavy use of -s"
goal; each IDB is a read-only access point over the same files, so there is no coordination
cost to adding more. Note the `wdb1` load path is stock `${KDBCODE}/processes/wdb.q` — the
WDB changes in §4 are an app-code overlay, not a replacement.

On the kdb-x community edition, concurrent connection and memory caps apply. Start with one
IDB (as the No-RDB pack deliberately does) and add more as the licence allows.

### 3.2 Environment

Follow the No-RDB pack's convention of a single named data root with the stock variables as
aliases, so TorQ core and any stock settings that read them by name resolve to the same
place:

```sh
export KDBDB=${TORQDATAHOME}/db
export KDBHDB=${KDBDB}
export KDBWDB=${KDBDB}
```

A kdb-x install also needs three variables that are typically not set in the
shell profile, without which `q` fails with `license error: no license loaded` and `use`
cannot resolve modules:

```sh
export QHOME=~/.kx/q          # empty directory, but q requires it to be set
export QLIC=~/.kx             # where kc.lic lives
export QPATH=~/.kx/mod        # module search path for `use`
```

### 3.3 `appconfig/settings/wdb.q`

```q
// Virtual-table capture pack : WDB config

\d .wdb
savedir:hdbdir:hsym`$getenv`KDBDB        // one directory; sym file lives at $KDBDB/sym
writedownmode:`partbyattr                // split by date + instrument (necessary, not sufficient - see 4.5)
mode:`saveandsort                        // sort phase is overridden to a no-op (see 4.2)
immediate:1b                             // flush on every timer tick, ignore maxrows
settimer:0D00:00:01                      // ...every second
gc:0b                                    // 1s cadence: do not gc on every flush
rdbtypes:hdbtypes:gatewaytypes:()        // none of these exist
sorttypes:sortworkertypes:()
idbtypes:`idb
permitreload:0b                          // nothing to reload

\d .servers
CONNECTIONS:`segmentedtickerplant`idb`discovery
```

`writedownmode:`partbyattr` gets you the directory *shape* but not the behaviour — on its
own it also writes the partition column into the files, which defeats the purpose (§2.2).
It must be paired with the override in §4.5.

`savedir:hdbdir` matters: `savetablesbypart` enumerates with
`.Q.en[hdbsettings[`hdbdir];...]` (`wdb.q:173`), so this is what decides where `sym` lives.
The IDB must load that same file before opening any partition directory, and reload it whenever it
grows (§5.3).

`gc:0b` is deliberate. `savetablesbypart` calls `.gc.run[]` after every table save
(`wdb.q:181`); at a 1s cadence with `immediate:1b` that is a garbage collection every second.
Let the timer-based `.gc` config handle it instead.

### 3.4 `appconfig/sort.csv`

Still required — `getsortparams` (`wdb.q:619-639`) exits if a `partbyattr` process has no
`p` attribute defined, and `getextrapartitiontype` reads this file to decide which column
becomes the directory level.

```
tabname,att,column,sort
default,p,sym,1
default,,time,1
```

Note the practical restriction: the parted column must be named consistently across tables, or
given a per-table row here. Both tables in this pack key on `sym` (`database.q`), so a single
`default` row would do; the per-table rows are written out anyway, so that adding a table with
a differently named identifier is an edit rather than a debugging session:

```
tabname,att,column,sort
default,p,sym,1
trade,p,sym,1
quote,p,sym,1
```

### 3.5 `appconfig/settings/idb.q`

```q
// Virtual-table IDB config
\d .vtidb
roots:enlist hsym`$getenv`KDBDB          // list — one entry per capture stack (see 8.3)
tabs:`trade`quote
refreshmode:`notify                      // `notify (WDB-driven) or `timer
historydays:0W                           // how far back to map; 0W = everything

\d .servers
CONNECTIONS:`wdb`discovery
STARTUP:1b

\d .proc
loadprocesscode:0b
```

`database.q`, `code/tick/feed.q` and the STP settings are unchanged from this repo.

---

## 4. What has to change in TorQ

Six gaps, all verified against 5.2.15 source. None are large; all are load-bearing.

They share one root cause. In stock TorQ, `partbyattr` is a **staging** format: data written
that way is not meant to be read, it exists only between a flush and the nightly merge that
turns it into a normal database. So every code path concerned with "data somebody might
query" deliberately excludes it. Delete the merge, as this design does, and each of those
exclusions becomes a bug.

| gap | what TorQ assumes | fix |
|---|---|---|
| 4.1 | nobody reads staging data | overlay, ~10 lines |
| 4.2 | staging gets merged nightly | overlay, ~4 lines |
| 4.3 | readers load a normal database | rewrite (§5) |
| 4.4 | column files are three levels deep | settings override |
| 4.5 | the partition column belongs in the data | overlay, one expression |
| 4.6 | a later merge will even out the partitions | overlay, small |

### 4.1 The WDB never notifies IDBs in `partbyattr` mode

`wdb.q:190-193`:

```q
savetodisk:{[]
    changes:savetables[savedir;getpartition[];immediate;] each tablelist[];
    if[any[changes] and writedownmode in `partbyenum`partbyfirstchar`default;filldb getpartition[];notifyidbs[`.idb.intradayreload;enlist()]]};
```

and `wdb.q:643-652`:

```q
idbreload:{[pt]
    if[writedownmode in `partbyenum`default`partbyfirstchar;
        ...
        notifyidbs[`.idb.rollover;pt]
    ];
```

`partbyattr` is excluded from both. This is consistent with stock TorQ (the data is not
queryable until merged) but means an IDB would never hear about a flush or a rollover.

Fix — as an app-code overlay in `$KDBAPPCODE/wdb/vtwrite.q`, following the pattern the
No-RDB pack uses in `code/wdb/rollover.q`:

```q
\d .wdb

/ notify idbs on every flush; no filldb - .Q.chk is meaningless for this layout
vtsavetodisk:{[]
  changes:savetables[savedir;getpartition[];immediate;] each tablelist[];
  if[any changes; notifyidbs[`.vtidb.refresh;enlist()]];
  };

applyvtwrite:{[]
  .lg.o[`vt;"installing partbyattr flush notification"];
  savetodisk::vtsavetodisk;
  endofdaysort::vteodsort;                        // see 4.2
  };

\d .
.proc.addinitlist".wdb.applyvtwrite[]";
```

The deferral matters. `.proc.reloadcode` loads `$KDBAPPCODE/<proctype>/` at torq.q:643-644,
*before* the `-load` file, so a direct redefinition here would be clobbered when
`code/processes/wdb.q` loads afterwards. `.proc.addinitlist` (torq.q:12) queues the swap onto
`.proc.initlist`, which `.proc.init[]` runs last (torq.q:697). This is why `process.csv` can
keep pointing at the stock `wdb.q`.

Overriding `savetodisk` this late is safe: the timer holds `(`.wdb.savetodisk;`)` as a symbol
(`wdb.q:532`) and resolves it at fire time.

### 4.2 EOD must not merge

With `mode:`saveandsort`, `endofday` calls `endofdaysort` directly (`wdb.q:221`), which for
`partbyattr` runs `endofdaymerge` (`wdb.q:458-461`) — exactly the operation we are removing.

Fix — replace it with a rollover notification, installed by the same `applyvtwrite` above:

```q
\d .wdb
vteodsort:{[dir;pt;tablist;writedownmode;mergelimits;hdbsettings;mergemethod]
  .lg.o[`eod;"no-merge eod - partition ",string[pt]," stays in place"];
  notifyidbs[`.vtidb.rollover;enlist pt+1];
  };
\d .
```

That is the entire end-of-day operation. The STP rolls its log on its own schedule
(`.stplg.multilog:`tabperiod`), `endofday` bumps `.wdb.currentpartition` (`wdb.q:228`), and
the next flush creates the new date directory. Nothing is copied, sorted or reloaded.

Choosing `mode:`saveandsort` over `mode:`save` avoids `informsortandreload` logging a
spurious "no sortandreload process detected" error before falling through to the same
function (`wdb.q:515-524`).

Why nothing has to be sorted at all is worth stating explicitly, because it is the substantive
difference from the No-RDB pack (§11). The only reason that pack sorts at EOD is to apply a
`p#` to `sym`, and the only reason it needs `p#` is that its data is date-partitioned, so
rows for one instrument are scattered through the partition. **`partbyattr` is a physical
`p#`**: the grouping the attribute describes is already expressed as directory structure, and
directory structure needs no maintenance, cannot go stale under append, and does not have to
be rebuilt at a day boundary. That is what makes "minimal EOD" achievable rather than merely
desirable.

### 4.3 The stock IDB cannot load this layout

`code/processes/idb.q:20-24` is `system "l ",1_string idbdir` — an ordinary q database load,
which fails on the four-level tree for the reason in §2.1. The stock IDB also derives its
paths from `.wdb.writedownmode` and only handles `` ` `` vs `currentpartition` (`idb.q:37`).

This is a rewrite, not a patch — see §5.

### 4.4 The compression process sees nothing to compress

`code/common/compress.q`, `hdbstructure` classifies paths purely by depth:

```q
t:update partition:split[;base],table:`$split[;base+1],column:`$split[;base+2] from t where splitcount=base+3;  / partitioned
t:update table:`$split[;base],column:`$split[;base+1] from t where splitcount=base+2;                           / splayed
```

A `partbyattr` column file is at `base+4` (`root/date/table/instrument/column`), so it
matches neither branch, `table` stays null, and `showcomp` then does
`pathstab:delete from pathstab where table in `` ` `` — dropping every row. The compression
process runs successfully and compresses nothing.

Fix — add the missing depth:

```q
hdbstructure:{
  t:([]fullpath:(raze/)traverse x);
  base:count "/" vs string x;
  t:update splitcount:count each split from update split:"/" vs' string fullpath,column:`,table:`,partition:(count t)#enlist"" from t;
  / date partitioned : partition/table/column
  t:update partition:split[;base],table:`$split[;base+1],column:`$split[;base+2] from t where splitcount=base+3;
  / partbyattr : partition/table/instrument/column
  t:update partition:split[;base],table:`$split[;base+1],column:`$split[;base+3] from t where splitcount=base+4;
  / splayed : table/column
  t:update table:`$split[;base],column:`$split[;base+1] from t where splitcount=base+2;
  t:update partition:{$[not all null r:"D"$'x;r;not all null r:"M"$'x;r;"I"$'x]}[partition] from t;
  $[14h=type t`partition; t:update age:.z.D - partition from t;
    13h=type t`partition; t:update age:(`month$.z.D) - partition from t;
    t:update age:{$[all x within 1000 3000; x - `year$.z.D;(count x)#0Ni]}[partition] from t];
  delete splitcount,split from t}
```

The instrument level is folded away, so per-column rules in `compressionconfig.csv` keep
working unchanged.

**Where the override goes matters, and the obvious place does not work.** This is
configuration in spirit, so it belongs in `appconfig/settings/compression.q` — but settings
files are loaded before `code/common/compress.q`, which then redefines `hdbstructure` with the
stock version. Measured on this stack, the two loads are 13 ms apart:

```
15:27:51.407262 loading /…/appconfig/settings/compression.q
15:27:51.420287 loading /…/code/common/compress.q          <- clobbers it
```

The failure is silent and looks exactly like having made no change at all: the job runs, logs
success, and reports nothing in scope. The override therefore lives in
`code/processes/vtcompress.q`, which replaces the stock compression process and is loaded via
`-load`, after common code. `appconfig/settings/compression.q` keeps only `hdbpath` and
`maxage`, with a comment saying why the rest is not there.

Compression is safe to run underneath live readers — see §7, where this is measured rather
than assumed. Keep `minage` at 1 or more so the live partition is never touched.

### 4.5 The partition column is written into the files

The most important of the six, for the reason set out in §2.2: a column stored inside the
files can never be used to skip directories, so leaving `sym` in the data means every query
on it scans the whole database and the instrument partitioning achieves nothing.

`upserttopartition` (`wdb.q:147-148`) selects the rows for each instrument but keeps all
columns:

```q
r:?[tabdata; <constraint on the parted column>; 0b; ()];
```

The last argument is the column selection, and `()` means "all of them". Fix — select
everything *except* the parted column, the same way `mp` does:

```q
\d .wdb

/ drop the parted column(s) from the data: the directory name supplies them
vtupserttopartition:{[dir;tablename;tabdata;pt;expttype;expt;writedownmode]
  directory:` sv .Q.par[dir;pt;tablename],
              (`$"_"^.Q.an .Q.an?"_" sv string `TORQNULLSYMBOL^ensuresymlist[expt]),`;
  keep:{x!x} cols[tabdata] except expttype;         // <- the change
  r:?[tabdata;{(x;y;(),z)}[in;;]'[expttype;expt];0b;keep];
  .[upsert;(directory;r);{[e] .lg.e[`vtwrite;"failed to save: ",e];'e}];
  .merge.partsizes[first ` vs directory]+:(count r;-22!r);
  };
```

installed alongside the others in `applyvtwrite` (§4.1).

Two things to know about this. The column is not lost — queries still return `sym`, because
the directory name supplies it. And it is not optional: without it the entire design is
slower than the date-partitioned database it replaces.

### 4.6 A partition missing one table silently loses that date

Stock TorQ never hits this because the nightly merge produces a uniform database. Here the
partitions are permanent, so an instrument that quotes but has not yet traded leaves a
`quotes` directory with no `trades` sibling — an entirely ordinary state for a live feed.

**Measured, not assumed** — step 5 of §10. Earlier drafts of this section predicted the
failure modes of a `\l`-style load: an error for a gap in a later partition, and a silently
dropped table for a gap in the first. **Neither happens with this reader.** It never loads a
partitioned database; it scans each table on each date independently, and `scandate` returns
an empty catalogue when a table directory is absent (`vtidb.q`, the `()~i:key p` line). That
tolerance is deliberate — and it is exactly what makes the failure quiet.

What actually happens, with `trade` removed from one of two dates:

```
reader load              : LOADED           / no error
tables attached          : `quote`trade   / nothing dropped
dates for trade          : 2026.08.16       / 2026.08.17 simply absent
count select from trade : 4086             / was 8172 - half the data, no warning
```

Gap position is irrelevant: first partition and last behaved identically. The symptom is
uniform, and it is the bad kind — **the table answers queries, and the answers are quietly
incomplete.**

The damage is bounded by the reader's sweep rather than permanent:

```
gap present                    : 4086
directory restored, no rebuild : 4086       / a new directory needs a rebuild (§5.2)
after one rebuild              : 8172
```

So breaking the fill-then-notify ordering costs up to `sweep` seconds of wrong answers, not a
broken process. That is milder than the original prediction in one sense and worse in the
sense that matters: nothing surfaces it.

This is a writer-side fix, not a reader-side one. By the time a reader sees it the database
on disk is already malformed, and repairing it on every load is fixing someone else's mess.
Stock TorQ takes the same view — its WDB calls `filldb` (which is `.Q.chk`) after writing,
precisely so readers never see an incomplete partition (`wdb.q:576-579`).

So: **when the writer creates a partition, it creates a directory for every table, not just
the ones with data.** An empty table with the right schema is enough.

The ordering matters, and getting it wrong reintroduces the same bug as a race:

```
WRONG                              RIGHT
─────                              ─────
create USDJPY/quotes               create USDJPY/quotes
notify readers                     create USDJPY/trades  (empty)
reader rebuilds  -> FAILS          notify readers
create USDJPY/trades               reader rebuilds  -> ok
```

Fill first, then notify. Never the other way round.

For repairing a database that is already malformed — or validating one at startup — a
`.Q.chk` equivalent is worth keeping to hand. It must take the union of tables across *all*
partitions, not just the first, or it will reproduce the silent failure:

```q
/ helpers must be globals: nested lambdas in q cannot see enclosing locals
.mpchk.sd  :{[p] r where 11h=type each key each r:` sv/:p,/:key[p]};
.mpchk.has :{[p;t] not ()~key ` sv (p;t;`)};
.mpchk.tmpl:{[parts;t] 0#get ` sv ((first parts where .mpchk.has[;t] each parts);t;`)};
.mpchk.fix :{[tmpl;p;t] d:` sv (p;t;`); $[()~key d; [d set tmpl t; enlist d]; ()]};

mpchk:{[path;nk]                                    // nk = number of partition levels
  parts:{raze .mpchk.sd each x}/[nk;path];
  tabs:distinct raze {last each ` vs' .mpchk.sd x} each parts;
  tmpl:tabs!.mpchk.tmpl[parts] each tabs;
  made:(raze/) {[tmpl;p] .mpchk.fix[tmpl;p] each key tmpl}[tmpl] each parts;
  count made
  };
```

---

### 4.7 The overrides are not in force during tickerplant log replay

The other six gaps are things stock TorQ does that this design cannot tolerate. This one is a
gap in **the overlay itself**, and it stayed hidden for the whole build because every test in
the pack wipes `var/` before starting.

Restarting the writer is the ordinary recovery path, and TorQ handles it by deleting the
current partition and rebuilding it from the tickerplant log — `clearwdbdata`, then a replay,
the log being the source of truth for the day in flight. The replay happens inside
`.wdb.startup[]`, which `wdb.q` calls at the bottom of its own load:

```q
upd:.wdb.replayupd;
.wdb.clearwdbdata[];
.wdb.startup[];          / subscribes, and replays the log
```

`.proc.init[]` — which runs the init list, and therefore `applyvtwrite` — runs *after* the
`-load` file has finished. Measured on a real restart, about a second later:

```
185   subscribe|replaying the log file(s)
3560  subscribe|finished log file replay
3573  vtwrite|installing virtual-table capture overrides
```

So every partition rebuilt by the replay was written by the **stock** writer, which keeps the
partition column in the files (§4.5). The tree then holds a mixture of stripped and unstripped
directories, which is precisely the mismatched-column state of §9.3 — silently wrong answers,
no error. On the run that found this, all 22 partitions came back carrying a `sym` column file
and the reader returned a schema with `sym` in it twice.

Fix — wrap `startup` rather than relying on the init list. `startup` is defined in
`code/wdb/origstartup.q`, which loads *before* `$KDBAPPCODE/wdb/`, and `wdb.q` only ever calls
it, so a wrapper here survives where redefining anything `wdb.q` owns would not:

```q
origstartup:startup;
startup:{[]
  applyvtwrite[];
  origstartup[]
  };
```

The `.proc.addinitlist` registration stays as well — it covers a writer that never subscribes
(`saveenabled` off, or no tickerplant), and `applyvtwrite` is idempotent.

**This is the one defect in the pack that a wiped-database test can never find**, which is why
`testfiles/vt-replay-test.q` asserts the ordering out of the writer's own log rather than by
inspecting behaviour after a clean start.

#### The replay does not go through `savetodisk` either

The load-order fix above puts the overrides in force, so the replay writes the right *layout*.
It does not make the replay run the rest of a normal flush. TorQ's replay flushes through its
own door:

```q
replaymaxrowcheck:{[t;lmt]
    if[(rpc:count[value t]) > lmt;
        savetables[savedir;getpartition[];0b;t]];   / direct, once per table
    };
```

`savetables` is called directly, so `vtupserttopartition` runs and `vtnew` fills correctly —
with *every* directory, because `deletewdbdata` wiped the partition first — but `vtfill` and
`notifyidbs` never fire, because those live in `vtsavetodisk`. The accumulated list was then
discarded by the `vtnew::()` at the top of the first flush after the replay.

The consequence is §4.6's failure arriving by the recovery path: an instrument that has rows in
one table but not another comes back without its empty directory in the other. Observed on a
real restart — nine instruments with a `trade` directory and no `quote` one. Harmless while
every table is busy, since a query returns no rows either way. Not harmless the moment a table
receives nothing for a whole day: that date then has no directory for it, which is served as
silently absent.

The fix carries the list across the boundary rather than clearing it:

```q
vtsavetodisk:{[]
  pending:vtnew;                    / anything a replay's direct calls left
  vtnew::();                        / edge-triggered: only this flush counts
  savetables[savedir;getpartition[];immediate;] each tablelist[];
  news:distinct pending,vtnew;
  if[count news; vtfill . ' news; notifyidbs[`.vtidb.rebuild;enlist()]];
  };
```

In steady state `pending` is empty, so this costs nothing; it does work only on the one flush
that follows a replay. Verified on a live restart: nine `creating empty quote` lines one second
after the replay finished, and the instrument directories matched again.
`testfiles/vt-replay-test.q` asserts it from the tree, so it holds however the current state arose.

### 4.8 A tickerplant restart stalls capture, permanently and silently

Restart the tickerplant and the stack does not recover. Every process stays up, the writer keeps
logging `enumerated trade table` once a second, the reader answers queries — and the row count
does not move. Measured: still stalled ten minutes later, well past the five-minute
`.servers` `RETRY`.

Two independent causes.

**The feed cached its tickerplant handle.** `code/tick/feed.q` did what the Starter Pack's own
feed does — `h:.servers.gethandlebytype[…]` once at load, then `h(".u.upd";…)` on a timer. When
the tickerplant dies that handle is dead, and `.servers` reconnecting afterwards updates its own
table, not a copy somebody took at startup. The only trace is in a log nobody watches:

```
ERR|timer|timer ID 9 failed with error Cannot write to handle 7.
     OS reports: Bad file descriptor.
```

Fixed — the feed now resolves the handle on every publish, and skips the tick when there is no
tickerplant to publish to:

```q
tphandle:{[] .servers.gethandlebytype[`segmentedtickerplant;`any] };

send:{[]
  tp:tphandle[];
  if[not count tp; :()];                 / tickerplant down - the next tick tries again
  …
  };
```

**The writer does not re-subscribe.** `subscribe[]` is called only from `.wdb.startup[]`. TorQ
defines `.wdb.notpconnected[]` for precisely this condition — and never calls it, in `wdb.q`,
`rdb.q` or `chainedtp.q`. The predicate exists; nothing invokes it.

This one is **not** fixed here, deliberately. Re-subscribing also re-runs `fixpartition`, which
deletes the current partition and replays — and the tickerplant has just rolled its log, so a
naive timer risks rebuilding the day from the wrong subset. That needs designing, not patching.

The operational answer is to **restart the writer**, which replays the tickerplant logs and
loses nothing. Verified: 435 rows before, 2,005 immediately after, and rising. Data written to
the tickerplant while the writer was disconnected is all recovered — the stall costs freshness,
not data.

`testfiles/vt-tprestart-test.q` turns the silent stall into a check: it asserts an active
subscription, asserts the database is actually growing, and asserts the feed is not holding a
cached handle.

> **Note for anyone reading `.wdb.notpconnected[]` as a fix.** It reads `tickerplanttypes`
> unqualified, so it only resolves when the calling context is already `.wdb`. Called over IPC
> it raises a value error rather than answering. Query `.sub.SUBSCRIPTIONS` instead, which is a
> root-namespace table.


---

## 5. The IDB

### 5.1 What a virtual table actually is

From `~/.kx/mod/kx/pq/t.k`, the module exports `([mkT;mkP;tt;mt;fv])`.

The module's own term for "the table a partition points at" is a **leaf**; elsewhere this
document says *partition directory*, which is the same thing.

- `mkP` takes a dictionary `t!v` where `t` is a simple table of partition columns and `v` is
  the matching list of leaf tables. It stores them internally as `t:t!([]t:v)` — a keyed
  table from partition-key row to leaf.
- `tt` wraps a plain q table as a leaf. Its select handler is a straight functional select
  (`. (?;t;c;b;a),v`), so a memory-mapped splayed directory works as a leaf. Leaves do not
  have to be Parquet.
- Leaves in one `mkP` need not share a root, a format, or a granularity.

Query execution, from `mkP`'s handler (`t.k:11-12`):

1. `fe[tc]'(c;b;a)` splits the where clause, by clause and aggregations into the parts that
   reference *only* virtual columns and the parts that reference any leaf column.
2. `ct[c;t]` prunes the partition table using min/max statistics columns (§9.3).
3. `ex[...;*u;0b;()]` filters the partition table by the virtual-only constraints.
4. Each surviving leaf is queried with the leaf-referencing constraints.
5. Results are re-aggregated, with the partition key columns prepended.

### 5.2 The key fact: a trailing slash gives a live view

Before the code, the property everything else rests on.

Opening a splayed directory **with a trailing slash** returns a view that keeps tracking the
file as it grows. Without the slash you get a frozen snapshot:

```q
a:get `:/db/leaf       / no trailing slash
b:get `:/db/leaf/      / WITH trailing slash

/ another process appends 3 rows, then 2 more
count a    ->  5   5   5      / never moves
count b    ->  5   8   10     / tracks
```

Both are type 98h; nothing distinguishes them at the type level. Verified across processes:
a separate q process appended three times and the reader saw every append with no reload.

This is why `mp` needs no reload for appends — its `vtable` builds paths as
`` ` sv (path;tablename;`) ``, and that final backtick is what produces the slash.

**What it removes from this design.** An earlier draft of this document had the IDB evict
every live directory from a cache each second, re-open it, and rebuild — plus a file-size
guard to avoid doing that for instruments that hadn't traded. None of it is needed. Writers
and readers stay in step with no coordination at all, and the reader only has to react when
a *new directory appears*.

**What it does not cover.** A new directory — a new instrument, or the next day — is not
picked up, because the virtual table holds a fixed list of directories. That is the only
event requiring a rebuild, and it happens a few times a day rather than once a second.

### 5.3 Implementation — `code/processes/vtidb.q`

Built and verified. The process is ~150 lines; the shape is:

```q
/ bind mkP at the root and fully qualified - see "what the sketch got wrong" below
.vtidb.mkp:(use`kx.pq.t)`mkP;

\d .vtidb

/ the (date;instrument;path) rows for one table on one date under one root.
/ NB the trailing ` is what makes the view live (§5.2). without it each partition
/ is a frozen snapshot and the reader never sees another row.
scandate:{[t;r;d]
  p:.Q.dd[.Q.dd[r;d];t];
  if[()~i:key p; :empty];
  ([]date:count[i]#"D"$string d; instrument:i; path:{.Q.dd[.Q.dd[x;y];`]}[p] each i)
  };

build:{[t]
  m:scanall t;
  v:open each m`path;                    / open tolerates a directory mid-creation
  ok:where 98h=type each v;
  m:m ok;
  parts[t]:m;
  @[`.;t;:;mkp ([]date:m`date; instrument:m`instrument)!v ok];
  count m
  };

/ §5.2 - appends need no work. the ONLY event a reader reacts to is a directory
/ appearing. called by the wdb when it creates one (§4.1), and by the sweep timer.
rebuild:{[]
  if[symchanged[]; loadsym[]];           / must precede any open: the enum domain grew
  before:count each parts;
  build each tablelist ds;
  if[not before~count each parts; .lg.o[`vtidb;"partitions ..."]];
  };

/ NOTE the drop has to precede the move: once current is the new date, the date that
/ just closed reads as immutable and build would reuse its stale catalogue
rollover:{[pt] dropdates enlist current; current::pt; loadsym[]; rebuild[]; };
```

Config lives in `appconfig/settings/idb.q`: `roots` (a list, so one reader can serve several
capture stacks), `tabs`, `historydays`, `sweep`, and how long to wait for the writer.

**Measured end to end.** Writer creates the directory at `12:36:55.799`, fills every table's
directory and notifies at `.800`, reader has rebuilt at `.802`. Two milliseconds, and the
only work in that window is one `key` per date per table.

#### What the sketch got wrong

Three things the earlier draft of this section would have got wrong, all found by running it:

**`t set value` inside a `\d` block does not create a global.** It creates `.vtidb.t`. The
virtual tables have to land in the root namespace or a client's `select from trade` does not
resolve, so the assignment is `@[`.;t;:;v]`, which names the root namespace explicitly.

**`tables[]` does not see virtual tables.** They are type `112h`, not `98h`, so every
TorQ-side facility that enumerates tables — including `.proc.getattributes`, which the
discovery service publishes — comes back empty. The process reports its own catalogue
instead. This is worth knowing before pointing anything at the IDB that discovers tables
rather than being told them.

**`@[f[a;b;c];::;handler]` does not trap `f`.** Supplying every argument applies the function
where it is written, outside the trap, so the failure it exists to catch propagates anyway.
The arguments belong in `@`'s second slot: `@[f;(a;b;c);handler]`.

#### Two departures from the sketch, on purpose

**The table list is discovered from disk, not configured.** `tabs` defaults to `` ` ``, which
means "whatever table directories exist". A table added to `database.q` then needs no change
here. Set `tabs` explicitly only to *restrict* what a reader attaches.

The scan looks at the **live partition only**, plus every date once when the catalogue is empty.
Scanning all of history on every rebuild — which is what this did originally — is a `readdir`
per date, so the cost grew with retention for ever, and it was paid every sweep to notice
something that happens once in a deployment's life. Measured at 250 dates and 10,000
partitions:

| | rebuild |
|---|---|
| scanning every date | 4,194 µs |
| scanning the live partition | **1,428 µs** |
| `tabs` hard-configured, no scan at all | 1,445 µs |

Discovery is now free: it costs the same as not discovering. The scan itself went from 2,644 µs
to 113 µs.

What this gives up is stated in `testfiles/vt-newtable-test.q` and asserted there: a table appearing
on a date that has **already rolled** is not found by a rebuild, because that date is not
scanned. `dropcache[]` finds it. That is the same recovery path §6.1 already prescribes for a
*directory* added to a past date, so it adds no new rule — a new table arrives where the writer
is writing, which is the partition that does get scanned.

**The writer is optional.** The sketch blocked forever waiting for the WDB. The reader does
not need the writer — it reads a directory tree, and the sweep keeps it current on its own.
It waits a few cycles, logs a warning, and starts anyway. Registering with the writer is
purely a latency optimisation: it turns new-partition visibility from `sweep` (30s) into the
2ms measured above.

### 5.4 Rows travel free; new symbol *values* do not

§5.2's result is easy to over-read. Two different things travel at two different speeds, and
the difference is invisible until it bites.

**Rows appended to a directory the reader already holds are visible immediately** — no rebuild,
no notification, nothing told to the reader. That is the trailing slash doing its job.

**A symbol value that has never been seen before is not.** Symbol columns are indices into the
enumeration domain, and the reader holds that domain *in memory*. When the writer meets a new
value — a new `src`, a new venue code — it appends an entry to the domain file and writes the
rows into an **existing** directory. No directory is created, so nothing is announced: §4.1 is
edge-triggered on directories appearing. The reader's copy of the domain is then one entry
short, and that column reads as **null**:

```
rows for symbol   : 859  ->  869        <- the rows arrived, live view, no rebuild
distinct sides    : `buy`sell`          <- the new value resolved to NULL, silently
```

Nothing on disk is wrong. The reader is misreading correct bytes, and it corrects itself the
moment the domain is reloaded.

Before this was found the window was the 30-second rebuild sweep, because a rebuild is the only
thing that called `loadsym`. The domain now has its own timer:

```q
refreshsym:{[]
  if[symchanged[];
    loadsym[];
    .lg.o[`vtidb;"enumeration domain grew - reloaded"]];
  };
```

`symchanged` is one `hcount` per root, so it is cheap enough to run every second where a
rebuild has no reason to. `symsweep` in `appconfig/settings/idb.q` sets the interval.

Measured, three runs: **1.1 s, 1.9 s, 2.6 s** from publish to the value resolving. The floor is
the writer's own flush interval — the value is not in the domain file until the writer flushes —
so with `settimer` at one second, roughly two seconds is as good as this can get without the
writer announcing domain growth the way it announces directories. `testfiles/vt-symdomain-test.q`
holds it to a five-second budget and separately asserts that the *rows* arrive immediately,
which is the distinction worth protecting.

The partition column is never affected: it comes from the directory name and never goes near
the domain.

### 5.5 Why it is shaped this way

**Appends need no code at all.** Section 5.2. This is the single biggest simplification, and
it is worth stating plainly because the obvious design — re-read everything on every flush —
costs about 0.25 ms per directory. At 500 instruments across two tables that would be ~250 ms
of every second spent re-opening files whose contents you already had.

**Rebuild is driven by directory creation, not by writes.** The writer notifies when it
creates a partition (§4.6), not when it appends. On a static instrument universe that is
once a day; on a growing one, once per new instrument. Either way it is rare enough that
`rebuild` can afford to rescan everything rather than tracking deltas.

**A timer exists, but only as a backstop.** `sweep` runs every 30 seconds and does the same
work as a notification. It is there so a dropped message degrades into 30 seconds of
staleness rather than a reader that is permanently blind to a new instrument. It is not the
primary path, and the interval is deliberately slack.

**Sym is reloaded before any directory is opened.** Leaf `sym` columns are enumerations
against `$KDBDB/sym`; open a directory before the domain covers its values and it resolves
incorrectly. Stock TorQ uses the same `hcount` check (`idb.q:52-54`). One caveat inherited
from the No-RDB pack: at a fast cadence the reload happens every time the file grows, so a
high-cardinality symbol universe becomes a recurring cost. Since instrument is also the
partition column here, that is worth thinking about early.

**`.Q.MAP` does not apply.** The No-RDB pack maps the whole database once and refreshes one
partition slot per flush. That is a `.Q` facility for `.Q` partitioned databases, and this is
not one (§2.1). The trailing-slash view is the equivalent, and it needs no framework support.

**`mkP` reconstruction is free.** Because it captures directory handles rather than paths, a
new directory means rebuilding the whole virtual table. Measured, that costs 5–18 µs even at
500,000 partitions — it assembles a keyed table from vectors that already exist, with no
per-partition work. There is no reason to optimise it.

### 5.6 What a query sees when it lands mid-write

There is no lock anywhere on the read path, and the writer appends to the very directories a
client is querying. So the honest question is what a query returns when it arrives at the worst
possible moment. There are two such moments and they are governed by different mechanisms.

**Mid-append.** A splayed write extends the column files **one at a time**. Between `price`
being extended and `size` being extended, the partition genuinely has columns of different
lengths on disk. This is not rare — measured with one process appending and another reading as
fast as it could, **200 of 5,000 reads** landed in that window.

What comes back is a short read, never a wrong one:

```
reads                     5000
landed mid-append          200
rows seen               192100 .. 800000
invariant b = 2*a broken     0        <- not once
queries that errored         0        <- not once
```

The mechanism is the same rule that makes on-disk truncation silent in §4.6: **a splayed table
is cut to its shortest column.** Here that rule is what saves it. Truncation takes a *prefix*
of every column, so the rows that come back are internally consistent — a query simply misses
the last few rows, and the next query sees them. Nothing needs to be locked, retried or
coordinated.

**Mid-rebuild.** `rebuild` replaces the global the client is querying. A client that caught it
half-done would see a table whose catalogue and contents disagree. It cannot: q's main loop is
the lock. A rebuild is one message and a query is another, and they do not interleave. Measured
with a client asking — in a single message, so the answer is one instant — for three numbers
that must agree, while directories appeared underneath a reader rebuilding every 3 ms:

```
queries                 1500
rebuilds meanwhile      1998
partitions              20 -> 60
catalogue disagreed with the served table :  0 times
row counts that went backwards            :  0 times
```

The cost is therefore paid as **queuing**, not as inconsistency. A query that arrives during a
rebuild waits for it. That is the reason §8.2's work — making rebuild proportional to new
directories rather than to history — matters to readers and not only to the writer. At the
pathological 3 ms cadence above, median query latency was ~12 ms; at the configured 30-second
sweep it is invisible.

`testfiles/vt-inflight-test.q` covers both, and asserts the invariants rather than the timings.

### 5.7 A partition can promise columns it does not have

§4.6 and `testfiles/vt-damage-test.q` cover three kinds of damage. There is a fourth, and it is not
guarded against — deliberately, after building the guard and measuring what it was worth.

A splayed write lays down `.d` **first** and then the columns in order. So between those steps
the directory names columns that do not exist. `get` is lazy, so such a directory attaches
perfectly cleanly — it even *counts* correctly, because a count reads only the first column:

```
.d names       `time`price`side
on disk        `.d`time
get dir/       OK, type 98
count          20000                    <- correct, and completely misleading
select from    'No such file or directory
```

The blast radius is the usual one: every partition must be opened to answer a query that does
not name an instrument, so one such directory makes **every whole-database query fail** —
including queries that never mention the missing column. Selective queries on healthy
instruments are unaffected.

**How often does this actually happen?** Only at partition *creation*. Appends never produce
it: the columns all exist already, and a mid-append read is §5.6's harmless short prefix. So
the exposure is one burst per instrument per day, and the main rebuild trigger cannot see it —
`vtsavetodisk` notifies readers only after `savetables` and `vtfill` have both returned. That
leaves the 30-second sweep as the only way in. Measured: writing one partition takes 0.4 ms
(500 rows) to 6.5 ms (100,000 rows), so the daily window is the creation burst:

| instruments × 2 tables | creation burst | chance a sweep lands in it | expected |
|---|---|---|---|
| 10 | ~10 ms | 0.03% / day | once per ~9 years |
| 500 | ~0.5 s | 1.7% / day | once per ~2 months |
| 5,000 | ~5 s | 17% / day | once per ~6 days |

And when a sweep does land there, the consequence is bounded: whole-database queries fail until
the next sweep re-opens the finished partition, at most 30 seconds, with no intervention.

**Why it is not guarded.** The reader can check each partition against its own `.d` before
accepting it — `all (cols v) in key first ` vs p` — and that was implemented, tested and then
reverted. Two reasons.

It costs about **45% of a full rescan** (measured: 60 ms unguarded, 83 ms guarded, on 2,000
partitions; a further 31 ms if the check is placed before the `get`, which reads `.d` twice
because `get` parses it anyway). That is affordable, but it buys little against a race that
heals itself.

The second reason is the one that decided it. The only *permanent* source of this state is a
full disk — and a full disk means capture has already stopped. You are in an outage. A reader
that fails loudly sends someone to look; a reader that skips the directory keeps answering
queries while silently omitting an instrument, with nothing but a log line to say so. That is
precisely the failure signature this design spends §4.6, §5.4 and §8.3.1 trying to eliminate.
Masking it would have been the wrong trade.

`testfiles/vt-diskfull-test.q` asserts the unguarded behaviour, so it is pinned down rather than
merely known.

### 5.8 Which partition is live — and why `.z.D` is the wrong answer

`.vtidb.current` is the partition the writer is filling. It decides which dates are rescanned
and which are cached forever, so it is not a cosmetic variable: **a date wrongly believed to
have rolled is cached and never looked at again.** Every instrument that starts trading
afterwards is on disk, absent from every query, and nothing is logged — there is no error to
log, the reader has simply stopped looking.

The reader asks the writer. When it cannot — the writer is down, the reader started first, or
the read of `.wdb.currentpartition` failed — it has to decide for itself, and the obvious
answer is wrong. Set any non-zero `.eodtime.rolltimeoffset` — a business day that ends somewhere
other than midnight in `rolltimezone` — and from midnight until the roll the writer is still
filling *yesterday* while `.z.D` already says today. The measurement below used `0D09:00`,
a 17:00 roll in a UTC+8 timezone:

```
idb .z.D              2026.08.19
wdb currentpartition  2026.08.18       <- 9 hours a day, minimum
```

A reader that guessed `.z.D` in that window froze the live partition for the rest of the day.
Reproduced against the unfixed reader: a new instrument directory on disk, three rebuilds, and
the catalogue never moved off two partitions.

The date on disk is knowable without asking anyone, and it is a bound the writer cannot
contradict — it cannot be filling a date older than the newest directory it has itself created:

```q
livepart:{[ds] $[count ds; max current,"D"$string last ds; current] };
```

Take the writer's answer when there is one, but never let it sit behind the disk. This needs no
connection tracking and it degrades correctly in both directions: a writer that has rolled but
not yet flushed stays *ahead* of the disk and is respected, and a writer that dies after
speaking once no longer freezes the reader behind it. `testfiles/vt-restart-test.q` drives the real
`init` path and fails on the old behaviour.

## 6. End of day

In full, in order:

1. STP rolls its log file on its configured schedule and calls `.u.end`.
2. `.wdb.endofday` flushes remaining rows, calls the overridden `endofdaysort` (a no-op plus
   notification), sets `currentpartition::pt+1` (`wdb.q:228`).
3. IDBs receive `.vtidb.rollover`, reload `sym`, rescan, and pick up the new empty date.
4. The next 1s flush creates `$KDBWDB/<newdate>/<table>/<instrument>/`.

No data is copied. No sort. No merge. No process restart. The cost of EOD is one directory
scan per IDB.

The one thing that *does* have to happen at EOD is the rebuild — a new date means new
directories, and new directories are the only event a reader has to react to (§5.2). Note
step 3 depends on the writer having created every table's directory for the new date before
notifying, per §4.6.

---

### 6.1 Editing historical data

`mutable` treats any date before the live partition as immutable, and the reader reuses its
catalogue and opened views rather than rescanning. That raises a fair question: can historical
data still be corrected or backfilled?

Yes — but what "immutable" means here is narrower than it sounds. **It is an assumption about
the set of directories, not about their contents.** Measured on a copy of a real database:

| change to a historical date | reader sees it |
|---|---|
| **append rows** to an existing instrument directory | **immediately, with no rebuild** |
| **replace a column file** (write new, rename over) | **immediately, with no rebuild** |
| **add a new instrument directory** | **not until `dropcache[]` then `rebuild[]`** |

The first two work because the opened views are live regardless of which date they belong to —
liveness is a property of how the file was opened (§5.2), not of the date. Only the third is
blocked, because finding a new directory requires a rescan and immutable dates are not
rescanned.

So the runbook for correcting history is:

- **Backfilling rows into instruments that already exist** — just write them. Nothing else to do.
- **Backfilling a new instrument into a past date** — write it, then send the reader
  `.vtidb.dropcache[]` followed by `.vtidb.rebuild[]`, or `.vtidb.rollover[.wdb.currentpartition]`,
  which does both. Without that the rows are on disk and invisible.
- **Deleting a partition** — a removed directory *is* noticed, because `build` drops catalogue
  rows whose date is no longer on disk. It is the addition that needs the cache drop.

One caveat carried forward: the third row above also suggests §7's compression caveat may be
wrong. That caveat assumes a running reader holds a mapping on the old inode and keeps serving
pre-compression data. This reader does not memory-map at all (§8.2), and a rename-over was
picked up immediately here. That was tested with a plain column file, not a genuinely compressed
one, so **§7 stands until VT-15 tests compression itself** — but expect it to need the same
correction §8.2 did.

---

## 7. Compression

`code/processes/vtcompress.q` replaces the stock compression process. It applies the §4.4
classifier, applies the two gates below, calls `.cmp.compressfromtable` over what is left, and
exits. The pack drives it through one script:

```
./compress.sh              compress
./compress.sh --dry-run    report what would be compressed, change nothing
./compress.sh --test       compress underneath the running reader and verify it copes
```

Two gates decide what gets touched. **The age tier**, `minage` in
`appconfig/compressionconfig.csv`:

```
table,minage,column,calgo,cblocksize,clevel
default,7,default,2,16,9
```

Recent partitions stay uncompressed so interactive queries on them run at full speed. It must
stay above 0 whatever tier is chosen: that is also what keeps the job off the live partition,
and never compressing a directory the WDB may still append to is the important safety property.
`testfiles/compressionconfig-test.csv` holds a 1-day copy, which is how `--test` exercises the
job against a database only a couple of days old.

**The size gate**, `.cmp.minfilesize` in `appconfig/settings/compression.q`, defaults to 4096
and is the subject of §7.3. Set it to 0 to compress everything, which is stock behaviour.

Weekend scheduling: the process exits on completion, so drive it externally rather than from
the TorQ timer:

```
# Saturday 02:00
0 2 * * 6  /path/to/TorQ-VT-Capture-Pack/compress.sh
```

### 7.1 Readers do not need to be told

An earlier draft of this section carried a caveat: *"IDBs must re-map afterwards.
`cleancompressed` renames the compressed file over the original, so a running IDB keeps its
mapping on the old inode and serves pre-compression data indefinitely. Send
`.vtidb.rollover[…]` to each IDB when the job finishes, or restart them."*

**That is wrong, and it mattered** — it was the sole reason `rollover` dropped the reader's
cache, which is what made end of day cost a full rescan of history (§10, VT-17).

`./compress.sh --test` compresses the oldest complete partition while the stack is running,
and re-queries through the *same handle*, with no rollover sent and no cache dropped:

```
  before     1000000 rows in 750 column files
             30474 kB logical, 33372 kB allocated, 0 already compressed

  compressing - reader stays up, no rollover sent

  PASS  reader returns identical results through the same handle, with no rollover
  PASS  files are genuinely compressed (0 -> 350 of 750)
  PASS  no temporary files left behind
  PASS  the partition still holds rows, so the comparison above is not vacuous
  PASS  a cold process can open a compressed partition directly
```

The reason is the one already established in §8.2: a trailing-slash open is a *live view*, not
a memory map. There is no inode to go stale on, so the rename-over is picked up on the next
read. The reader needs no notification, no rollover and no restart, and end of day is free to
keep its cache.

### 7.2 What it actually saves

Measured by `./compress.sh --test` against a partition holding 20,000 rows per instrument —
a realistic day for a busy symbol:

| | before | after | saved |
|---|---|---|---|
| logical (bytes in the files) | 29.8 MB | 5.0 MB | **83.1 %** |
| allocated (what `df` reports) | 30.2 MB | 5.7 MB | **81.2 %** |

Both rows are large here, and that is the point: once a column file is comfortably bigger than
a filesystem block, the logical ratio and the disk ratio converge. `testfiles/vt-compress-ratio.q`
reads each compressed file's own header and buckets by the size it had before:

```
sizeband files logicalsaved disksaved blockswas blocksnow
---------------------------------------------------------
16-64 kB 150   66           60        750       300
>64 kB   200   84.9         83.5      6990      1152
```

Nothing appears below 16 kB because the size gate of §7.3 skipped it: 400 of the partition's
750 column files were too small to free a block, and were left alone.

**This is very sensitive to how much data lands in each directory**, which is the whole
small-files story of §8.1. On a thin partition — a few hundred rows per instrument — the same
job frees 83 % of the *bytes* and under 10 % of the *disk*, because almost every file already
fits in one block. Do not carry a compression ratio across from a different partition size.

### 7.3 So does it pay?

It costs read latency, and at these partition sizes it costs a lot. Same single-instrument
select, 1,000 samples (`testfiles/vt-compress-ab.q`):

```
state     | uncompressed gated ungated
compressed| 0            350   750
allocKB   | 33372        8220  8220
minus     | 382          805   775
medus     | 526          982   985
```

So roughly **+100 %** on the query the whole layout exists to make fast, in exchange for 75 %
of the disk. That is a real decision, not a free win — and note that the cost scales the same
way the benefit does: the bigger the partitions, the more there is to inflate on every read.

`testfiles/vt-compress-sizes.q` sweeps the partition size directly. Compressed size lands on the
floor — one block per column file — almost immediately and then stays flat, so the *saving* is
decided entirely by how large the files were to begin with, which is rows per instrument per
day:

```
rows        | 100  300  1000 3000 10000 30000 100000
kbperfile   | 1    1.9  4.9  13.6 43.8  130.3 433.1
cmpallocKB  | 28   28   28   36   64    152   468     <- flat: the one-block-per-file floor
disksaved   | 12.5 12.5 36.4 64   80    83.6  84.6
```

(Entropy is held constant across the sweep, so the absolute ratios are optimistic; the shape,
which is what sets the threshold, is not affected.)

#### The size gate, and what it does not buy

Since a file inside one filesystem block frees nothing, compressing it is pure cost. The job
therefore skips them — `.cmp.minfilesize`, default 4096. On the partition above that excludes
400 of 750 files. The expectation was that skipping them would also cut the read cost, because
a selective query opens every column of one instrument directory.

**It does not.** Gated and ungated are indistinguishable on latency in the table above (805 vs
775 µs minimum, 982 vs 985 median), and identical on disk — 8,220 kB either way, which is the
block floor again, proving the 400 extra files freed nothing at all.

The reason is structural rather than incidental. The gate only ever skips files in directories
that hold little data, and queries against those directories are already cheap. It cannot speed
up an expensive query, because an expensive query is by definition reading a directory with
enough data in it that none of its columns qualify.

The gate is still worth keeping, for operational reasons rather than query ones: it compresses
350 files instead of 750 for the same result on disk, which is less job time and 53 % fewer
files whose inode changes each weekend — which matters to `rsync`-style backup over a tree that
already has a small-files problem (§8.1).

#### Recommendation

Enable it, on a retention tier, with the size gate on — which is how the pack now ships
(`minage 7`, `minfilesize 4096`). The age tier is what makes the read cost tolerable: recent
data, which is what gets queried interactively, stays uncompressed and fast, while older data
gives back most of its disk. Below roughly 1,000 rows per instrument per day the layout has
already made the files too small for compression to recover much and the read cost is paid
anyway; above ~10,000 it recovers more than 80 % of the disk and the case is clear.

---

## 8. Scale and limits

### 8.1 File count

Files = `days × instruments × tables × columns`. For 500 pairs, 2 tables, 10 columns:
10,000 files/day, 2.5M files/year. Every one carries a `.d` sibling and a filesystem inode.
This is the drawback already identified, and it is real: it constrains the filesystem
choice, `rsync`-style backup, and any tooling that stats the tree.

### 8.2 Memory mappings — measured, and not the limit after all

**This section previously named memory mappings as the sharpest constraint in the design. Step 6
of §10 measured it properly and that was wrong.** The correction matters enough to show the
reasoning.

The original measurement was real and reproducible: opening a splayed directory with plain
`get` costs exactly one kernel mapping per column, so 500 directories of 7 columns added 3,500
mappings. Extrapolating that gave a ceiling of roughly nine days of history at 500 instruments
on a stock Linux box.

**But the reader does not open directories that way.** It appends a trailing slash to get a
live view (§5.2), and a trailing-slash open does *not* memory-map — it reads on demand. The
two are easy to confuse and cost completely different resources:

```
get `:.../AMD      -> +8 mappings      (8-column splay, 1 per column)
get `:.../AMD/     -> +0 mappings      (live view, what the reader uses)
```

Measured against the real `vtidb.q` on synthetic trees, reading every column of every
partition to be sure the data was genuinely touched:

| partition dirs | mappings added | file descriptors | RSS added | bytes/dir |
|---|---|---|---|---|
| 400 | 0 | 0 | 384 kB | 983 |
| 2,500 | 1 | 0 | 2.3 MB | 922 |
| 10,000 | 1 | 0 | 8.7 MB | 891 |
| 20,000 | 1 | 0 | 17.4 MB | 891 |
| 40,000 | 1 | 0 | 34.8 MB | 891 |

Mappings do not scale with partition count at all. Neither do file descriptors. The cost is
ordinary heap, and it is small and linear: **891 bytes per partition directory**, so a million
partitions is about 850 MB of RSS. `vm.max_map_count` is not reachable by this design.

The `historydays` knob therefore is not the memory-mapping defence this document previously
said it was. It is still useful, for the reason below.

#### The real limit is rebuild time

Rebuild rescans every date and re-opens every directory. That is linear in partition count,
and it runs on the sweep timer as well as on every new directory:

| partition dirs | full rescan | live rebuild | end of day | selective query |
|---|---|---|---|---|
| 400 | 14 ms | 1 ms | 1 ms | 237 µs |
| 2,500 | 100 ms | 3 ms | 3 ms | 245 µs |
| 10,000 | 381 ms | 6 ms | 7 ms | 269 µs |
| 20,000 | 758 ms | 6 ms | 7 ms | 249 µs |
| 40,000 | 3,691 ms | 6 ms | 8 ms | 279 µs |

That is the current `testfiles/vt-scale-test.q` output. The **live rebuild** column is the one that
runs on the sweep, and it is now flat at 6 ms from 10,000 directories to 40,000 — the table
scan no longer contributes to it. The full-rescan column is unchanged by that work (a cold
catalogue still scans every date) and it degrades faster than linearly at the top end as the
dentry cache stops holding the whole tree; it swings between roughly 2.7 s and 3.7 s at 40,000
across runs, and is left as measured. The *full rescan* column is what rebuild
used to cost on every sweep, and is what the two subsections below remove; it is kept because
it is the measurement that located the problem.

Two things to read off this.

**The design's core promise holds.** A selective query — one date, one instrument — is flat at
roughly 250–290 µs from 400 partitions to 40,000: a hundredfold change in database size moves
it by less than the run-to-run noise. It does not degrade as history grows, because the engine
never looks at the directories it does not need. That is the whole point of the design, now
verified at scale rather than argued.

**Rebuild was the constraint.** About 38 µs per partition directory when this was measured —
now ~69 µs — single-threaded, and it blocked the process while it ran. Against the default 30-second sweep:

| partition dirs | rebuild | share of a 30s sweep |
|---|---|---|
| 40,000 | 1.4 s | 5% |
| 100,000 | 3.4 s | 11% |
| 250,000 | 8.5 s | 28% |
| 1,000,000 | 34 s | **cannot keep up** |

That put the practical ceiling at roughly 100,000 partition directories — 500 instruments
across 2 tables for about 100 days — as a *latency* limit rather than a hard failure: past it,
queries stall for seconds at a time on every sweep.

**This table describes the original full-rescan behaviour.** It is kept because it is the
measurement that located the problem; the next subsection removes it.

#### The fix was in our own code, not KX's — and it is now implemented

**History is immutable.** Once a date has rolled, its set of directories never changes again;
only the live partition can gain one. So `build` keeps the catalogue *and the opened views*
for every immutable date it already holds, and rescans only the live date plus any date it has
not seen before. Rebuild becomes O(instruments) instead of O(instruments × days).

Measured, same harness (`testfiles/vt-scale-test.q`):

| partition dirs | rebuild, full rescan | rebuild, live date only | speed-up |
|---|---|---|---|
| 400 | 14 ms | 1 ms | 14x |
| 2,500 | 100 ms | 3 ms | 33x |
| 10,000 | 381 ms | 6 ms | 64x |
| 20,000 | 758 ms | 6 ms | 126x |
| 40,000 | 3,691 ms | 6 ms | **615x** |

The live-date rebuild is **flat** — 6 ms whether the database holds 10,000 directories or
40,000 — because the work no longer depends on how much history is attached. The sweep now
costs 8 ms every 30 seconds instead of seconds, at any depth. The table above showing rebuild
as the ceiling describes the pre-optimisation behaviour; that ceiling is gone.

Three details worth knowing about the cache:

- **A full rescan is still available**, via `dropcache[]`. It is the manual recovery path for
  the one change this reader cannot see by itself — a directory added to a *past* date (§6.1).
  It is no longer called at end of day; see §8.2.1.
- **The cache never blocks discovery.** It reuses only dates it already holds; a date that
  appears late — backfill, or a reader whose `historydays` widens — is not in the catalogue,
  so it lands in the rescan set. Verified by `testfiles/vt-gap-test.q`, which recovers a restored
  historical directory through the cache.
- **A null `current` forces a full scan**, which is what makes the first build after startup
  complete rather than partial.

If ever needed, two lesser levers remain: lengthen `sweep` (the notification path already
covers the latency-sensitive case), or bound `historydays` and route by date across readers.

#### 8.2.1 End of day is flat too

Making the sweep flat left one operation that still scanned everything: `rollover` dropped the
whole cache, so end of day cost a full rescan — ~47 µs per directory, which is 12 s at 250,000
partitions and 47 s at 1,000,000, as a blocking stall once a night. The justification was that
compression needed a genuine re-open, and §7.1 measured that it does not.

It could not simply be deleted, though. `mutable` is `d>=current`, so the moment `current`
moves to the new date the date that just *closed* reads as immutable — and `build` would then
reuse its catalogue as-is. Any directory the writer created in its final flush of the day,
before the reader last rebuilt, would be on disk and permanently invisible. Silently.

So `rollover` forgets exactly one date, the one closing, and does it **before** `current`
moves:

```q
dropdates:{[ds]
  if[not count ds; :()];
  {[ds;t]
    k:where not parts[t][`date] in ds;
    parts[t]:parts[t] k;
    opened[t]:opened[t] k;
    }[ds] each key parts;
  };

rollover:{[pt] dropdates enlist current; current::pt; loadsym[]; rebuild[]; };
```

End of day now costs one date's scan, and tracks the live rebuild rather than the cold one:

| partition dirs | cold rescan | live rebuild | **end of day** |
|---|---|---|---|
| 400 | 18 ms | 1 ms | **2 ms** |
| 2,500 | 90 ms | 3 ms | **3 ms** |
| 10,000 | 388 ms | 7 ms | **7 ms** |
| 20,000 | 731 ms | 8 ms | **8 ms** |
| 40,000 | 1,540 ms | 10 ms | **11 ms** |

Flat, and 140x cheaper at 40,000 directories. On the running stack a rollover takes 2.4 ms and
keeps every partition attached. `testfiles/vt-rollover-test.q` covers the failure mode above — it
creates a directory the reader has not scanned, rolls over, and checks the rows survive. It is
written to fail against the naive version of this change, and does.

**No operation left in this design scales with how much history is attached.**

#### What this means for the rejected mitigation

The granularity-mixing plan in earlier drafts existed to keep the mapping count flat as data
aged. Since the mapping count was never growing, that motivation is gone. Mixing granularities
is still blocked by §9.3, and that blocker is still real — but it is no longer entangled with
scaling, which makes the ask of KX narrower than this document previously claimed.
### 8.3 Adding tickerplants

`.vtidb.roots` is a list. A second capture stack writing to a different `savedir` is picked
up by adding its root — the scan produces more partitions, `mkP` takes them all, and nothing
downstream changes. The claim that TPs can be added without modifying anything downstream
holds, with one condition on the enumeration domain that §8.3.1 settles.

Measured cost of the extra root, same data split one tree versus two
(`testfiles/vt-multistack-test.q`):

| roots | partitions | rebuild | selective query |
|---|---|---|---|
| 1 | 22 | 73 µs | 254 µs |
| 2 | 22 | 119 µs | 278 µs |

A root costs one extra directory read per date per table on rebuild, and nothing at query time
beyond the wider partition table.

---

### 8.3.1 Each stack needs its own enumeration domain

Symbol columns are not stored as text — they are integer indices into a domain file at the
database root. The reader loads that file with `load`, and **`load` binds a global named after
the file**. Two stacks that both call theirs `sym` therefore collide: one load wins, and every
other root's symbol columns resolve against the wrong domain.

```
root a sym : `AAA`BBB`CCC
root b sym : `XXX`YYY`ZZZ

after loading a : sym = `AAA`BBB`CCC
after loading b : sym = `XXX`YYY`ZZZ

index 0 from root a's data should be AAA; it resolves to `XXX
```

No error, just wrong symbols — and two stacks that grew their domains independently will have
assigned different indices to the same symbols, so this is the default outcome rather than an
edge case.

**The fix is to name the domains apart, not to share one file.** `load` binds by filename, and
each column file records which domain it belongs to, so `sym` and `symb` coexist in one process
with each column resolving through its own. Both sides are configuration:

- writer — `symdomain` in `appconfig/settings/wdb.q`. `.Q.en[d;t]` is `.Q.ens[d;t;`sym]`, so
  the override redirects `.Q.en` once and covers every enumeration site in the writer rather
  than copying a forty-line TorQ function to change one symbol in it
- reader — `symfiles` discovers whatever domain files exist at each root instead of assuming
  `sym`, and `loadsym` now reports only the configuration that is actually unsafe: two roots
  using the **same name** for different contents

Three configurations, all verified by `testfiles/vt-multistack-test.q`:

| domains | outcome |
|---|---|
| `` `sym `` and `` `symb `` | **works** — stacks stay independent, one reader serves both |
| both `` `sym ``, different contents | **refused loudly** — the error names the domain |
| both `` `sym ``, identical contents | works, and symbol columns unify (see below) |

#### What separate domains cost

One thing does not unify across domains, and it is worth knowing before choosing:

| operation | separate domains | shared domain |
|---|---|---|
| group by the **partition column** | correct | correct |
| filter on a symbol column, `` where side=`buy `` | correct | correct |
| `` select … by value side `` | correct | correct |
| `` select … by side `` | **splits per domain** | correct |

The partition column comes from directory names rather than a domain, so the query this layout
exists to serve is unaffected. A filter is correct because comparing an enum to a symbol
resolves per element. But a *grouping* on a symbol column held inside the files gets one group
per domain — `` `sym$`book1 `` and `` `symb$`book1 `` are distinct values — so a cross-stack
aggregate by `side` returns one group per domain rather than one per value. `value` on the column fixes it.

That is visible rather than silent (the group labels carry their domain), and the test asserts
it so a change in the engine's behaviour shows up.

#### Sharing one domain is safe — the constraint is storage, not concurrency

An earlier draft of this section rejected the shared domain partly on the grounds that two
writers appending to one `sym` file risk corrupting it. **That is wrong.** The enumeration
primitive `.Q.en` calls is `path?syms` on a file handle, and it locks. Measured by
`testfiles/vt-sym-concurrency.q` — six concurrent processes, 1,800 enumeration calls, an overlapping
vocabulary:

```
  final domain size    507
  duplicate entries    0
  indices handed out   3012
  now resolving WRONG  0
```

No duplicates, and every index handed to a writer still resolves to the symbol it was issued
for — which is the property that matters, because column files already written carry those
indices.

The real constraint is physical. A domain file lives at a database root and the reader loads
`<root>/<domain>`, so "sharing" means both stacks writing **one inode**, symlinked into each
root:

```
/data/stackA/sym          the file
/data/stackB/sym -> /data/stackA/sym
```

That works — verified, both roots resolve against one domain and each stack's writes extend it.
It requires the stacks to share a filesystem.

What is *not* safe is two **copies**. They are identical the day you set them up and diverge the
moment either stack sees a symbol the other has not, at which point the configuration silently
becomes the colliding row in the table above.

#### Both modes are supported — how to configure each

The reader does not have to be told which mode is in use. `symfiles` discovers whatever domain
files exist at each root, and `loadsym` objects only to the one configuration that is actually
broken. So the choice is made entirely on the writer side, per stack.

**Shared domain** — one file, symlinked into each root. **The link has to exist before the
second stack writes anything.** Symlinking a domain over a tree whose columns were already
enumerated against a different one shares nothing: it reinterprets existing indices against the
wrong list, which is the collision case again. Leave `symdomain` at its default:

```q
/ appconfig/settings/wdb.q, on every stack
symdomain:`sym
```

```sh
# one physical file; every other stack links to it
ln -s /data/stackA/sym /data/stackB/sym
```

Verified: the link survives repeated writes — `.Q.en` appends to the file rather than replacing
it — both roots stay on one inode, and `hcount` follows the link, so the reader's
`symchanged` check still notices when the *other* stack extends the domain.

**Separate domains** — one file per stack, named apart. Set `symdomain` per stack:

```q
/ appconfig/settings/wdb.q, stack A          / stack B
symdomain:`syma                              symdomain:`symb
```

Nothing else changes; nothing needs to be linked.

| | separate domains | shared domain |
|---|---|---|
| stacks on separate storage | **yes** | not possible |
| stacks on shared storage | yes | **yes** |
| cross-stack `by` on a symbol column | needs `value` | correct |
| coupling between stacks | none | one shared file |
| concurrent writers | n/a | safe — the primitive locks |

Use the shared domain when the stacks already share storage and cross-stack aggregation by a
symbol column matters. Use separate domains otherwise — it is the only option across
filesystems, and it keeps the stacks independent, which is usually why a second one exists.

What must **not** happen in either mode is two *copies* of a domain under the same name. That
is the middle row of the table above: correct on the day it is set up, silently wrong from the
first symbol one stack sees and the other does not. The reader detects it and logs an error
naming the domain.

One further limit applies whichever mode is chosen: **the same `(date;instrument)` under two
roots is served twice.** `mkP` does not reject a duplicate key — it builds cleanly, the keyed
table shows one key, and a query returns the rows of *both* directories. Two stacks capturing
the same instrument therefore double-count, silently. Keep the instrument universes of two
stacks disjoint, or expect to deduplicate downstream. Asserted in `testfiles/vt-inflight-test.q`.

### 8.3.2 Two writers sharing one root

§8.3 adds a second stack with its **own** `savedir`, which is the arrangement to prefer. Two
writers pointed at the *same* root is a different proposition: it works in steady state, and
breaks in three places that stock TorQ is entitled to get wrong, because with one writer all
three assumptions hold.

All three fixes are off by default. A single-writer stack runs exactly the code it ran before.

| | flag | file |
|---|---|---|
| scoped pre-replay delete | `.wdb.multiwriter` | `code/wdb/vtwritemulti.q` |
| live-partition guard | `.vtidb.multiwriter` | `code/processes/vtidb.q` |
| tickerplant binding | `.wdb.tickerplantname` | `code/wdb/vttickerplant.q` |

#### The pre-replay delete removes the other writer's day

On startup TorQ's `clearwdbdata` deletes `.Q.par[savedir;partition;`]` — the whole date
directory — before replaying its own tickerplant log, then restores only its own rows. With two
writers over one root, restarting one destroys the other's data for that date. Measured:

```
before      stack1  869   stack2   902
after wdb2  stack1  290   stack2  1363    <- 579 stack-1 rows gone
after wdb1  stack1 2162   stack2   263    <- mutual
```

Every process in both stacks stayed up, and only the restarting writer logged anything at all
(`deletewdbdata|removing wdb data ... prior to log replay`). Nothing reports the loss.

With `.wdb.multiwriter` on, each writer records the instrument directories it creates in a
manifest at `<savedir>/.vtowner/<procname>_<partition>`, and the delete removes only those,
under every table in the partition. The manifest name contains a dot, so the reader ignores it:
`datedirs` keeps only date-shaped names and `symfiles` drops anything matching `*.*`.

`clearwdbdata` is defined and called inside `wdb.q`, so there is nothing to wrap. It deletes
through `.os.deldir`, and `code/wdb/` loads 12 ms before `wdb.q`, which is the window. Only the
exact partition-root delete is intercepted; housekeeping and `fixpartition`'s rename pass
straight through.

If a writer has **no** manifest for the partition but another writer's manifest exists at the
root, it deletes nothing and logs a refusal. A duplicate replay of its own rows is recoverable;
another stack's deleted day is not.

#### One stack's rollover closes a date the other is still writing

`mutable` is `d>=current`, so a date below `current` is cached and never rescanned. Stock
`livepart` takes the newest date on disk, so the **first** writer to create tomorrow's directory
advances `current` for every reader — while the other writer is still filling today. Every
directory it creates there afterwards is invisible for good, with nothing logged. Recovering it
needs `.vtidb.dropcache[]` and a sweep.

This does **not** require the stacks to be configured differently. Each stack has its own
tickerplant firing its own timer, so they never roll at the same instant:

| | measured |
|---|---|
| skew between two tickerplants, same roll offset | ~104 ms |
| skew between the two writers | < 1 ms |
| a writer stalled across the boundary | seconds to minutes |

With `.vtidb.multiwriter` on, the reader asks every writer which partition it is filling and
holds `current` at the earliest answer, in both `livepart` and `rollover`. Holding it lower is
always safe: `mutable` is a `>=` test, so a lower `current` rescans more dates, never fewer.

Verified against a real timer-driven roll with one writer stopped across the boundary
(`kill -STOP`, resumed 90 s later):

```
12:06:51.014  stock reader     rollover to 2026.09.18    <- closed the date 88s early
12:08:19.283  guarded reader   every writer has rolled - advancing to 2026.09.18
```

The writer handles are opened by the reader with `.vtidb.writertimeout`, not reused from
`.servers`, whose handles carry no timeout. A writer that is up but not answering — paused,
swapping, replaying a long log — would otherwise block the synchronous call and with it every
rebuild: measured at **5 m 12 s** against a stopped writer, during which ordinary queries still
served in 12 ms. A writer that times out is dropped and simply does not constrain the live
partition.

#### A writer binds to whichever tickerplant it hears about first

`wdb.q` subscribes with

```q
s:.sub.getsubscriptionhandles[tickerplanttypes;();()!()];
subproc:first s
```

— a filter on process **type**, none on process **name**, and then the first row of whatever
comes back. With one stack that is not a choice. With two visible to each other it is decided by
the order `.servers.SERVERS` happens to be in.

A writer on the wrong tickerplant is completely silent. It subscribes, it captures, it writes;
every process stays up and nothing is logged. It is simply writing the *other* stack's
instruments — so both writers claim the same directories, the reader serves every row twice, and
the scoped delete above now has two claimants for one set of instruments, which puts the
pre-replay delete back into play. Measured with the pin removed from an otherwise correct
two-stack start:

```
wdb1 owns  AAPL AIG AMD DELL DOW GOOG HPQ IBM INTC MSFT
wdb2 owns  AAPL AIG AMD DELL DOW GOOG HPQ IBM INTC MSFT   <- both on stp1
stack 2's instruments captured                        0
restarting wdb2                             472 -> 435    <- and it deletes stack 1's rows
```

`.sub.getsubscriptionhandles` already takes a procname filter; `wdb.q` simply never passes one.
`code/wdb/vttickerplant.q` wraps it so that a lookup which asks for a tickerplant type and leaves
the name open gets `.wdb.tickerplantname` injected. It has to be wrapped at **load** time, not
from `.proc.initlist`: `wdb.q` calls `startup[]` at the bottom of its own file, long before the
init list runs. `.sub` is common code, so it is already there when `$KDBAPPCODE/wdb/` loads.

The name is declared in `appconfig/settings/wdb.q` and set per writer from the process file's
`extras` column:

```
-.wdb.tickerplantname stp2
```

It must be **declared** in a settings file for that to work. `.proc.override[]` runs before
process code is loaded and only overrides variables that already exist, so a name declared only
in `code/wdb/vttickerplant.q` would be skipped without a word. The value arrives as a symbol:
`overrideconfig` casts the command-line string to the type of the existing value.

The demo feed has the same choice to make and takes it the same way, from
`.feed.tickerplantname`.

#### Starting both stacks: `VTSTACKS=2`

With the binding pinned, both stacks can live in **one** process file and start together:

```sh
VTSTACKS=2 ./deploy/bin/torq.sh start all
```

`setenv.sh` reads `VTSTACKS` and selects `appconfig/process-2stack.csv` over
`appconfig/process.csv`. That file is the single-stack topology plus a second tickerplant,
writer, feed and reader at `{KDBBASEPORT}+100`, with the three flags set per process in the
`extras` column.

The choice is then recorded in `$TORQDATAHOME/.vtstacks` and read back when `VTSTACKS` is unset,
so later calls need nothing:

```sh
VTSTACKS=2 ./deploy/bin/torq.sh start all
./deploy/bin/torq.sh summary
./deploy/bin/torq.sh stop all
```

It has to be remembered rather than re-typed, because `torq.sh` only knows about the processes in
the file it is given: a `stop all` that forgot the flag reads `process.csv`, stops the first
stack, and leaves the second running with nothing managing it. An explicit `VTSTACKS` always
wins and is written back in turn, and the marker sits with the database rather than the install,
so two data directories can run different topologies at once. Writing it is best effort — a
read-only data directory means the flag still works, it just has to be passed each time.

One process file rather than two also means one `-stackid`, so `torq.sh stop all` reaches both
stacks and `summary` lists all nine processes.

Two details make it safe to share the rest of the environment:

- the two tickerplants can share `KDBTPLOG`, because the segmented tickerplant names its log
  directory `<procname>_<date>`;
- the two writers share one root and therefore one `sym` file, which is the shared-domain mode
  of §8.3.1 with nothing to symlink — the enumeration primitive locks.

What is *not* shared is the instrument universe: `appconfig/settings/feed2.q` gives the second
feed a disjoint one. That file is loaded only for procname `feed2`, which exists only in
`process-2stack.csv`, so it is inert in the shipped single-stack topology.

#### Deployment rules

1. **Pin every writer to its tickerplant by name** — `.wdb.tickerplantname`, and
   `.feed.tickerplantname` on the feed. This is the only rule that holds however the stacks
   learn about each other: it filters at subscription time, so it does not matter whether the
   tickerplant came from the process file or from a shared discovery service.
2. **Or keep the stacks from seeing each other at all**, which is what the pin replaces: give
   each stack its own process file listing only its own tickerplant, pass it with `-procfile`,
   and set `.servers.CONNECTIONSFROMDISCOVERY:0b` on the second stack so it cannot learn the
   first stack's tickerplant from a shared discovery. Both halves are needed — the process file
   alone is not sufficient. (On kdb-x `DISCOVERYCONNECT` is `0b` when `.Q.lim` caps connections,
   but `CONNECTIONSFROMDISCOVERY` is not.) `examples/multi-writer/` is laid out this way.
3. **Keep the instrument universes disjoint**, per §8.3.1, and give each stack its own
   enumeration domain unless they are deliberately coordinated on one.
4. **Every writer sharing the root must enable the scoped delete.** One stock writer still
   deletes the whole partition; the manifest cannot defend against a process that does not read
   it.

`testfiles/vt-multiwriter-test.q` covers the two behaviours in isolation, including that each is
inert when its flag is off. `testfiles/vt-twostack-test.sh` runs two real stacks over one root
from hand-built config, and `testfiles/vt-vtstacks-test.sh` runs the same topology from the
pack's own config through `VTSTACKS=2` — the second of those asserts the manifests are disjoint,
which is what catches a writer on the wrong tickerplant.

### 8.3.3 Two stacks on separate roots — the worked setup

§8.3.2 is what to do when two writers *must* share a tree. This is the arrangement to prefer,
and it needs a different subset of the same three flags. The difference is not obvious, so it is
worth stating plainly: **separating the roots removes the delete problem and leaves the rollover
problem exactly where it was.**

| | shared root (§8.3.2) | separate roots |
|---|---|---|
| `.wdb.multiwriter` — scoped delete | **required** | not needed |
| `.wdb.tickerplantname` — the pin | **required** | **required** |
| `.vtidb.multiwriter` — live-partition guard | **required** | **required**, if one reader serves both roots |
| `symdomain` — §8.3.1 | leave at `` `sym `` | **required**, one name per root |

The delete stops mattering because each writer is alone at its root, so stock `clearwdbdata` is
correct again and cheaper. Leaving the flag on is harmless — with no other writer's manifest at
the root, `vtnomanifest` falls through to the stock full delete — but there is nothing to gain.

The rollover guard still matters because the reader holds **one** `current` across every root it
serves (`alldates` rakes `datedirs` over `.vtidb.roots`). When the first stack rolls, the reader
advances, and the other stack's still-open date becomes immutable **in its own tree**.

#### Configuration

TorQ loads settings in the order `default → parentproctype → proctype → procname`, so per-stack
values go in a file named after the process. No code changes and no extra `-load`.

**Why these files are needed here and not in §8.3.2.** `wdb1` and `wdb2` share the `wdb`
proctype, so `settings/wdb.q` hands them identical values; a file named after the *process* is
the only place two processes of the same type can differ. With a shared root nothing has to
differ — one `savedir`, one enumeration domain, one root for the readers — which is why
`VTSTACKS=2` works on a fresh install with no configuration at all. Separate roots is the first
topology where that stops being true, and the four files below are the whole of it.

The pack already ships one file of this kind: `appconfig/settings/feed2.q`, giving the second
feed its disjoint universe. That is the one thing which varies per process even with one root.

```q
/ appconfig/settings/wdb1.q                  / appconfig/settings/wdb2.q
\d .wdb                                      \d .wdb
savedir:hdbdir:hsym`$"/path/db1"             savedir:hdbdir:hsym`$"/path/db2"
symdomain:`syma                              symdomain:`symb
\d .                                         \d .
```

```q
/ appconfig/settings/idb1.q and idb2.q — one reader, both roots
\d .vtidb
roots:(hsym`$"/path/db1";hsym`$"/path/db2")
\d .
```

In the process file, keep the tickerplant pin and the reader guard and drop the scoped delete:

```
wdb1 ... -.wdb.tickerplantname stp1
feed1... -.feed.tickerplantname stp1
idb1 ... -s 4 -.vtidb.multiwriter 1
wdb2 ... -.wdb.tickerplantname stp2
feed2... -.feed.tickerplantname stp2
idb2 ... -s 4 -.vtidb.multiwriter 1
```

`VTSTACKS=2 ./deploy/bin/torq.sh start all` then starts both, exactly as for a shared root.

#### Verified

Two stacks, roots `db1` and `db2`, domains `` `syma `` and `` `symb ``, one reader on both:

```
one reader, both roots        817 rows - 378 from db1, 439 from db2, 20 instruments
idb1 = idb2                   1b
both domains loaded           syma 16, symb 16, no `sym` global
```

A writer restart touches only its own tree, with no scoped delete and nothing to coordinate:

```
                   before   after
stack 1 (db1)         509     692     <- untouched, still capturing
stack 2 (db2)         521     703     <- recovered from its own log

wdb2 log: deletewdbdata|removing wdb data (.../db2/2026.09.23/) prior to log replay
```

The rollover guard, forced by advancing one writer's `.wdb.currentpartition`:

```
livepartitions[]              2026.09.23 2026.09.24   <- wdb2 on today, wdb1 moved on
livepart returns              2026.09.23              <- the minimum

guard ON    current 2026.09.23   a new directory in db2/2026.09.23   1 row, visible
guard OFF   current 2026.09.24   the same directory on disk          0 rows, invisible
```

Note the failure only shows for a directory created **after** the freeze. One already in the
catalogue keeps being served, because freezing loses future directories rather than existing
ones — which is why the symptom is a missing instrument rather than a missing date.

#### The cost, from §8.3.1

Separate roots mean separate enumeration domains, and `` `syma$`Buy `` and `` `symb$`Buy `` are
distinct values. A cross-root grouping on a symbol column held inside the files returns one group
per domain:

```q
select rows:count i by side from trade          / 4 groups - one per domain
select rows:count i by value side from trade    / 2 - correct
```

Filtering, and grouping on the partition column, are unaffected — those are the queries this
layout exists to serve. The other cost is one extra directory read per date per table on rebuild
(§8.3: 73 µs → 119 µs at 22 partitions).

### 8.4 Under load — measured

Everything in §8.2 was measured on synthetic trees of 10-row partitions, driven by the demo
feed's handful of rows every 200 ms. This section replaces that with real volume.
`./loadtest.sh` starts a clean stack with no demo feed, bursts a configurable number of rows
through the tickerplant, and polls the reader until every row is visible — so the figure is the
whole chain, not the rate at which the tickerplant's queue can be filled.

| rows | instruments | offered | end to end | rows/dir | selective query | group by all | rebuild | files | on disk |
|---|---|---|---|---|---|---|---|---|---|
| 200k | 50 | 4.99M/s | **137k/s** | 4,000 | 1,048 µs | 3 ms | 4 ms | 851 | 8.8 MB |
| 1M | 50 | 4.77M/s | **637k/s** | 20,000 | 1,993 µs | 3 ms | 4 ms | 851 | 33 MB |
| 4M | 50 | 4.57M/s | **1,447k/s** | 80,000 | 6,087 µs | 5 ms | 4 ms | 851 | 122 MB |
| 1M | 500 | 4.59M/s | **216k/s** | 2,000 | 886 µs | 27 ms | 35 ms | 8,501 | 60 MB |
| 1M | 2,000 | 4.33M/s | **97k/s** | 500 | 807 µs | 71 ms | 142 ms | 34,001 | 164 MB |

**No data was lost in any run, and no errors were logged.** Every row published was visible to
the reader.

**Throughput rises with burst size**, because the ~1 second flush interval is a fixed cost that
amortises: 137k/s for 200k rows becomes **1.45M/s** for 4M. The writer is not the constraint at
these volumes — the flush cadence is. If low latency matters more than throughput, shorten
`settimer`; if throughput matters more, lengthen it.

**Selective queries track rows read, not database size.** 488 rows in 807 µs, 1,897 in 886 µs,
20,013 in 2.0 ms, 80,191 in 6.1 ms — roughly 0.1 µs per row at the larger sizes. This is the
design paying off in the way intended, and note the direction: *more* instruments makes a
single-instrument query **faster**, because each directory holds fewer rows.

**Instrument count is what costs.** Same 1M rows, three universes:

- write throughput falls (637k/s → 216k/s → 97k/s), because each flush touches more directories
- whole-database operations scale with directory count (group by all: 3 ms → 27 ms → 71 ms;
  rebuild: 4 ms → 35 ms → 142 ms), consistent with the per-directory cost in §8.2
- **storage amplifies 4.9x**: 35 bytes/row at 50 instruments, 63 at 500, **172 at 2,000** — the
  small-files cost of §8.1, now quantified rather than asserted

That last figure is the one to carry into capacity planning. Fragmentation, not row data,
dominates the footprint once the instrument universe is wide and each partition holds only a
few hundred rows — and the narrower the row, the worse the ratio, because the per-file overhead
is fixed. This schema's 7-column `trade` row is about half the width of the FX schema measured
in an earlier draft, and its amplification is correspondingly worse: 4.9x against 2.5x.

**The writer's memory is the burst buffer.** During the 4M-row run the writer was observed
holding 2,098,000 rows in memory in a single flush cycle, because the burst arrived faster than
the flush could drain it. That is correct behaviour and it absorbed the burst without loss, but
it means a sufficiently large burst is bounded by writer RAM rather than by disk. Worth a `-w`
limit and an alert in a real deployment.

### 8.5 When the disk fills up

The writer writes straight into the directories readers are reading; there is no staging area
to fail into. So a full disk is worth knowing in detail rather than guessing at.
`testfiles/vt-diskfull-test.q` runs the whole thing inside a private mount namespace with a small
tmpfs in it, so it fills a real filesystem without root and without touching anything outside.

**ENOSPC is an ordinary q error, not a death.** It names the file:

```
/db/2026.01.01/trade/I12/price. OS reports: No space left on device
```

The process stays up and keeps serving. (This is worth stating because the obvious way to
simulate a full disk — `ulimit -f` — is *not* equivalent: that raises `SIGXFSZ` and kills q
outright, which is a different failure and would teach the wrong lesson.)

**The data is not lost.** `savetablesbypart` upserts every partition and only *then* empties
the in-memory table, and the pack's `upserttopartition` override rethrows rather than
swallowing. The error therefore escapes before the table is cleared, and the rows are still
there for the next flush to retry.

**But a retry duplicates.** The failure happens part way through the partition loop, so
partitions written before it are already on disk — complete and readable. A retry re-upserts
the *whole* buffer, and nothing dedupes it:

```
save failed part way through          yes
rows still in memory                  80000      <- nothing lost
partitions already written            100 101 102 <- these get the same rows twice
```

So after a disk-full it is the partitions written **before** the failure that need checking,
not just the one that reported it.

**What is left on disk** is the incomplete partition of §5.7 — `.d` naming columns that were
never written. The reader attaches it without complaint, and every whole-database query then
fails naming the missing file; selective queries on healthy instruments keep working. That is
the intended signal rather than a defect (§5.7). Recovery is to free space and write the
partition again; the reader attaches the repaired copy on the next rebuild, with no restart.

## 9. Backward compatibility

Everything below is **verified by execution** — `testfiles/vt-probe.q` and
`testfiles/vt-sample-legacy.q` reproduce it:

```sh
QHOME=~/.kx/q QLIC=~/.kx QPATH=~/.kx/mod ~/.kx/bin/q testfiles/vt-probe.q
```

The probe makes one partition a poison value (an int, not a table) so any query against it
throws. A clean result therefore proves the partition was skipped; `THREW` proves it was
opened.

**Headline: attaching an existing HDB works today, and is simpler than expected.** What does
not work is putting old and new formats under one table name. Earlier drafts of this document
had that backwards.

### 9.1 Why the greenfield case is not affected

The mechanism is the one from §2.2: a condition on a column stored inside the files is
answered by opening the files, never by skipping directories.

| probe | virtual column | in the files? | result |
|---|---|---|---|
| 1a | `date` | no | **skips** |
| 1b | `instrument` | no | **skips** |
| 2a | `sym` | yes | **opens everything** |

1b and 2a are the same query on the same data; only the column name differs.

For new data this is settled by §4.5 — strip the column on write and the collision never
arises. For an existing HDB you cannot: `sym` is written into every partition, and removing
it means rewriting the database.

### 9.2 Attaching an existing HDB: partition on date only

The options in the original brief all added `sym` to the partition key in some form. None of
them help, and one is actively harmful. With a legacy table

```q
trade:([]sym:`AMD`AAPL`MSFT`AAPL; px:10 20 30 40f);
```

the correct answer for `` where sym=`AAPL `` is px 20 and 40.

| approach | result | why |
|---|---|---|
| `([]date:…)` — **date only** | **correct, 2 rows** | `sym` is filtered by the table itself, exactly as in a normal HDB |
| replicated links, key named `sym` | **6 rows — each duplicated 3×** | nothing is skipped, so all three entries query the same table and the results stack up |
| replicated links, key named `instrument` | **wrong instruments returned** | skips to the right entry, but the table receives no condition and returns the whole day mislabelled |
| null / wildcard key | correct, but the key is **ignored** | one entry, so nothing stacks; the null is never consulted |
| nested list of instruments | correct, but the key is **ignored** | likewise |

The last two are provably inert — put deliberate nonsense in the key and the answer does not
change:

```q
bad:vt.mkP ([]date:enlist 2020.01.01; sym:enlist `AAA`BBB`CCC)!enlist trade;
select from bad where sym=`AAPL      / still returns px 20 and 40
```

**And none of them could help even if they worked.** Every entry for a given date points at
the same table:

```
(2020.01.01, AMD) ─┐
(2020.01.01, AAPL) ─┼─> trade        one set of files
(2020.01.01, MSFT) ─┘
```

Filtering on `sym` might drop an entry from the list, but it never avoids opening a file —
they all lead to the same place. `date` is different, because each date genuinely is its own
set of files.

> **Instrument-level partitioning over an existing HDB cannot be achieved by configuration.**
> It requires the files physically rewritten into the new layout. Anything else is bookkeeping
> that costs correctness and buys no I/O.

So: attach legacy partitions keyed on date alone. Queries are correct and perform exactly as
they do today — not a regression, just not an improvement.

### 9.3 The blocker: one table cannot span both formats

New-format partitions have the instrument column stripped; legacy ones still contain it. A
virtual table reads its column list from the **first** partition only and assumes the rest
match.

```q
neweur:([]px:100 200f);                        / new format: sym is in the directory name
old   :([]sym:`AMD`AAPL; px:10 20f);      / legacy:     sym is in the data
```

Correct answer for `` sym=`AMD `` is px 100, 200 and 10.

```q
q) select from c1 where sym=`AMD    / new-format partition listed first
2026.08.03 AMD 100
2026.08.03 AMD 200                  <- legacy row SILENTLY DROPPED

q) select from c2 where sym=`AMD    / legacy partition listed first
2020.01.01 AMD AMD 10
2026.08.03 AMD AMD 100
2026.08.03 AAPL AAPL 200           <- AAPL returned for a sym=`AMD query
```

Same data, same query. Which failure you get depends on listing order — an implementation
detail no one should have to reason about.

The workaround is two table names:

```q
tradenew :vt.mkP ([]date:…; sym:…)!(new partitions);      / correct
tradehist:vt.mkP ([]date:…)!(legacy partitions);          / correct
```

Each is right in isolation. But a client wanting full history must know both names exist,
know the cutover date, query both and stitch — which is the RDB/HDB split this design set out
to remove.

It also blocks granularity mixing, though that matters less than earlier drafts claimed: the
mixing plan existed to hold the memory-mapping count flat, and §8.2 measured that the count
never grows. So this blocker is now purely about presenting one table name to clients, not
about scaling.

### 9.4 Partition-skipping hints: present, undocumented, and unusable here

There is a mechanism for skipping partitions based on a column's *range* rather than its
value. Virtual columns named `9<col>9min` and `9<col>9max` record per-partition minimum and
maximum, and are hidden from results. It works:

```q
q) select from v where px<2.5          / partitions whose min px is 10 and 100 are skipped
```

Two limits make it useless for this design.

**Only `< > <= >=` are recognised.** `=`, `in` and `within` return correct results but ignore
the hint and open everything, even though the hint plainly contains enough information:

```
where px<2.5              pruned
where px<=2               pruned
where px>=1, px<=2        pruned
where px=1.0              NOT pruned
where px in 1 2f          NOT pruned
where px within 1 2       NOT pruned
```

**Symbol columns cannot use it at all.** The engine works out which side of the condition is
the column name by testing which one is a symbol — for `` sym>=`AMD `` both sides are, so
it gives up. Since the partition key here *is* an instrument symbol, the entire mechanism is
unavailable exactly where it would be most useful. That closes off the last workaround for
§9.2.

### 9.5 Asks for KX, in priority order

1. **Support partitions with differing column lists** — or at minimum detect and reject them
   rather than silently dropping rows. Unblocks §9.3 *and* §8.2; by far the highest value.
2. **Guard against silent row multiplication.** Several partition entries sharing one table
   multiply result rows with no warning, even with no `where` clause at all.
3. **Apply a condition in both places when the column exists in both** the partition key and
   the data. Would make the legacy options in §9.2 correct — though see the caveat there
   about whether they are worth having.
4. **Identify the constrained column by position, not by type**, so symbol columns can use
   the hints in §9.4.
5. **`=`, `in`, `within` in hint matching.**
6. **Reject nested partition values** until they are properly supported — currently they are
   accepted and then conformed element-wise, which mislabels rows.
7. **Document the `9<col>9min`/`9<col>9max` convention.** It is a real, working feature with
   no public description and a name order that is easy to get backwards.

Items 1 and 2 are correctness. Nothing here requires a new storage format.

---

### 9.6 Status: designed and proven, deliberately not built

**The reader has no legacy path, and that is a decision, not an omission.** This is a
greenfield deployment with no history to migrate, and item 1 above — one table spanning both
formats — is with KX. Building the attachment now would mean shipping the two-table-name
workaround into a codebase that may not need it: if KX supports differing column lists, the
right design is one table name and the workaround becomes dead code carrying a migration story
nobody used.

It was prototyped far enough to retire the risk before being set aside. A conventional
date-partitioned database was built from real captured data, attached beside the capture tree,
and checked against a plain `\l` of the same files. (Measured on the FX schema this pack
carried at the time; the design is schema-independent, and the reader now has no legacy path
at all — see below.)

| claim | result |
|---|---|
| attaches keyed on **date alone** (§9.2) | one partition per date, not per instrument |
| exposed under its **own table name** (§9.3) | `trade` and `tradehist` side by side, both correct |
| row counts, symbols and numerics vs a direct read | identical |
| filter and group by the partition column | correct — it is in the data, as the legacy DB stored it |
| client query shapes | count, aggregate, time filter, distinct, sort, `meta`, and a union of both tables — all fine |
| **performance vs a conventional load** | **280 µs conventional, 320 µs through the reader** |

So the design in §9.2 and §9.3 holds, and the performance claim — "correct, and no faster" — is
now measured rather than asserted: about 14 % overhead, not a regression.

**What it takes when it is needed**, from the prototype:

- `legacyroots` and `legacysuffix` in the reader's settings
- a scan one level shallower (`root/date/table` *is* the splayed table, so `key` on it returns
  column names — its only use is existence)
- a build keyed on `date` alone, into `<table><suffix>`, cached like any other immutable history
- the legacy catalogue kept **apart** from `parts`, or §4.6's coverage check reads a legacy
  table's older dates as a gap in every other table
- legacy roots included in `symfiles`, under the same domain rules as §8.3.1

Roughly 40 lines in `vtidb.q`. Revisit when KX answers item 1, or when a deployment with real
history appears — whichever comes first.
## 10. Build order

Steps 0-4 have been done; the rest is the build.

0. ~~Establish how the query engine actually behaves.~~ **Done** — `testfiles/vt-probe.q`.
   Outcome: a column stored in the files can never be used to skip directories, which is what
   drives §4.5.
1. ~~Determine whether appends need a reload.~~ **Done** — they do not, given a trailing
   slash (§5.2). This removed most of the planned refresh machinery.
2. ~~Determine whether legacy data can be attached.~~ **Done** — yes, keyed on date (§9.2).
   Mixing formats under one table name cannot (§9.3).

3. ~~**WDB writing the right shape.**~~ **Done** — `code/wdb/vtwrite.q`. The tree is
   `date/table/instrument/`, the partition column is absent from the files, and a
   poison-partition test confirms a query on one instrument never opens the others.
4. ~~**IDB over a single day.**~~ **Done** — `code/processes/vtidb.q` (§5.3). The §5.2
   property is verified end to end through the real process: two IPC queries seconds apart
   returned 389 then 395 rows with the partition count unchanged, i.e. the writer's appends
   were visible with no reload and no notification.
   ~~*Still outstanding:* comparing results against stock kdb+.~~ **Done** — see §12.
5. ~~**New-partition handling.**~~ **Done.** Publishing a new instrument mid-session was
   verified end to end: the writer created every table's directory (§4.6), notified, and the
   reader rebuilt 19 → 20 partitions, 2 ms from directory creation to reader visibility.
   The fill-then-notify ordering was then deliberately broken, and **the failure is real but
   not the one this document predicted** — see the measured results in §4.6. The reader does
   not error and does not drop the table; it serves that table with the affected date missing,
   silently, until the next rebuild. The guard is still justified — arguably more so, since a
   silent wrong answer is worse than a crash — but the stated rationale was wrong and has
   been corrected.
6. ~~**Multi-day, and measure mappings** against `vm.max_map_count`.~~ **Done, and it
   overturned §8.2.** Measured on synthetic trees from 400 to 40,000 partition directories:
   the reader adds **0–1 mappings and 0 file descriptors regardless of scale**, because a
   trailing-slash open does not memory-map. `vm.max_map_count` is unreachable by this design.
   Cost is 891 bytes of heap per partition directory, linear. A selective query stays flat at
   300–400 µs across the whole range, which verifies the design's central claim at scale.
   The real limit turned out to be **rebuild time** — ~34 µs per directory, single-threaded,
   on the sweep timer — giving a practical ceiling around 100,000 directories. **That ceiling
   has since been removed**: `build` now reuses the catalogue and opened views for immutable
   dates and rescans only the live partition, which is 154x faster at 40,000 directories and
   flat with respect to history depth. See §8.2.
7. **Compression.** Done — `./compress.sh`, driven by `code/processes/vtcompress.q`. Two
   findings. The classifier override cannot live in the settings file, because settings load
   before `code/common/compress.q` overwrites it (§4.4); and readers need no rollover, no
   re-map and no restart across a compression run, which was the documented caveat and is
   false (§7.1) — which unblocked the end-of-day work in §8.2.1. What it saves
   is 93% of the bytes but only 37% of the disk, for ~30% more query latency, because a third
   of the column files already fit inside one filesystem block (§7.2). It now ships with an age
   tier (`minage 7`) and a size gate (`minfilesize 4096`) — the gate compresses 137 files
   instead of 308 for an identical result on disk and on latency (§7.3).
8. **Attach an existing HDB** as date-keyed partitions under a *separate* table name (§9.3).
   Prototyped and proven — correct, and 280 µs versus 320 µs against a conventional load — then
   deliberately reverted. Greenfield deployment, and the shape depends on the open KX item.
   §9.6 has the findings and what it takes to rebuild.
9. **Second capture stack** into a second root, to test the §8.3 claim.
10. **Make end of day flat.** Done — `rollover` forgets only the date it just closed rather
    than the whole cache, so end of day tracks the live rebuild (8 ms at 20,000 directories,
    against 857 ms) and no longer grows with retention. The naive version of this change loses
    the writer's final flush silently; §8.2.1 has the reason and `testfiles/vt-rollover-test.q`
    guards it.

Step 6 is the one that can invalidate the design at scale, so do not leave it until last. For
steps 4 and 6, reuse `bench/` from the No-RDB pack rather than writing a new harness —
`bench/run.sh` already seeds ~50M rows, stands up an RDB control, and runs a latency matrix,
which gives a directly comparable three-way number (RDB / date-partitioned / this design) on
the selective live lookup that the whole design is meant to win.

**Client compatibility is smaller than earlier drafts of this document claimed.**
`testfiles/vt-compat-test.q` probes 38 common operations against a virtual table: **27 work
directly, 11 fail, and all 11 work when applied to the result of a `select`**. Nothing is
unreachable.

An earlier figure of "33 operations, 22 direct, 9 failing" appeared here and in the status
report. It came from an ad-hoc session rather than a script, it did not add up (22 + 9 = 31),
and it could not be re-derived. The test above replaces it, and runs against a scratch tree of
its own so it needs no live stack.

```
meta trade                      'length      meta select from trade                ok
`time xasc trade                'type        `time xasc select from trade          ok
update flag:1b from trade      'type        update flag:1b from select from trade ok
trade[`side]                    'rank        (select from trade)[`side]            ok
```

The failures are all the same thing: applying an operation to the *table object* rather than
to data. The practical rule is "put a `select` in front of it" — a mechanical edit to existing
scripts, not a redesign.

Two corrections to earlier drafts, both found by probing rather than assuming:

- **Dot notation works.** `select time.minute from trade` returns correct values.
- **`ungroup` and `uj` are not virtual-table limitations.** The expressions used to test them
  fail identically on an ordinary in-memory table — they were bad tests.

The one genuine gap is `tables[]`, which does not fail — it succeeds and omits the virtual
tables, because they are type `112h` (§5.3). Anything that *discovers* table names rather than
being told them sees nothing. That affects tooling, not analysts. Checking dashboards for
`tables[]` and bare table references is still worth doing, but it is no longer the thing most
likely to change the design — §8.2 is.

---

## 11. Relationship to the No-RDB Starter Pack

Checked against [DataIntellectTech/TorQ-No-RDB-Starter-Pack](https://github.com/DataIntellectTech/TorQ-No-RDB-Starter-Pack)
at commit `73956f9`.

The two designs agree on the whole skeleton. It is worth being explicit that this is a change
of *one variable* rather than a different architecture:

| | No-RDB pack | this design |
|---|---|---|
| one directory, `savedir==hdbdir` | yes (`KDBDB`) | yes, adopted |
| continuous 1s flush, `immediate:1b` | yes | yes |
| N identical readers, no gateway | yes | yes |
| RDB / HDB / sort workers | none | none |
| **partition scheme** | **date only** | **date + instrument** |
| on-disk shape | real q partitioned DB | 4-level, not q-loadable |
| reader | stock `idb.q` + `.Q.MAP` overlay | replacement, `kx.pq.t` virtual table |
| EOD | staged copy, sort, atomic swap | nothing but a notification |
| sort process | yes | not needed |

Everything downstream follows from the partition scheme. Because that pack stays
date-partitioned its database is a normal q partitioned DB, so `\l` works, `.Q.MAP` works,
and the stock IDB needs only a small overlay. Because this design partitions by instrument as
well, none of that holds (§2.1) and the virtual table does the job `.Q` does there.

**Adopted from it:**

- **The `.proc.addinitlist` overlay pattern** (§4.1). Its `code/wdb/rollover.q` and
  `code/idb/mapping.q` both define under a private name and swap in from `.proc.initlist`,
  because `$KDBAPPCODE/<proctype>/` loads *before* the stock process code and a direct
  redefinition gets clobbered. This is why `process.csv` can keep pointing at stock `wdb.q`.
- **Touch only what can have changed** (§5.4). Its `refreshliveslot` refreshes one partition
  slot and leaves the rest alone; an early draft here rescanned every date on every flush.
  The trailing-slash view (§5.2) later made even that unnecessary, but the principle drove
  the design.
- **Reload sym on growth, and treat it as a recurring cost** (§5.4), which an early draft
  omitted and which would have broken on the first new instrument.

**Deliberately not adopted:**

- **The EOD staged sort.** That pack copies the day's partition, sorts the copy and swaps it
  in with two atomic renames — transiently 2× the day's disk — solely to apply `p#` to `sym`.
  Partitioning by instrument makes that unnecessary (§4.2). This is the design's clearest
  win: it removes the last EOD operation *and* the transient disk requirement.
- **`.Q.MAP` and the two read modes.** Not applicable to a non-`.Q` database. The
  trailing-slash view is the equivalent and needs no framework support.

**Honest comparison.** On EOD cost this design is unambiguously better, and that needs
nothing from KX. On live selective lookups — the thing it exists to win — it should be
dramatically better: that pack's own benchmark puts an indexed RDB lookup at 0.7 ms against
370 ms for a mapped on-disk scan, and its README is explicit that attributes cannot be
maintained under continuous append, so the live day is always un-indexed. Turning that scan
into a directory lookup is the entire point, and §4.5 is what makes it happen. Verify it at
step 4 rather than assuming it.

The area where that pack remains ahead is ordinary q compatibility: its database is a real
partitioned database, so everything works on it. See the note at the end of §10.

## 12. Agreement with stock kdb+

Everything up to here shows the design behaves as intended. This section asks a different
question: **given the same data, does it return the same answers as ordinary kdb+?**

Method — `testfiles/vt-compare-kdb.sh`. Two databases are built from the *same captured bytes*: the
new date+instrument tree, and a conventional date-partitioned splay with `sym` stored
as a real column. The conventional one is stood up as a plain q process, with no TorQ involved.
19 queries are then run against both and the results compared after normalising for row order,
column order and symbol representation.

**Result: 16 of 19 identical. 3 differ, and in all 3 the virtual table raises an error rather
than returning a wrong answer.**

```
PASS  total row count                     PASS  min / max / avg
PASS  count by date                       PASS  distinct on the partition column
PASS  filter on the partition column      PASS  select specific columns
PASS  filter on partition column + date   PASS  time-range filter
PASS  filter on a data column             FAIL  dot notation on a temporal column
PASS  combined partition and data filter  PASS  empty result - instrument that does not exist
PASS  in on a list of instruments         PASS  weighted average
PASS  sum aggregate                       FAIL  fby
PASS  group by the partition column       FAIL  count distinct
PASS  group by date and a data column
```

**No silent disagreement was found.** That is the material result: an error is recoverable, a
quietly different number is not.

The three failures follow the pattern established in §10 — they fail on the table object and
work when wrapped in a `select`:

| query | direct | wrapped in a select |
|---|---|---|
| `select n:count i by time.hh from t` | `'time.hh` | works |
| `where price=(max;price) fby sym` | `'length` | works |
| `select nd:count distinct sym from t` | `'type` | works |

Note that dot notation works in a *select list* (`select time.minute from t`) and fails only in
a *by* clause; and `fby` works on a data column and fails only on a partition column. The
failures are narrower than the operation names suggest.

`count distinct` deserves a caveat: it is not a true aggregation, so kdb+ itself returns
per-partition rows for it against a partitioned database. That query needs rethinking whichever
backend it runs on.

### 12.1 Two representation differences, neither a defect

**Symbol columns come back as enumerations in-process.** A local query against the virtual
table returns symbol columns as unresolved enumerations (type `20h`) where a conventional
partitioned select resolves them to symbols (`11h`). Values compare equal, but `~` does not
match. **Over IPC both send plain symbols**, so remote clients — dashboards, other processes —
see no difference at all. This only matters to code running inside the reader.

**The partition column name is configurable, and now matches the schema.** The reader cannot
derive this name — the column is not stored on disk, which is the whole point of the design
(§2.2) — so it comes from `partitioncol` in `appconfig/settings/idb.q`, defaulting to
`instrument` and set to `sym` here. That means a client query reads exactly as it
would against a conventional database, and the comparison in this section needed no renaming on
either side.

Set it to whatever the source schema calls the parted column. Getting it wrong is not subtle —
queries fail with a value error on the column name rather than returning anything misleading.

### 12.3 On a brand new database, the tables do not exist yet

Found while building the load test. A reader started against an *empty* database defines no
tables at all — `build` finds no partitions, warns, and returns without creating the global.
So `select from trade` is a **value error**, not an empty result:

```
q)count select from trade
'trade
```

A conventional kdb+ stack would have the schema in memory from `database.q` and return an empty
table. Here the tables only come into existence once the writer has flushed something.

This is narrow — it lasts from process start until the first flush, so about a second in a live
stack — but it is real at the beginning of a deployment, and a client that starts up and
immediately queries can hit it. Two options if it matters: have the reader define empty schema
tables when a partition is missing, or have clients treat a value error on first query as "not
ready yet". Not currently handled either way.

### 12.2 One case where the virtual table is better

`exec side from trade` against the conventional partitioned database **fails with `'nyi` over
IPC**, whether or not the client has the sym file. The same query against the virtual table
returns correctly. Not a reason to choose the design, but worth knowing that the compatibility
gap is not entirely one-directional.

---

## 13. Known issues and silent failure modes

Every entry below is reproduced by a script in `testfiles/`. The ones in **bold** fail
*silently* - wrong answers or missing data, with no error, no warning and no log line. That is
what makes them worth listing together rather than only in the sections that explain them.

| risk | impact | mitigation |
|---|---|---|
| Storage amplifies 4.9x at wide instrument universes | Capacity planning | Measured; size the estate on 172 B/row, not row data |
| Large bursts bounded by writer RAM | Writer could exhaust memory | Set a `-w` limit and alert |
| Cross-stack `by` on a symbol column splits per domain | Wrong group count in multi-stack reports | Documented; use `value`, or share one domain (§8.3.1) |
| One table cannot span both data formats | Clients must know two table names | Raised with KX; workaround in place |
| Small-files count | Constrains filesystem choice and backup tooling | Known and quantified; inherent to the design |
| **A tickerplant restart stalls capture until the writer is restarted** | Silent — every process stays up and looks healthy | Feed fixed; writer needs a manual restart, which replays and loses nothing. Detect with `vt-tprestart-test.q` (§4.8) |
| **A truncated column file returns fewer rows, silently** | Wrong answers, no warning | Demonstrated (`vt-damage-test.q`). Specific to **uncompressed** columns: a compressed one carries a metadata header kdb+ validates, so the same damage raises instead. No detection exists for the uncompressed case |
| **Instrument names differing only in punctuation** | **One becomes unqueryable, the other absorbs its rows — silently** | Demonstrated (`vt-collision-test.q`). No detection exists. Hash or escape identifiers containing `.` `-` `/` before they reach the parted column |
| Client scripts need edits | Migration effort for existing dashboards | Quantified: 11 of 38 operations need a `select` wrapper (`vt-compat-test.q`) |
| A writer restart deletes and rebuilds the live partition | Anything not in the current tp log is not restored | Stock TorQ recovery; know it before restarting a writer |
| **A partition whose `.d` names columns that are not on disk** | **Every whole-database query fails, not just that partition** | Not guarded, by decision (§5.7): transient case heals within one sweep, permanent case is a full disk where failing loudly is correct. Pinned down by `vt-diskfull-test.q` |
| **A disk-full retry re-writes partitions that already succeeded** | Duplicate rows, silently, in the partitions written *before* the failure | Demonstrated (`vt-diskfull-test.q`, §8.5). No dedupe exists — check those partitions after any ENOSPC |
| **The same `(date;instrument)` under two roots** | Rows served twice, no error, one key | Demonstrated (`vt-inflight-test.q`, §8.3.1). Keep stack instrument universes disjoint |
| Partitions created during tp log replay are not announced | Up to 30s of staleness after a writer restart; `vtfill` skipped for them | Known, not fixed (VT-21.7) |
| **A stock writer sharing a root with multi-writer writers** | On its restart it deletes the WHOLE date directory, destroying every other writer's data for that date | Not defendable from the manifest — a process that does not read it cannot be stopped. Every writer on a shared root must set `.wdb.multiwriter` (§8.3.2) |
| **Two writers that can see each other's tickerplant** | A writer subscribes to the WRONG stack's tickerplant and captures its instruments; both writers then claim the same directories, the reader serves every row twice, and a restart puts the pre-replay delete back in play | Pin each writer with `.wdb.tickerplantname` and each feed with `.feed.tickerplantname` (§8.3.2); or keep the stacks apart with their own `-procfile` and `.servers.CONNECTIONSFROMDISCOVERY:0b`. Measured; nothing logs it. `vt-vtstacks-test.sh` asserts the ownership manifests are disjoint |
