/ Virtual-table capture pack : bind this writer to ONE named tickerplant. §8.3
/ Inert unless .wdb.tickerplantname is set.
/ wdb.q filters subscription handles on process type but never on name, so
/ .sub.getsubscriptionhandles is wrapped below to pass the name through.

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
  .lg.o[`vtwrite;"subscribing only to tickerplant `",string .wdb.tickerplantname];
  ];
