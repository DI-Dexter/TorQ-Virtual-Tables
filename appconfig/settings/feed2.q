// Virtual-table capture pack : the SECOND capture stack's feed (doc 8.3.2).
//
// Loaded only for procname feed2, which exists only in appconfig/process-2stack.csv - so this
// file is inert in the single-stack topology the pack ships with.
//
// The universes of two stacks writing into one root MUST be disjoint. The same
// (date;instrument) written under one root by two writers is served TWICE, with no error and
// nothing in any log (8.3.1) - the reader builds cleanly and every query double-counts.
//
// NOTE the leading \d . is load-bearing. Settings files are loaded into one session in order,
// and appconfig/settings/feed.q ends inside \d ., but a file that ended inside another namespace
// would leave this one there too - which is how a flag lands in .proc and does nothing.

\d .

syms:`BARC`HSBA`LLOY`NWG`STAN`VOD`BP`SHEL`GSK`AZN
