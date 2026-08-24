/ Is the stack actually capturing, and is the writer still subscribed? (§4.8)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./vt-env.sh && q testfiles/vt-tprestart-test.q
/ .
/ A liveness check, and the reason it exists is worth reading before you need it.
/ .
/ Restart the tickerplant and the stack does not fully recover on its own. Every process stays
/ up, the writer keeps logging "enumerated trade table" once a second, the reader answers
/ queries - and nothing new is captured, indefinitely. Measured: still stalled ten minutes
/ later, well past the five-minute .servers RETRY.
/ .
/ Two separate causes, one fixed and one not:
/ .
/   the feed cached its tickerplant handle at startup. a cached handle dies with the
/   tickerplant, and .servers reconnecting afterwards updates its own table, not a copy
/   somebody took at load time. FIXED - code/tick/feed.q now resolves the handle per publish
/ .
/   the writer does not re-subscribe. TorQ defines .wdb.notpconnected[] for exactly this
/   condition and then never calls it - the predicate exists, nothing invokes it. NOT FIXED:
/   re-subscribing also re-runs the partition delete-and-replay, so wiring it to a timer needs
/   more care than it looks. The operational answer is to restart the writer, which replays
/   the tickerplant log and loses nothing - verified, 435 rows to 2005 on restart
/ .
/ So: after a tickerplant restart, restart the writer. This test tells you whether you need to.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

window:0D00:00:08;                        / long enough for several 1s flushes

pass:0; fail:0;
check:{[ok;msg] $[ok; [pass+::1; -1 "  PASS  ",msg]; [fail+::1; -1 "  FAIL  ",msg]]; };

idbport:`$"::",string[30+"J"$getenv`KDBBASEPORT],":idb:pass";
wdbport:`$"::",string[5+"J"$getenv`KDBBASEPORT],":wdb:pass";
h:@[hopen;idbport;{'"no reader on ",string[idbport],": ",x}];
w:@[hopen;wdbport;{'"no writer on ",string[wdbport],": ",x}];

-1 "";

/ ---------------------------------------------------------------------------
/ 1. the writer's subscription.
/ NOTE not via .wdb.notpconnected[] - it reads `tickerplanttypes` unqualified, which only
/ resolves when the calling context is already .wdb, so over IPC it raises a value error.
/ .sub.SUBSCRIPTIONS is a root-namespace table and asks the same question safely.
nsub:.[{[w] w"count select from .sub.SUBSCRIPTIONS where active"};enlist w;{`$"ERROR: ",x}];
check[(-7h=type nsub) and nsub>0;
  "the writer holds an active tickerplant subscription (",(.Q.s1 nsub),")"];
if[not (-7h=type nsub) and nsub>0;
  -1 "         -> a tickerplant restart drops this and nothing re-establishes it.";
  -1 "            restart the writer; it replays the log and loses nothing."];

/ ---------------------------------------------------------------------------
/ 2. and the thing that actually matters: are rows arriving on disk?
/ NOTE the trailing ignored argument keeps this a FUNCTION - {[a;b]…}[x;y] is fully applied
/ and evaluates on the spot, so tot[] would hand back a cached number and measure nothing
tabs:h"key .vtidb.parts";
tot:{[h;tabs;i] sum {[h;t] h"count select from ",string t}[h] each tabs}[h;tabs];
a:tot 0;
system "sleep ",string `long$window%0D00:00:01;
b:tot 0;

-1 "";
-1 "  rows over ",(string window)," : ",(string a)," -> ",string b;
-1 "";
check[b>a; "the database is growing - the whole chain is live"];

/ ---------------------------------------------------------------------------
/ 3. the feed must not be holding a stale handle. it publishes through a lookup, not a
/    cached global, so a tickerplant restart cannot strand it
feedsrc:read0 hsym`$getenv[`KDBAPPCODE],"/tick/feed.q";
check[not any feedsrc like "h:.servers.gethandlebytype*";
  "the feed resolves its tickerplant handle per publish, not once at startup"];
check[any feedsrc like "*tphandle:*";
  "  - via tphandle[], so .servers reconnection is picked up automatically"];

-1 "";
-1 "  ",string[pass]," passed, ",string[fail]," failed";
-1 "";
hclose h; hclose w;
exit $[fail>0;1;0]
