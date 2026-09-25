// Bespoke Feed config : Finance Starter Pack

// Every variable below has to be DECLARED here even though the process file is what sets
// it: .proc.override[] runs before process code loads, and only overrides names that
// already exist. A flag passed for a name that was never declared is silently ignored.
//
// The instrument universe itself lives in code/tick/feed.q; set `universe` below (inside
// \d .feed) to change it. Starting prices follow the symbols automatically unless px is set to a matching-length
// list.

\d .feed

// 8.3 - pin this feed to ONE tickerplant, by name. ` publishes to whichever tickerplant is
// found first, which is right with one stack and a coin toss with several.
tickerplantname:`

// 8.3 - which slice of the universe this feed publishes. Stack i of n takes every instrument
// whose index is congruent to i-1 mod n, so the slices are disjoint by construction. Left at
// 1 of 1 the feed publishes the whole universe, which is the single-stack case.
stackid:1
nstacks:1

\d .servers	
enabled:1b						
CONNECTIONS:enlist `segmentedtickerplant		// Feedhandler connects to the tickerplant
HOPENTIMEOUT:30000

\d .
