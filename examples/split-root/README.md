# Two capture stacks on separate roots

The arrangement to prefer when you want two stacks. Each writer owns its own tree, so a writer
restart cannot touch the other stack's data and nothing has to be coordinated between them.

Full detail and the measurements are in §8.3.3 of `docs/virtual-table-capture-pack.md`.
For two writers over ONE root, see `../multi-writer/` and §8.3.2 instead.

## What you need, and what you do not

| | separate roots |
|---|---|
| `.wdb.multiwriter` — scoped pre-replay delete | **not needed**, each writer is alone at its root |
| `.wdb.tickerplantname` — pin the writer to one tickerplant | **required** |
| `.feed.tickerplantname` — pin the feed | **required** |
| `.vtidb.multiwriter` — live-partition guard | **required**, if one reader serves both roots |
| `symdomain` — one enumeration domain per root | **required** |

Separating the roots removes the delete problem. It does **not** remove the rollover problem:
the reader holds one live partition across every root it serves, so the first stack to roll
still closes the date the other one is filling — in that stack's own tree.

## Setup

1. Copy the four settings files into `appconfig/settings/`, keeping their names, and replace
   `/path/to/data` with your database location.

   ```
   wdb1.q  wdb2.q      per-stack savedir + symdomain
   idb1.q  idb2.q      both roots, on both readers
   ```

   TorQ loads settings in the order `default -> parentproctype -> proctype -> procname`, so a
   file named after the process applies to that process alone. No code changes, no extra -load.

   These files have no equivalent in the shared-root setup, because there nothing varies per
   process: both writers want the same savedir and the same domain, and both readers the same
   root. A file named after the PROCESS is the only place two processes of the same proctype
   can be given different values, which is what separate roots requires and one root does not.

2. In your process file, pin each writer and feed to their own tickerplant and turn the reader
   guard on. Start from `appconfig/process-2stack.csv` and drop `-.wdb.multiwriter 1`:

   ```
   wdb1  ...  -.wdb.tickerplantname stp1
   feed1 ...  -.feed.tickerplantname stp1
   idb1  ...  -s 4 -.vtidb.multiwriter 1
   wdb2  ...  -.wdb.tickerplantname stp2
   feed2 ...  -.feed.tickerplantname stp2
   idb2  ...  -s 4 -.vtidb.multiwriter 1
   ```

3. Give the second stack a disjoint universe in `appconfig/settings/feed2.q` (`syms`).

4. Start both:

   ```sh
   VTSTACKS=2 ./deploy/bin/torq.sh start all
   ```

## Checking it worked

```sh
ls deploy/data/db1/      # 2026.09.23  syma
ls deploy/data/db2/      # 2026.09.23  symb
```

```q
h1:hopen`$"::6030:idb:pass"
h1".vtidb.roots"                                    / both roots
h1"count select from trade"                         / rows from both
h1"count select distinct sym from trade"            / both universes
h1"count syma"; h1"count symb"                      / both domains, no `sym` global
```

Restart one writer and watch the other stack keep climbing:

```sh
./deploy/bin/torq.sh stop wdb2 && ./deploy/bin/torq.sh start wdb2
```

## The one thing that behaves differently

Separate roots mean separate enumeration domains, so `` `syma$`Buy `` and `` `symb$`Buy `` are
distinct values. A cross-root grouping on a symbol column held inside the files gets one group
per domain:

```q
select rows:count i by side from trade          / 4 groups - one per domain
select rows:count i by value side from trade    / 2 - correct
```

Filtering, and grouping on the partition column, are unaffected. Those are the queries this
layout exists to serve.
