/ Virtual-table capture pack : bind this writer to ONE named tickerplant. Section 8.3.2 of
/ docs/virtual-table-capture-pack.md. Inert unless .wdb.tickerplantname is set.
/ .
/ THE PROBLEM. wdb.q subscribes with
/ .
/   s:.sub.getsubscriptionhandles[tickerplanttypes;();()!()];
/   subproc:first s
/ .
/ - a filter on process TYPE and none on process NAME, and then the FIRST row of whatever comes
/ back. With one capture stack that is correct: there is one tickerplant, so the choice is not a
/ choice. With two stacks in one process file there are two, and which one a writer lands on
/ depends on the order .servers.SERVERS happens to be in.
/ .
/ A writer that binds to the wrong tickerplant is silent. It subscribes, it captures, it writes,
/ every process stays up and nothing is logged - it is simply writing the OTHER stack's
/ instruments. Measured while building this: wdb2 captured stack 1's data and the reader served
/ every row twice. Checking the directory names per stack is the quickest way to see it.
/ .
/ THE HOOK. .sub.getsubscriptionhandles already takes a procname filter; wdb.q just never passes
/ one. .sub is common code, loaded before $KDBAPPCODE/wdb/, so it can be wrapped here - and it
/ must be wrapped HERE rather than from .proc.initlist, because wdb.q calls startup[] at the
/ bottom of its own file, long before the init list runs.
/ .
/ NOTE .wdb.tickerplantname is declared in appconfig/settings/wdb.q, not below, so that TorQ's
/ command-line override can reach it: .proc.override[] runs before process code is loaded and
/ only overrides variables that ALREADY EXIST. That is what lets the process file say
/ "-.wdb.tickerplantname stp2" in its extras column.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here carries
/ text after the slash.

\d .wdb

/ which tickerplant this writer belongs to. ` = whichever one is found first
tickerplantname:@[value;`tickerplantname;`];

/ Inject the name only when the caller asked for a tickerplant and left the name open. A caller
/ that named a process already knows what it wants, and a lookup for any other process type is
/ none of our business.
/ .
/ .wdb.tickerplanttypes is read through value at CALL time: wdb.q defines it after this file
/ loads, and the trap covers a call that somehow arrives before it does.
vtpintickerplant:{[nm;proctype;procname;attributes]
  tpt:(),@[value;`.wdb.tickerplanttypes;`];
  if[(all null (),procname) and count tpt inter (),proctype; procname:nm];
  vtorigsubhandles[proctype;procname;attributes]
  };

\d .

if[not null .wdb.tickerplantname;
  .wdb.vtorigsubhandles:.sub.getsubscriptionhandles;
  .sub.getsubscriptionhandles:.wdb.vtpintickerplant[.wdb.tickerplantname];
  .lg.o[`vtwrite;"subscribing only to tickerplant `",string[.wdb.tickerplantname]," (8.3.2)"];
  ];
