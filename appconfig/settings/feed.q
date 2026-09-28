// Bespoke Feed config : Finance Starter Pack

// Every variable below has to be DECLARED here even though the process file is what sets
// it: .proc.override[] runs before process code loads, and only overrides names that
// already exist. A flag passed for a name that was never declared is silently ignored.
//
// The instrument universe itself lives in code/tick/feed.q; set `universe` below (inside
// \d .feed) to change it. Starting prices follow the symbols automatically unless px is set to a matching-length
// list.

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
