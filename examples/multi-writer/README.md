# Two capture stacks over one database

Worked example for §8.3.2 of [the design doc](../../docs/virtual-table-capture-pack.md). The
pack ships a single stack; this is what changes when a second writer shares the root.

**Prefer separate roots.** `.vtidb.roots` is a list, so one reader can serve two trees written by
two independent stacks (§8.3), and nothing below is needed. Share a root only when the stacks
must write into one database.

**If you just want two stacks running, use `VTSTACKS=2`.**

```sh
VTSTACKS=2 ./deploy/bin/torq.sh start all
```

That starts both from one process file — `appconfig/process-2stack.csv`, ports derived from
`{KDBBASEPORT}` with `+100` for stack 2 — and needs no config of your own. It can do that because
each writer is pinned to its tickerplant by name (`.wdb.tickerplantname`), which is what the two
separate process files below exist to avoid needing.

What follows is the other arrangement: two stacks that do not know about each other at all, each
with its own config tree. Use it when the stacks are genuinely independent — different owners,
different machines, different release cadences — rather than two halves of one deployment.

## The files

`process-stack1.csv` and `process-stack2.csv` differ in three ways, all of which matter:

- each lists **only its own tickerplant** — the writer picks one with
  `gethandlebytype[...;`any]`, so a combined file lets a writer subscribe to the wrong stack,
  unless every writer is pinned by name as `process-2stack.csv` does it;
- each lists **every writer and every reader**, so a reader can ask all writers which partition
  they are filling, and a writer can notify all readers;
- `startwithall` is `1` only for that stack's own processes.

Ports are hardcoded rather than derived from `{KDBBASEPORT}`, since the two stacks sit at
different bases (6000 and 6100) and one file describes both.

## Settings each stack needs

```q
// appconfig/settings/wdb.q   - on EVERY writer sharing the root
multiwriter:1b                 // scope the pre-replay delete to this writer's instruments

// appconfig/settings/idb.q   - on every reader serving more than one writer's data
multiwriter:1b                 // hold the live partition at the earliest still-open date

// appconfig/settings/default.q - on the SECOND stack
\d .servers
CONNECTIONSFROMDISCOVERY:0b    // or it learns stack 1's tickerplant from the shared discovery

// appconfig/settings/feed.q  - on the second stack, disjoint from the first
\d .
syms:`BARC`HSBA`LLOY`NWG`STAN`VOD`BP`SHEL`GSK`AZN
```

The instrument universes **must** be disjoint: the same `(date;instrument)` under two roots is
served twice, with no error (§8.3.1).

## Running it

Stack 1 is the pack as shipped, pointed at the example process file. `TORQPROCESSES` has to be
set **inside** the file named by `SETENV`, not in the environment: `torq.sh` sources `SETENV`
after your shell, so `setenv.sh` overwrites an exported value.

```sh
cat > stack1-env.sh <<'END'
. /path/to/pack/setenv.sh
export TORQPROCESSES=/path/to/pack/examples/multi-writer/process-stack1.csv
END

SETENV=$PWD/stack1-env.sh $TORQHOME/torq.sh start all
```

Stack 2 needs its own `appconfig`, its own `KDBTPLOG`, and its own log and data directories, with
`KDBDB` pointing at the shared root. Start it with its own process file the same way.

## What to check once both are up

```q
q)h:hopen `:localhost:6105:admin:admin        / writer 2
q)h"string .wdb.savedir"                       / the shared root
q)h".u.x"                                      / the tickerplant it subscribed to - must be stp2
```

A writer that subscribed to the wrong tickerplant looks perfectly healthy: it captures, it
writes, and both roots quietly fill with the same instruments while the reader serves every row
twice. Checking the instrument names per root is the quickest way to see it:

```sh
ls <root>/<date>/trade/
```
