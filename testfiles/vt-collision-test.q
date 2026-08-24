/ What happens when two instrument names sanitise to the same directory? (§2.3)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./vt-env.sh && q testfiles/vt-collision-test.q
/ .
/ The writer builds a directory name by replacing every non-alphanumeric character with "_".
/ That mapping is NOT injective: BRK-B and BRK_B both become BRK_B. The design has always
/ noted this, describing the result as rows "interleaving". Measured, it is considerably worse
/ than interleaving, and this test pins the actual behaviour so it cannot be forgotten:
/ .
/   one instrument becomes completely unqueryable - its rows are on disk, under the other
/   instrument's name, and a query naming it returns zero
/ .
/   the other silently ABSORBS those rows - a query naming it returns more rows than were
/   ever published for it
/ .
/ Neither produces an error. A universe of plain uppercase tickers never trips this; anything
/ containing . - or / does. If yours can, hash or escape the value before it reaches the
/ partition column.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

idbport:`$"::",string[30+"J"$getenv`KDBBASEPORT],":idb:pass";
tpport:`$"::",getenv[`KDBBASEPORT],":feed:pass";
h:@[hopen;idbport;{'"no reader on ",string[idbport],": ",x}];
tp:@[hopen;tpport;{'"no tickerplant on ",string[tpport],": ",x}];

system "S ",string "i"$.z.t;
tag:"" sv string 4?.Q.A;
a:`$"ZZ-",tag;                            / differ only in a character the sanitiser destroys
b:`$"ZZ_",tag;
na:4; nb:6;
dirname:"ZZ_",tag;

cnt:{[h;s] h "count select from trade where sym=`$\"",string[s],"\""};

-1 "";
-1 "  publishing ",string[na]," rows for ",(.Q.s1 a)," and ",string[nb]," for ",.Q.s1 b;
do[na; tp(".u.upd";`trade;(enlist a;enlist 11f;enlist 1i;enlist 0b;enlist " ";enlist "N";enlist`buy))];
do[nb; tp(".u.upd";`trade;(enlist b;enlist 22f;enlist 2i;enlist 0b;enlist " ";enlist "N";enlist`sell))];
system "sleep 4";

dirs:key hsym`$getenv[`KDBDB],"/",string[h".vtidb.current"],"/trade";
made:dirs where dirs in (`$dirname;a;b);

-1 "";
-1 "  directories created : ",.Q.s1 made;
-1 "  rows for ",(.Q.s1 a),"    : ",.Q.s1 cnt[h;a];
-1 "  rows for ",(.Q.s1 b),"    : ",.Q.s1 cnt[h;b];
-1 "";

check[1=count made;
  "the two instruments collapsed into ONE directory (",(.Q.s1 made),")"];
check[0=cnt[h;a];
  "the hyphenated name is now completely unqueryable - ",string[na]," rows published, 0 returned"];
check[(na+nb)=cnt[h;b];
  "the surviving name absorbed them - ",string[nb]," published, ",string[cnt[h;b]]," returned"];

/ the rows are not lost, they are mislabelled - which is what makes it silent
p:first h "exec path from .vtidb.parts[`trade] where sym=`$\"",dirname,"\"";
check[not null p; "the merged directory is in the catalogue under the sanitised name"];

-1 "";
-1 "  Both answers are wrong and neither errors. This is the one failure mode in the design";
-1 "  that the writer cannot detect on its own: by the time it has a directory name, the";
-1 "  character that distinguished the two instruments is gone.";
-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
hclose h; hclose tp;
exit $[fail>0;1;0]
