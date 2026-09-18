/ Virtual-table capture pack : WDB overlay for a root shared by SEVERAL writers. Section 8.3.2
/ of docs/virtual-table-capture-pack.md. Everything here is inert unless .wdb.multiwriter is set.
/ .
/ THE PROBLEM. TorQ's clearwdbdata (code/processes/wdb.q) deletes .Q.par[savedir;partition;`] -
/ the WHOLE date directory - before replaying its own tickerplant log, then restores only its own
/ rows. With one capture stack that is correct. With two writers sharing a root it destroys the
/ other stack's data for that date, silently: measured at 579 rows lost, with every process in
/ both stacks staying up and logging nothing.
/ .
/ THE HOOK. clearwdbdata is called from inside wdb.q and defined in the same file, so there is
/ nothing to wrap. What there is: it deletes through .os.deldir, which common code defines long
/ before. This file loads after vtwrite.q and before wdb.q (measured 12ms apart), which is the
/ window in which .os.deldir can be wrapped.
/ .
/ OWNERSHIP. The writer records every instrument directory it writes into a manifest at
/ <savedir>/.vtowner/<procname>_<partition>. The name contains a dot, so the reader ignores it:
/ datedirs keeps only "[0-9][0-9][0-9][0-9].[0-9][0-9].[0-9][0-9]" and symfiles drops anything
/ matching "*.*". The set only grows when a directory is created, which is rare, so the file is
/ written on the flush that changed it and not otherwise.
/ .
/ WARNING the refusal below uses .lg.w, NOT .lg.e. TorQ's .lg.e calls `exit 3` when
/ .proc.initialised is false and .proc.trap is off, and all of this runs during load - so logging
/ the refusal as an error KILLS THE WRITER instead of letting it come up having declined to
/ delete. Measured: the writer exited silently on its first start under this override.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here carries
/ text after the slash.

\d .wdb

/ does another writer share this root? Off by default: with a single writer the stock full delete
/ is correct, and the manifest below is pure overhead.
multiwriter:@[value;`multiwriter;0b];

/ ---------------------------------------------------------------------------
/ the ownership manifest
/ ---------------------------------------------------------------------------
vtownerdir:{[] ` sv savedir,`$".vtowner"};
vtownerfile:{[pt] ` sv vtownerdir[],`$string[.proc.procname],"_",string pt};

vtowned:(`date$())!();                     / partition -> directory names this writer wrote
vtowneddirty:0b;
vtdeleted:0;

vtloadowned:{[]
  d:vtownerdir[];
  if[()~key d; :()];
  f:(key d) where (key d) like string[.proc.procname],"_*";
  {[d;x]
    pt:"D"$last "_" vs string x;
    if[not null pt; vtowned[pt]:distinct (vtowned pt),get ` sv d,x];
   }[d] each f;
  if[count f; .lg.o[`vtwrite;"loaded ownership manifest: ",.Q.s1 count each vtowned]];
 };

vtflushowned:{[]
  d:vtownerdir[];
  if[()~key d; .os.md 1_string d];
  {[pt] (vtownerfile pt) set vtowned pt} each key vtowned;
  vtowneddirty::0b;
 };

/ record every directory written. Wraps the pack's own upsert rather than replacing it, so 4.5
/ (strip the partition column) and 4.6 (record new directories) are untouched.
vtrecordupsert:{[dir;tablename;tabdata;pt;expttype;expt;writedownmode]
  n:vtdirname[expt];
  if[not pt in key vtowned; vtowned[pt]:0#`];
  if[not n in vtowned pt; vtowned[pt]:(vtowned pt),n; vtowneddirty::1b];
  vtorigupsert[dir;tablename;tabdata;pt;expttype;expt;writedownmode]
 };

vtsaveandflushowned:{[]
  vtorigsavetodisk[];
  if[vtowneddirty; vtflushowned[]];
 };

/ ---------------------------------------------------------------------------
/ the scoped delete
/ ---------------------------------------------------------------------------
vtnorm:{[p] $[(0<count p) and "/"=last p; -1_p; p]};    / one trailing slash, or none
vtpartstr:{[pt] 1_string .Q.par[savedir;pt;`]};

/ delete only the instrument directories named in this writer's manifest, under every table in
/ the partition. Anything another writer owns is left where it is.
vtscopeddelete:{[pt;p]
  f:vtownerfile pt;
  mine:$[()~key f; 0#`; get f];
  if[not count mine; :vtnomanifest[pt;p]];
  base:hsym`$vtnorm p;
  tabs:$[()~key base; 0#`; key base];
  tabs:tabs where not tabs like "*.*";
  {[base;mine;t]
    {[base;t;x]
      d:.Q.dd[.Q.dd[base;t];x];
      if[not ()~key d; vtorigdeldir 1_string d; vtdeleted+:1];
     }[base;t] each mine;
   }[base;mine] each tabs;
  .lg.o[`vtwrite;"scoped delete: removed ",string[vtdeleted]," directories for ",
                 string[count mine]," instruments across ",string[count tabs]," tables in ",p,
                 " - other writers untouched"];
 };

/ no manifest for this partition. If anyone else owns directories at this root, deleting the
/ whole thing would destroy their data, so decline: a duplicate replay of our own rows is
/ recoverable, another stack's deleted day is not.
vtnomanifest:{[pt;p]
  owners:$[()~key vtownerdir[]; 0#`; key vtownerdir[]];
  others:owners where not owners like string[.proc.procname],"_*";
  if[count others;
    .lg.w[`vtwrite;"REFUSING to delete ",p," - no ownership manifest for ",string[pt],
                   ", but ",string[count others]," other writer file(s) exist at this root"];
    :()];
  .lg.o[`vtwrite;"no manifest and no other writers at this root - stock full delete"];
  vtorigdeldir p
 };

\d .

/ ---------------------------------------------------------------------------
/ Installation. Nothing above has any effect until these assignments run, so a single-writer
/ stack behaves exactly as it did before this file existed.
/ .
/ The .os.deldir wrapper intercepts ONLY the exact partition-root delete that clearwdbdata
/ issues; every other caller - housekeeping, fixpartition's rename path - passes straight through.
/ ---------------------------------------------------------------------------
if[.wdb.multiwriter;
  .wdb.vtorigupsert:.wdb.vtupserttopartition;
  .wdb.vtupserttopartition:.wdb.vtrecordupsert;
  .wdb.vtorigsavetodisk:.wdb.vtsavetodisk;
  .wdb.vtsavetodisk:.wdb.vtsaveandflushowned;
  .wdb.vtorigdeldir:.os.deldir;
  .os.deldir:{[p]
    pt:@[.wdb.getpartition;(::);{[e] 0Nd}];
    if[null pt; :.wdb.vtorigdeldir p];
    if[not (.wdb.vtnorm p)~.wdb.vtnorm .wdb.vtpartstr pt; :.wdb.vtorigdeldir p];
    .wdb.vtdeleted:0;
    .wdb.vtscopeddelete[pt;p];
   };
  .wdb.vtloadowned[];                      / pick up a manifest a previous life left behind
  .lg.o[`vtwrite;"multi-writer mode: scoped pre-replay delete installed"];
 ];
