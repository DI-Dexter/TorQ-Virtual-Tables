/ Does a new symbol VALUE reach the reader, and how fast? (§5.4)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./setenv.sh && q testfiles/vt-symdomain-test.q
/ .
/ Two different things travel at two different speeds, and conflating them hides a real gap.
/ .
/   rows appended to a directory the reader already holds are visible IMMEDIATELY, with no
/   rebuild and no notification - that is what the trailing-slash live view buys (5.2)
/ .
/   a symbol VALUE that has never been seen before is a different matter. it is an index into
/   the enumeration domain, and the reader holds that domain in memory. the writer appends the
/   new entry to the domain file, but creates no directory - so nothing is announced (4.1 is
/   edge-triggered on directories). until the reader reloads the domain, the rows are there but
/   that column reads as NULL. no error.
/ .
/ Before the domain got its own timer, the window was the 30s rebuild sweep. This checks it is
/ now bounded by the writer's flush interval instead.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

budget:0D00:00:05;                        / generous: flush interval + symsweep, both ~1s

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

idbport:`$"::",string[30+"J"$getenv`KDBBASEPORT],":idb:pass";
tpport:`$"::",getenv[`KDBBASEPORT],":feed:pass";
h:@[hopen;idbport;{'"no reader on ",string[idbport],": ",x}];
tp:@[hopen;tpport;{'"no tickerplant on ",string[tpport],": ",x}];

system "S ",string "i"$.z.t;              / every q process starts on the same seed
tabs:h"key .vtidb.parts";
if[not `trade in tabs; -1 "  no trade table yet - let the stack capture for a few seconds"; exit 1];
inst:first h"exec sym from .vtidb.parts`trade";
if[null inst; -1 "  no partitions yet"; exit 77];

pc:h".vtidb.partitioncol";
newside:`$"ZS","" sv string 5?.Q.A;       / a data symbol column value never seen before
rows:{[h;inst] h"count select from trade where sym=`",string inst};
sides:{[h;inst] (h"select distinct side from trade where sym=`",string inst)`side};

n0:rows[h;inst];
s0:h"count sym";

-1 "";
-1 "  existing partition : ",.Q.s1 inst;
/ NOTE the parentheses matter: .Q.s1 is unary, so ".Q.s1 x," y"" parses as .Q.s1 (x,"y")
-1 "  new value          : ",(.Q.s1 newside)," - a value in `side, a column INSIDE the files";
-1 "  rows / domain      : ",string[n0]," / ",string s0;
-1 "";

t0:.z.p;
do[3; tp(".u.upd";`trade;(enlist inst;enlist 99f;enlist 1i;enlist 0b;enlist " ";enlist "N";enlist newside))];

/ 1. the rows must arrive through the live view, with nothing told to the reader
arrived:{[rows;h;inst;n0;t0]
  $[n0<rows[h;inst]; .z.p-t0;
    0D00:00:10<.z.p-t0; 0Nn;
    [system"sleep 0.1"; .z.s[rows;h;inst;n0;t0]]]
  }[rows;h;inst;n0;t0];
check[not null arrived; "the appended rows arrive at all"];
if[not null arrived; -1 "         after ",string arrived];

/ 2. and the new value must resolve, within the budget
resolved:{[sides;h;inst;newside;t0;budget]
  $[newside in sides[h;inst]; .z.p-t0;
    budget<.z.p-t0; 0Nn;
    [system"sleep 0.1"; .z.s[sides;h;inst;newside;t0;budget]]]
  }[sides;h;inst;newside;t0;budget];

check[not null resolved;
  "the new symbol value resolves within ",string budget];
if[not null resolved; -1 "         after ",string resolved];
check[s0<h"count sym"; "the reader's enumeration domain grew"];

/ 3. and the partition column is never affected - it comes from the directory name
check[inst in h"exec ",string[pc]," from .vtidb.parts`trade";
  "the partition column is unaffected - it never goes through the domain"];

-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
hclose h; hclose tp;
exit $[fail>0;1;0]
