/ Are the writer's overrides in force during tickerplant log replay? (§4.7)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./vt-env.sh && q testfiles/vt-replay-test.q
/ .
/ Restarting the writer is the normal recovery path. TorQ handles it by DELETING the current
/ partition and rebuilding it from the tickerplant log, the log being the source of truth for
/ the day in flight. That replay runs inside .wdb.startup[], called at the bottom of wdb.q -
/ about a second before .proc.init[] runs the init list.
/ .
/ So an overlay installed only from the init list is NOT in force during the replay, and every
/ partition it rebuilds is written by the stock writer, which keeps the partition column in the
/ files (4.5). The database then holds a mix of 7-column and 8-column directories: the
/ mismatched-column state of 9.3, which gives silently wrong answers rather than an error.
/ .
/ This checks the invariant directly, from the writer's own log and from the tree, rather than
/ by restarting anything - a test that kills processes by name matches its own caller's command
/ line and is not worth the trouble. To exercise it for real, restart wdb1 by hand while the
/ tickerplant log has data in it, then run this.
/ .
/ Reference numbers from the run that found this, before the fix: the overrides installed at
/ log line 3573 and the replay ran at line 185. After the fix: 171 and 184. The first check
/ below is exactly that comparison.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

db:getenv`KDBDB;
idbport:`$"::",string[30+"J"$getenv`KDBBASEPORT],":idb:pass";

h:@[hopen;idbport;{'"no reader on ",string[idbport],": ",x}];
pc:h".vtidb.partitioncol";

/ ---------------------------------------------------------------------------
/ 1. the ordering, from the writer's own log. this is the invariant: whatever else changes,
/    the overrides have to be installed before the first replay line
/ ---------------------------------------------------------------------------
logf:first system "ls -t ",getenv[`KDBLOG],"/out_wdb1_*.log 2>/dev/null";
if[not count logf; -1 "  no wdb1 log found - is the stack up?"; exit 1];
lines:read0 hsym`$logf;
inst:where lines like "*installing virtual-table capture overrides*";
rep :where lines like "*replaying the log file(s)*";

-1 "";
-1 "  writer log      ",logf;
-1 "  overrides at    ",.Q.s1 inst;
-1 "  replay at       ",.Q.s1 rep;
-1 "";

check[count inst; "the writer installs the capture overrides at all"];
check[$[count rep; (first inst)<first rep; 1b];
  $[count rep;
    "they are installed BEFORE the tickerplant log is replayed";
    "no replay in this log (empty tickerplant log) - ordering not exercised"]];

/ ---------------------------------------------------------------------------
/ 2. the consequence, from the tree. one table must never hold two column widths
/ ---------------------------------------------------------------------------
leaves:system "find ",db," -mindepth 3 -maxdepth 3 -type d";
if[not count leaves; -1 "  no partitions yet - let the stack capture for a few seconds"; exit 77];
ncols:{[d] count system "ls ",d," | grep -v '^\\.d$'"};
tabof:{[d] p:"/" vs d; `$p[-2+count p]};
/ tables legitimately differ in width - trade has 7 columns, quote 8 - so widths are compared
/ PER TABLE. one table holding two widths is the signature of the defect
widths:{[ncols;ds;idx] asc distinct ncols each ds idx}[ncols;leaves] each group tabof each leaves;

-1 "  partitions      ",string count leaves;
-1 "  widths by table ",.Q.s1 widths;
-1 "";

check[all 1=count each value widths;
  "each table has ONE column width across every partition"];
check[0=count system "find ",db," -mindepth 3 -maxdepth 3 -name '",string[pc],"'";
  "the partition column (",string[pc],") is in no file anywhere in the tree"];

/ and the reader can still answer, which the mismatch is what breaks
/ NOTE two arguments means the . form - @[f;x;handler] traps a MONADIC application only
r:.[{[h;t] count h "select from ",string t};(h;`trade);{`$"ERROR: ",x}];
check[-7h=type r; "the reader answers a query against the tree (",string[r]," rows)"];

/ ---------------------------------------------------------------------------
/ 3. 4.6's fill, on the recovery path.
/ .
/ Every instrument must have a directory under EVERY table, even an empty one. That is what
/ vtfill exists for: a date whose table directory is missing is served as silently absent.
/ .
/ A replay does not go through savetodisk at all - TorQ's replaymaxrowcheck calls
/ savetables[savedir;getpartition[];0b;t] directly, once per table - so vtfill never runs
/ during one. vtnew still fills correctly, and with EVERY directory, because deletewdbdata
/ wipes the partition first. It was then discarded by the vtnew::() at the top of the next
/ flush. The fix carries it across that boundary instead.
/ .
/ Checked from the tree rather than by restarting anything, so it holds whatever produced the
/ current state.
/ ---------------------------------------------------------------------------
seg:{[d] p:"/" vs d; (`$p[-3+count p]; `$p[-2+count p]; `$p[-1+count p])} each leaves;
tri:flip `date`tab`inst!flip seg;
bytab:0!select insts:asc distinct inst by date,tab from tri;
dates:asc distinct exec date from tri;

/ per date: what does the union of all tables have that this table lacks?
gaps:{[bytab;d]
  rows:select from bytab where date=d;
  every:asc distinct raze exec insts from rows;
  m:{[every;x] every except x}[every] each exec insts from rows;
  (exec tab from rows)!m
  }[bytab] each dates;

-1 "";
-1 "  instrument directories per date and table:";
{[bytab;d] -1 "    ",(string d),"  ",", " sv {[r] (string r`tab),"=",string count r`insts} each
  0!select from bytab where date=d}[bytab] each dates;

short:where 0<sum each {[g] count each g} each gaps;
if[count short;
  -1 "";
  {[dates;gaps;i]
    {[d;tb;m] if[count m; -1 "    ",(string d)," ",(string tb)," is missing ",
      (string count m)," instrument dir(s): ",.Q.s1 3 sublist m]}[dates i]'[key gaps i;value gaps i]
    }[dates;gaps] each short];
-1 "";

check[0=count short;
  "every instrument has a directory under every table, on every date (4.6's fill survives ",
  "the recovery path)"];

-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
hclose h;
exit $[fail>0;1;0]
