/ VT-11 prep: build two databases holding IDENTICAL data.
/   1. vtdb  - the new format: date/table/instrument dirs, partition column stripped
/   2. hdb   - conventional kdb+: date-partitioned splay, sym as a real column
/ Both are derived from the same captured bytes, so any query difference is the access path.

live:getenv`KDBDB;
scratch:getenv`SCRATCH;
vtdb:scratch,"/vtdb";
hdb :scratch,"/hdb";

system"rm -rf ",vtdb," ",hdb;
system"mkdir -p ",vtdb," ",hdb;

/ two dates, so cross-date queries are exercised. both are copies of the same captured day,
/ which is fine: both databases receive the identical duplication.
src:first asc key[hsym`$live] where key[hsym`$live] like "[0-9][0-9][0-9][0-9].*";
system"cp ",live,"/sym ",vtdb,"/";
system"cp -r ",live,"/",(string src)," ",vtdb,"/2026.01.01";
system"cp -r ",live,"/",(string src)," ",vtdb,"/2026.01.02";
-1 "vt-format database : ",vtdb;

/ ---- build the conventional control from the same files ----
load .Q.dd[hsym`$vtdb;`sym];

/ read one partition directory and put the partition columns BACK as real columns,
/ which is what a conventional layout would have stored in the first place
/ WARNING the instrument parameter must NOT be called "i" - inside q-sql, i is the row
/ index, so "sym:i" silently stores row numbers instead of the instrument
readpart:{[r;d;t;inst]
  x:select from get .Q.dd[.Q.dd[.Q.dd[r;d];t];inst];   / select forces an in-memory copy
  dd:"D"$string d;
  update date:dd, sym:inst from x
  };

vh:hsym`$vtdb;
dates:asc key[vh] where key[vh] like "[0-9][0-9][0-9][0-9].*";

gather:{[vh;t;dates]
  raze raze {[vh;t;d] readpart[vh;d;t] each key .Q.dd[.Q.dd[vh;d];t]}[vh;t] each dates
  };

tradeall:gather[vh;`trade;dates];
quoteall:gather[vh;`quote;dates];
-1 "control rows       : trade ",(string count tradeall),", quote ",string count quoteall;

/ ---- write it out as a conventional date-partitioned database ----
/ Use ONE shared enumeration domain: copy the vt database's sym file, then enumerate the
/ rebuilt sym column against that same in-memory domain. Letting .Q.en manage it
/ produced column files whose indices did not match the sym file that was written, so
/ symbol columns resolved to the wrong labels.
hh:hsym`$hdb;
system"cp ",vtdb,"/sym ",hdb,"/";

tradeall:update sym:`sym$sym from tradeall;
quoteall:$[count quoteall; update sym:`sym$sym from quoteall; quoteall];

{[hh;t;data]
  {[hh;t;d;data]
    .Q.dd[.Q.dd[.Q.dd[hh;`$string d];t];`] set delete date from select from data where date=d;
    }[hh;t;;data] each asc distinct data`date;
  }[hh;;] . ' ((`trade;tradeall);(`quote;quoteall));

-1 "conventional hdb   : ",hdb;
-1 "sym written        : ",string count key hh;
-1 "hdb partitions     : ",.Q.s1 key hh;
exit 0
