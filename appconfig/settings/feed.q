// Bespoke Feed config : Finance Starter Pack

// The instrument universe. A second capture stack (8.3.2) sets its own here - disjoint from
// this one, because the same (date;instrument) under two roots is served twice with no error.
// Starting prices follow the symbols automatically unless px is set to a matching-length list.
//
// \d .
// syms:`BARC`HSBA`LLOY`NWG`STAN`VOD`BP`SHEL`GSK`AZN

\d .servers	
enabled:1b						
CONNECTIONS:enlist `segmentedtickerplant		// Feedhandler connects to the tickerplant
HOPENTIMEOUT:30000

\d .
