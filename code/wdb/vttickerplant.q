/ Virtual-table capture pack : bind this writer to ONE named tickerplant (8.3).
/ Inert unless .wdb.tickerplantname is set.
/ .
/ wdb.q subscribes with a filter on process TYPE and none on NAME, then takes the first row.
/ With one tickerplant that is unambiguous; with several it depends on the order
/ .servers.SERVERS happens to be in, and a writer on the wrong one captures the other stack's
/ instruments while looking healthy.
/ .
/ .sub.getsubscriptionhandles already accepts a procname filter that wdb.q never passes, so it
/ is wrapped below. It has to be wrapped here rather than from .proc.initlist, because wdb.q
/ calls startup[] at the bottom of its own file, before the init list runs.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here carries
/ text after the slash.

\d .wdb

/ which tickerplant this writer belongs to. ` = whichever one is found first
tickerplantname:@[value;`tickerplantname;`];

/ Inject the name only when the caller asked for a tickerplant and left the name open.
/ tickerplanttypes is read at call time because wdb.q defines it after this file loads.
vtpintickerplant:{[nm;proctype;procname;attributes]
  tpt:(),@[value;`.wdb.tickerplanttypes;`];
  if[(all null (),procname) and count tpt inter (),proctype; procname:nm];
  vtorigsubhandles[proctype;procname;attributes]
  };

\d .

if[not null .wdb.tickerplantname;
  .wdb.vtorigsubhandles:.sub.getsubscriptionhandles;
  .sub.getsubscriptionhandles:.wdb.vtpintickerplant[.wdb.tickerplantname];
  .lg.o[`vtwrite;"subscribing only to tickerplant `",string[.wdb.tickerplantname]," (8.3)"];
  ];
