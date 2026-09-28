/ Virtual-table capture pack : WDB overlay. Sections 4.1, 4.2, 4.5, 4.6 of
/ docs/virtual-table-capture-pack.md.
/ .
/ This file loads BEFORE the stock code/processes/wdb.q, so anything defined directly would
/ be clobbered. Everything is named privately and swapped in from .proc.initlist, which runs
/ last.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

\d .wdb

/ partitions created during the current flush, as (partition;instrument) pairs
vtnew:();

/ this stack's enumeration domain; the default keeps stock behaviour. §8.3.1
symdomain:@[value;`symdomain;`sym];

/ TorQ's directory-name sanitiser, factored out of upserttopartition so the fill logic
/ below builds identical names. non-alphanumerics become "_", nulls become TORQNULLSYMBOL.
/ WARNING lossy - EUR-USD and EUR_USD collapse into the same directory
vtdirname:{[expt] `$"_"^.Q.an .Q.an?"_" sv string `TORQNULLSYMBOL^ensuresymlist[expt]};

/ the schema a partition directory should have: the table minus its partition column(s),
/ because those are carried by the directory name. §4.5
vtschema:{[t;expttype] ![0#value t;();0b;expttype]};

/ write the data without the partition column - a column inside the files can never be
/ used to skip directories, so leaving sym in would make every query on it scan everything.
/ Also records directories that did not exist beforehand, for 4.6.
vtupserttopartition:{[dir;tablename;tabdata;pt;expttype;expt;writedownmode]
  base:` sv .Q.par[dir;pt;tablename],vtdirname[expt];
  if[()~key base; vtnew,:enlist (pt;expt)];
  keep:{x!x} cols[tabdata] except expttype;
  r:?[tabdata;{(x;y;(),z)}[in;;]'[expttype;expt];0b;keep];
  .[upsert;(` sv base,`;r);{[e] .lg.e[`vtwrite;"failed to save partition: ",e];'e}];
  .merge.partsizes[base]+:(count r;-22!r);
  };

/ every table needs a directory in every partition. One holding trade but not quote
/ breaks a reader's load, and if it sorts first it silently truncates the table list.
vtfill:{[pt;expt]
  {[pt;expt;t]
    d:` sv .Q.par[savedir;pt;t],vtdirname[expt],`;
    if[()~key first ` vs d;
      .lg.o[`vtwrite;"creating empty ",(string t)," for new partition ",1_string d];
      d set .Q.en[hsym hdbdir; vtschema[t;.merge.getextrapartitiontype t]]];
    }[pt;expt] each tablelist[];
  };

/ notify readers about NEW partitions only; appends need none. Fill every table's directory
/ before notifying, or a reader can rebuild against a half-created partition. §4.1, §4.6
/ NOTE `pending` covers a tickerplant log replay, which never reaches this function -
/ replaymaxrowcheck calls savetables directly, so vtnew must not be cleared unconditionally.
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

/ end of day only announces the new date. Stock endofdaysort would merge the instrument
/ directories back into one table per date, which is the layout this design exists to avoid.
vteodsort:{[dir;pt;tablist;writedownmode;mergelimits;hdbsettings;mergemethod]
  .lg.o[`vtwrite;"no-merge eod - partition ",string[pt]," stays in place"];
  notifyidbs[`.vtidb.rollover;enlist pt+1];
  };

/ enumerate against this stack's own domain file - a reader binds a global named after the
/ file, so two stacks both calling it `sym cannot be served by one reader. §8.3.1
applysymdomain:{[]
  if[symdomain~`sym; :()];
  .lg.o[`vtwrite;"enumerating against `",string[symdomain]," instead of `sym"];
  .Q.en:{[dom;d;t] .Q.ens[d;t;dom]}[symdomain];
  };

/ the overrides must be installed before the tickerplant log is replayed, and addinitlist is
/ too late: wdb.q calls startup[] at the bottom of its own file. Wrapping startup works where
/ redefining anything wdb.q owns would not. §4.7
origstartup:startup;
startup:{[]
  applyvtwrite[];
  origstartup[]
  };

/ Swap everything in once the stock wdb.q has loaded. Still registered on the init list: the
/ wrapper above covers the replay path, this covers a writer that never subscribes. Idempotent.
applyvtwrite:{[]
  .lg.o[`vtwrite;"installing virtual-table capture overrides (4.1, 4.2, 4.5, 4.6)"];
  / one directory per writer, so hdbdir is always savedir. An override can move one without
  / the other, and hdbdir is where .Q.en writes the domain file.
  if[not hdbdir~savedir;
    .lg.o[`vtwrite;"hdbdir follows savedir: ",(string hdbdir)," -> ",string savedir];
    hdbdir::savedir];
  upserttopartition::vtupserttopartition;
  savetables::savetablesbypart[;;;;writedownmode];   / rebind: it closed over the old upsert
  savetodisk::vtsavetodisk;
  endofdaysort::vteodsort;
  applysymdomain[];
  };

\d .

.proc.addinitlist".wdb.applyvtwrite[]";
