// Bespoke Feed config : Finance Starter Pack

// Every variable below has to be DECLARED here even though the process file sets it:
// .proc.override[] only overrides names that already exist, and silently ignores the rest.
// The universe itself lives in code/tick/feed.q; set `universe` below to change it.

\d .feed

// pin this feed to one tickerplant by name; ` publishes to whichever is found first. §8.3
tickerplantname:`

// which slice of the universe this feed publishes - stack i of n, disjoint by construction.
// 1 of 1 publishes the whole universe. §8.3
stackid:1
nstacks:1

\d .servers	
enabled:1b						
CONNECTIONS:enlist `segmentedtickerplant		// Feedhandler connects to the tickerplant
HOPENTIMEOUT:30000

\d .
