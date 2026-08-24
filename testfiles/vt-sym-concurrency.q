/ Is one enumeration domain safe for several concurrent writers? (§8.3.1, VT-16)
/ .
/     cd ~/TorQ-VT-Capture-Pack && . ./vt-env.sh && q testfiles/vt-sym-concurrency.q
/ .
/ Sharing one domain across capture stacks was rejected in an earlier draft partly on the
/ grounds that two writers appending to one sym file risk corrupting it. That deserved
/ measuring rather than asserting, because it is the difference between "a deployment choice"
/ and "a thing you must not do".
/ .
/ The enumeration primitive is `path?syms` on a FILE HANDLE, which is what .Q.en calls. This
/ runs several processes through it against one file, on an overlapping vocabulary, and checks
/ the two things that would break a database: a domain that gained duplicates, and an index
/ handed to a writer that no longer resolves to the symbol it was given for - which would mean
/ column files already on disk are now wrong.
/ .
/ NOTE a line containing only "/" opens a block comment in q, so every comment line here
/ carries text after the slash.

writers:6;
rounds:300;

d:"/tmp/vt-symconc-",string .z.i;
system"rm -rf ",d; system"mkdir -p ",d;
sp:d,"/sym";
(hsym`$sp) set 0#`;

/ the child, written out rather than shipped separately so this stays one file
child:d,"/child.q";
(hsym`$child) 0: (
  "p:hsym`$getenv`SYMPATH;";
  "id:\"J\"$getenv`WID;";
  "rounds:\"J\"$getenv`ROUNDS;";
  "system \"S \",string 1000+id;              / every q process starts on the same seed";
  "vocab:`$\"S\",/:string til 400;            / shared with every other writer";
  "mine:`$\"W\",string[id],\"_\",/:string til 100;";
  "seen:()!();";
  "{[p;vocab;mine;i]";
  "  s:(neg[40]?vocab),neg[10]?mine;";
  "  seen[s]::p?s;                            / the enumeration primitive .Q.en uses";
  "  }[p;vocab;mine] each til rounds;";
  "(hsym`$getenv[`OUTPATH]) set seen;";
  "exit 0");

-1 "";
-1 "  ",string[writers]," concurrent writers x ",string[rounds]," enumeration calls, one shared domain file";

{[sp;d;rounds;child;i]
  system"SYMPATH=",sp," WID=",string[i]," ROUNDS=",string[rounds],
        " OUTPATH=",d,"/out",string[i]," q ",child," </dev/null >",d,"/log",string[i]," 2>&1 &"
  }[sp;d;rounds;child] each til writers;

/ wait for every child to land its result
wait:{[d;n] $[n=count key[hsym`$d] where key[hsym`$d] like "out*"; ::; [system"sleep 0.3"; .z.s[d;n]]]};
wait[d;writers];
system"sleep 0.5";

final:get hsym`$sp;
outs:{[d;i] get hsym`$d,"/out",string i}[d] each til writers;
pairs:(!/)(raze key each outs; raze value each outs);
dups:count[final]-count distinct final;
bad:where not final[value pairs]=key pairs;

-1 "";
-1 "  final domain size    ",string count final;
-1 "  duplicate entries    ",string dups;
-1 "  indices handed out   ",string count pairs;
-1 "  now resolving WRONG  ",string count bad;
if[count bad; -1 "  e.g. ",.Q.s1 3#key[pairs] bad];
-1 "";
-1 $[(0=dups) and 0=count bad;
     "  SAFE - the primitive locks. every index still resolves to the symbol it was issued for.";
     "  UNSAFE - the file lost or reordered entries under concurrency."];
-1 "";
-1 "  what this does NOT say: two stacks can only share a domain if they share one PHYSICAL";
-1 "  file (shared storage, symlinked into each root). two copies diverge on the first new";
-1 "  symbol either stack sees, and that is the silently-wrong configuration. see 8.3.1.";
-1 "";
system"rm -rf ",d;
exit $[(0=dups) and 0=count bad; 0; 1]
