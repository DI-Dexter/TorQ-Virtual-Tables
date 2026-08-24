/ Virtual-table capture pack : WDB overlay
/ .
/ Implements sections 4.1, 4.2, 4.5 and 4.6 of docs/virtual-table-capture-pack.md.
/ .
/ Load order note: $KDBAPPCODE/wdb/ is loaded by .proc.reloadcode BEFORE the stock
/ code/processes/wdb.q, so anything defined here directly would be clobbered. Everything
/ is therefore defined under a private name and swapped in from .proc.initlist, which
/ runs last. Same pattern as the No-RDB pack's code/wdb/rollover.q.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

\d .wdb

/ partitions created during the current flush, as (partition;instrument) pairs
vtnew:();

/ this stack's enumeration domain (8.3.1). settings override it; default keeps stock behaviour
symdomain:@[value;`symdomain;`sym];

/ TorQ's directory-name sanitiser, factored out of upserttopartition so the fill logic
/ below builds identical names. non-alphanumerics become "_", nulls become TORQNULLSYMBOL.
/ WARNING lossy - EUR-USD and EUR_USD collapse into the same directory
vtdirname:{[expt] `$"_"^.Q.an .Q.an?"_" sv string `TORQNULLSYMBOL^ensuresymlist[expt]};

/ the schema a partition directory should have: the table minus its partition column(s),
/ because those are carried by the directory name (4.5)
vtschema:{[t;expttype] ![0#value t;();0b;expttype]};

/ ---------------------------------------------------------------------------
/ 4.5 - write the data WITHOUT the partition column.
/ a column stored inside the files can never be used to skip directories, so leaving
/ sym in the data would make every query on it scan the whole database.
/ also records directories that did not exist beforehand, for 4.6 below.
/ ---------------------------------------------------------------------------
vtupserttopartition:{[dir;tablename;tabdata;pt;expttype;expt;writedownmode]
  base:` sv .Q.par[dir;pt;tablename],vtdirname[expt];
  if[()~key base; vtnew,:enlist (pt;expt)];
  keep:{x!x} cols[tabdata] except expttype;
  r:?[tabdata;{(x;y;(),z)}[in;;]'[expttype;expt];0b;keep];
  .[upsert;(` sv base,`;r);{[e] .lg.e[`vtwrite;"failed to save partition: ",e];'e}];
  .merge.partsizes[base]+:(count r;-22!r);
  };

/ ---------------------------------------------------------------------------
/ 4.6 - every table must have a directory in every partition.
/ a partition holding trade but not quote breaks a reader's load outright, and if it
/ sorts first it silently truncates the reader's table list. cheap to prevent here.
/ ---------------------------------------------------------------------------
vtfill:{[pt;expt]
  {[pt;expt;t]
    d:` sv .Q.par[savedir;pt;t],vtdirname[expt],`;
    if[()~key first ` vs d;
      .lg.o[`vtwrite;"creating empty ",(string t)," for new partition ",1_string d];
      d set .Q.en[hsym hdbdir; vtschema[t;.merge.getextrapartitiontype t]]];
    }[pt;expt] each tablelist[];
  };

/ ---------------------------------------------------------------------------
/ 4.1 - tell readers about NEW partitions only.
/ appends need no notification: readers hold live views (5.2) and see them already.
/ the only event a reader must react to is a directory appearing.
/ ORDER MATTERS - fill every table's directory before notifying, or a reader can
/ rebuild against a half-created partition and fail (4.6).
/ ---------------------------------------------------------------------------
/ .
/ NOTE the pending carry-over is what covers a tickerplant log REPLAY. TorQ's replay does not
/ come through here at all: replaymaxrowcheck calls savetables[savedir;getpartition[];0b;t]
/ directly, once per table, whenever a table exceeds replaymaxrows. So vtupserttopartition runs
/ and vtnew fills correctly - with every directory, since deletewdbdata wiped the partition
/ first - but vtfill and the notification never fire. Clearing vtnew unconditionally here then
/ THREW THAT LIST AWAY on the first flush after the replay, so an instrument that only ever had
/ rows in one table came back without its empty directory in the other. Harmless while every
/ table is busy; it is 4.6's silently-absent-date the moment a table receives nothing all day.
vtsavetodisk:{[]
  pending:vtnew;                                     / anything a replay's direct calls left
  vtnew::();                                         / edge-triggered: only this flush counts
  savetables[savedir;getpartition[];immediate;] each tablelist[];
  news:distinct pending,vtnew;
  if[count news;
    vtfill . ' news;
    .lg.o[`vtwrite;"new partitions: ",.Q.s1 news];
    notifyidbs[`.vtidb.rebuild;enlist()]];
  };

/ ---------------------------------------------------------------------------
/ 4.2 - end of day does nothing but announce the new date.
/ stock endofdaysort would merge the instrument directories back into one table per
/ date, which is precisely the layout this design exists to avoid.
/ ---------------------------------------------------------------------------
vteodsort:{[dir;pt;tablist;writedownmode;mergelimits;hdbsettings;mergemethod]
  .lg.o[`vtwrite;"no-merge eod - partition ",string[pt]," stays in place"];
  notifyidbs[`.vtidb.rollover;enlist pt+1];
  };

/ ---------------------------------------------------------------------------
/ 8.3.1 - name this stack's enumeration domain.
/ symbol columns are indices into a file at the database root, and a reader binds a global
/ named after that FILE. two stacks that both call it `sym` cannot be served by one reader:
/ one load wins and the other's symbols resolve to the wrong values, silently. giving each
/ stack its own name removes the coupling entirely.
/ .
/ .Q.en[d;t] is .Q.ens[d;t;`sym], so redirecting .Q.en covers every enumeration site in the
/ writer at once - savetables, the empty-partition fill, and the initial table creation -
/ without copying a forty-line TorQ function to change one symbol in it.
/ ---------------------------------------------------------------------------
applysymdomain:{[]
  if[symdomain~`sym; :()];
  .lg.o[`vtwrite;"enumerating against `",string[symdomain]," instead of `sym (8.3.1)"];
  .Q.en:{[dom;d;t] .Q.ens[d;t;dom]}[symdomain];
  };

/ ---------------------------------------------------------------------------
/ 4.7 - the overrides must be installed BEFORE the tickerplant log is replayed.
/ .
/ .proc.addinitlist alone is not enough, and the gap is silent. Load order is:
/ .
/   code/wdb/origstartup.q       defines .wdb.startup
/   $KDBAPPCODE/wdb/vtwrite.q    this file
/   code/processes/wdb.q         defines savetables/upserttopartition, then CALLS startup
/   .proc.init[]                 runs the init list
/ .
/ startup[] is what subscribes to the tickerplant and replays its log, and it runs at the
/ bottom of wdb.q - a full second before the init list. So on any restart with a populated
/ log, every partition rebuilt by the replay was written by the STOCK writer, which keeps
/ the partition column in the files. That is the one thing this design cannot tolerate
/ (4.5), and it puts old and new partitions into the mismatched-column state of 9.3.
/ .
/ It only shows up on the normal recovery path - restart a writer whose log has data - so a
/ test that wipes var/ first will never see it. testfiles/vt-replay-test.q covers it.
/ .
/ startup is defined in origstartup.q, which loads BEFORE this file, and wdb.q only calls it.
/ So wrapping it here survives, where redefining anything wdb.q owns would not.
/ ---------------------------------------------------------------------------
origstartup:startup;
startup:{[]
  applyvtwrite[];
  origstartup[]
  };

/ ---------------------------------------------------------------------------
/ swap everything in once the stock wdb.q has finished loading.
/ still registered: the wrapper above covers the replay path, this covers a writer that
/ never subscribes (saveenabled off, or no tickerplant). applyvtwrite is idempotent.
/ ---------------------------------------------------------------------------
applyvtwrite:{[]
  .lg.o[`vtwrite;"installing virtual-table capture overrides (4.1, 4.2, 4.5, 4.6)"];
  upserttopartition::vtupserttopartition;
  savetables::savetablesbypart[;;;;writedownmode];   / rebind: it closed over the old upsert
  savetodisk::vtsavetodisk;
  endofdaysort::vteodsort;
  applysymdomain[];
  };

\d .

.proc.addinitlist".wdb.applyvtwrite[]";
