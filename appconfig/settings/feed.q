// Bespoke Feed config : Finance Starter Pack

// The instrument universe. A second capture stack (8.3.2) sets its own here - disjoint from
// this one, because the same (date;instrument) under two roots is served twice with no error.
// Starting prices follow the symbols automatically unless px is set to a matching-length list.
//
// \d .
// syms:`BARC`HSBA`LLOY`NWG`STAN`VOD`BP`SHEL`GSK`AZN

// 8.3.2 - pin this feed to ONE tickerplant, by name. ` publishes to whichever tickerplant is
// found first, which is right with one stack and a coin toss with two. Set it from the process
// file's extras column (-.feed.tickerplantname stp2); it has to be DECLARED here for that to
// work, because .proc.override[] only overrides variables that already exist.
\d .feed
tickerplantname:`

\d .servers	
enabled:1b						
CONNECTIONS:enlist `segmentedtickerplant		// Feedhandler connects to the tickerplant
HOPENTIMEOUT:30000

\d .
