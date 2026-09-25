#!/bin/bash
# Environment for the TorQ Virtual-Table Capture Pack, in TorQ's setenv.sh format.
#
# torq.sh sources this through the SETENV variable, so pass SETENV=<this file> when
# calling it. Sourcing it by hand is also how the test files expect to be run.
#
# This is an application overlay: it supplies config and code that layer on top of a
# TorQ checkout, which supplies the framework and process code.
#
# Only TORQHOME below should ever need editing. Everything else derives from it and
# from the location of this file, so the pack can be cloned anywhere.

# --- inside an installed tree ------------------------------------------------
# installlatest.sh lays the pack out as deploy/TorQApp/<version>/<pack>/ and writes the real
# paths into deploy/bin/setenv.sh, a copy of this file. This copy is never rewritten, so a script
# run from the installed pack - selftest.sh, regress.sh, compress.sh - would get an empty TorQ
# location and a var/ database that nothing writes to. Defer to the rewritten copy instead.
# The depth is checked exactly, and deploy/bin/torq.sh must sit beside it, so a clone that
# merely lives under a directory called TorQApp is left alone.
_vtphys="$(cd -P "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd)"
case "${_vtphys#*/TorQApp/}" in
  "$_vtphys"|*/*/*) ;;                                  # not under TorQApp, or too deep
  */*)
    _vtroot="${_vtphys%/TorQApp/*}"
    if [ -z "${_VTDELEGATED:-}" ] && [ -f "$_vtroot/bin/setenv.sh" ] && [ -f "$_vtroot/bin/torq.sh" ]; then
      _VTDELEGATED=1
      . "$_vtroot/bin/setenv.sh"
      unset _VTDELEGATED _vtphys _vtroot
      return 0 2>/dev/null || exit 0
    fi
    ;;
esac
unset _vtphys _vtroot

# --- the two roots -----------------------------------------------------------
# TorQ core: the checkout that contains torq.q, code/ and config/. There is no sensible
# default, so either export TORQHOME before sourcing this file or fill in the path below.
# compress.sh checks it and stops with a clear message if it is wrong.
export TORQHOME="${TORQHOME:-}"

# warn when sourced by hand - the test headers say ". ./setenv.sh && q testfiles/<x>.q", and
# without this an unset TORQHOME turns KDBCODE into "/code" and the failure is a load error
# deep inside a test rather than anything pointing back here.
if [ ! -f "${TORQHOME}/torq.q" ]; then
  echo "setenv.sh: WARNING - no torq.q under TORQHOME=${TORQHOME:-<unset>}" >&2
  echo "setenv.sh:           set TORQHOME to your TorQ checkout, or edit this file" >&2
fi

# this pack, resolved from the location of this script - never hardcode it
if [ -n "${BASH_SOURCE[0]}" ]; then
  _VTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
  _VTDIR="$(cd "$(dirname "$0")" && pwd)"
fi
export TORQAPPHOME="${_VTDIR}"
export TORQDATAHOME="${TORQDATAHOME:-${_VTDIR}/var}"     # runtime state; data/ holds the feed's sample csv

# --- TorQ core ---------------------------------------------------------------
export KDBCONFIG="${TORQHOME}/config"
export KDBCODE="${TORQHOME}/code"
export KDBLIB="${TORQHOME}/lib"
export KDBHTML="${TORQHOME}/html"

# --- this pack ---------------------------------------------------------------
export KDBAPPCONFIG="${TORQAPPHOME}/appconfig"
export KDBAPPCODE="${TORQAPPHOME}/code"

# --- topology ----------------------------------------------------------------
# VTSTACKS  how many capture stacks. Each is a tickerplant + feed + writer, and each writes
#           into its OWN database root - so two writers never share a partition to delete,
#           and never compete for the same disk. 1 (the default) is the pack as described
#           everywhere else.
# VTIDBS    how many readers. Each reader attaches EVERY root, so any one of them answers
#           for the whole estate. Readers are interchangeable; add them for query capacity.
#
#   VTSTACKS=2 ./deploy/bin/torq.sh start all               # two stacks, one reader
#   VTSTACKS=3 VTIDBS=2 ./deploy/bin/torq.sh start all      # three stacks, two readers
#
# Both are REMEMBERED, in $TORQDATAHOME. Set them once when starting and later calls need
# nothing - which matters because torq.sh only knows about the processes in the file this
# picks, so a `stop all` that forgot would leave processes running and unmanaged.
#
# Anything other than 1x1 is GENERATED into $TORQDATAHOME/process-generated.csv. The shipped
# appconfig/process.csv is used unchanged for the 1x1 case, so the default deployment does
# not depend on the generator at all.
#
# PORTS, from KDBBASEPORT: stack i occupies the block at +100*(i-1) - tickerplant at +0,
# writer at +5, feed at +14 - and reader j sits at +30 of block j. discovery is at +1 and
# the compression process at +40, both in block 1.
_vtsfile="${TORQDATAHOME}/.vtstacks"
_vtifile="${TORQDATAHOME}/.vtidbs"
if [ -z "${VTSTACKS:-}" ] && [ -r "$_vtsfile" ]; then VTSTACKS="$(cat "$_vtsfile" 2>/dev/null)"; fi
if [ -z "${VTIDBS:-}"   ] && [ -r "$_vtifile" ]; then VTIDBS="$(cat "$_vtifile" 2>/dev/null)"; fi
VTSTACKS="${VTSTACKS:-1}"
VTIDBS="${VTIDBS:-1}"
case "$VTSTACKS" in ''|*[!0-9]*|0) echo "setenv.sh: WARNING - VTSTACKS='${VTSTACKS}' is not a positive integer, using 1" >&2; VTSTACKS=1 ;; esac
case "$VTIDBS"   in ''|*[!0-9]*|0) echo "setenv.sh: WARNING - VTIDBS='${VTIDBS}' is not a positive integer, using 1" >&2;   VTIDBS=1 ;; esac
export VTSTACKS VTIDBS

# CONNECTION BUDGET. A reader holds roughly 3 sockets per capture stack - two outbound to each
# writer (one from .servers, one for the live-partition poll) and one inbound as that writer
# registers - plus one to discovery. A licence that caps concurrent connections therefore caps
# the topology: past the cap a reader stays up, keeps capturing, and refuses every hopen with
# 'conn, which reads like the process being down when it is anything but.
#
# The cap is read from the licence rather than assumed, because it differs by licence and
# .Q.lim[] has two shapes - a plain dictionary where conns is a number, and a keyed table with
# cur and lim columns where it is a row. An unlimited licence reports 0W and says nothing.
if [ "$VTSTACKS" -ge 3 ] && command -v "${QCMD:-q}" >/dev/null 2>&1; then
  _vtneed=$(( 3 * VTSTACKS + 1 ))
  _vtcap=$("${QCMD:-q}" -q 2>/dev/null <<'VTLIMEOF'
v:.Q.lim[]`conns;
-1 string $[-7h=type v; v; v`lim];
exit 0;
VTLIMEOF
)
  case "$_vtcap" in
    ''|*[!0-9]*) : ;;                         # 0W, or q unavailable - no cap to warn about
    *) if [ "$_vtcap" -lt "$_vtneed" ]; then
         echo "setenv.sh: WARNING - VTSTACKS=${VTSTACKS} needs ~${_vtneed} connections per reader, but this" >&2
         echo "setenv.sh:           licence caps a process at ${_vtcap}. Readers will keep capturing and" >&2
         echo "setenv.sh:           refuse client connections with 'conn. Reduce VTSTACKS, or use a" >&2
         echo "setenv.sh:           licence without a connection cap." >&2
       fi ;;
  esac
  unset _vtneed _vtcap
fi

# the root a stack writes into, and the enumeration domain it enumerates against. With one
# stack both are the stock defaults, so a single-stack tree is byte-for-byte what Part 1 laid
# down. With several, each gets its own - two roots sharing a domain NAME cannot be read
# together, because the reader binds a global named after the file (8.3.1).
vtroot   () { if [ "$VTSTACKS" -gt 1 ]; then echo "${TORQDATAHOME}/db$1"; else echo "${TORQDATAHOME}/db"; fi; }
vtdomain () { if [ "$VTSTACKS" -gt 1 ]; then echo "sym$1"; else echo "sym"; fi; }
vtport   () { if [ "$1" = 0 ]; then echo "{KDBBASEPORT}"; else echo "{KDBBASEPORT}+$1"; fi; }

vtgenprocesses () {
  _acl="${TORQAPPHOME}/appconfig/passwords/accesslist.txt"
  _roots=""
  _i=1; while [ "$_i" -le "$VTSTACKS" ]; do _roots="${_roots} :$(vtroot $_i)"; _i=$((_i+1)); done

  echo "host,port,proctype,procname,U,localtime,g,T,w,load,startwithall,extras,qcmd"
  echo "localhost,$(vtport 1),discovery,discovery1,${_acl},1,0,,,${KDBCODE}/processes/discovery.q,1,,q"

  _i=1
  while [ "$_i" -le "$VTSTACKS" ]; do
    _off=$(( 100 * (_i - 1) ))
    # the tickerplant pin is on both writer and feed, and is NOT optional with several
    # stacks: a lookup by process type takes whichever is found first, so a writer can bind
    # to another stack's tickerplant and capture its instruments while looking healthy.
    _wx="-.wdb.tickerplantname stp${_i}"
    _fx="-.feed.tickerplantname stp${_i}"
    if [ "$VTSTACKS" -gt 1 ]; then
      # savedir AND hdbdir together - hdbdir is what .Q.en writes the enumeration file to,
      # so overriding savedir alone puts every domain in the default directory and the
      # readers hand back raw enumeration indices instead of symbols, silently.
      _r="$(vtroot $_i)"
      _wx="${_wx} -.wdb.savedir :${_r} -.wdb.hdbdir :${_r} -.wdb.symdomain $(vtdomain $_i)"
      _fx="${_fx} -.feed.stackid ${_i} -.feed.nstacks ${VTSTACKS}"
    fi
    echo "localhost,$(vtport $_off),segmentedtickerplant,stp${_i},${_acl},1,0,,,${KDBCODE}/processes/segmentedtickerplant.q,1,-schemafile ${TORQAPPHOME}/database.q -tplogdir ${TORQDATAHOME}/tplogs,q"
    echo "localhost,$(vtport $((_off+5))),wdb,wdb${_i},${_acl},1,1,,,${KDBCODE}/processes/wdb.q,1,${_wx},q"
    echo "localhost,$(vtport $((_off+14))),feed,feed${_i},,1,0,,,${TORQAPPHOME}/code/tick/feed.q,1,${_fx},q"
    _i=$((_i+1))
  done

  _j=1
  while [ "$_j" -le "$VTIDBS" ]; do
    _off=$(( 100 * (_j - 1) + 30 ))
    # every reader attaches every root. .vtidb.multiwriter is required whenever there is
    # more than one writer, INCLUDING with separate roots: a reader holds ONE live partition
    # across all the roots it serves, so the first stack to roll would otherwise close a date
    # another stack is still filling, and every directory it creates after that is invisible.
    _ix="-s 4"
    if [ "$VTSTACKS" -gt 1 ]; then _ix="${_ix} -.vtidb.multiwriter 1 -.vtidb.roots${_roots}"; fi
    echo "localhost,$(vtport $_off),idb,idb${_j},${_acl},1,1,60,4000,${TORQAPPHOME}/code/processes/vtidb.q,1,${_ix},q"
    _j=$((_j+1))
  done

  echo "localhost,$(vtport 40),compression,cmp1,${_acl},1,0,,,${TORQAPPHOME}/code/processes/vtcompress.q,0,,q"
}

mkdir -p "${TORQDATAHOME}" 2>/dev/null || true
printf '%s\n' "$VTSTACKS" > "$_vtsfile" 2>/dev/null || true
printf '%s\n' "$VTIDBS"   > "$_vtifile" 2>/dev/null || true

if [ "$VTSTACKS" = 1 ] && [ "$VTIDBS" = 1 ]; then
  export TORQPROCESSES="${KDBAPPCONFIG}/process.csv"
else
  export TORQPROCESSES="${TORQDATAHOME}/process-generated.csv"
  if ! vtgenprocesses > "${TORQPROCESSES}.tmp" 2>/dev/null; then
    echo "setenv.sh: ERROR - could not write ${TORQPROCESSES}" >&2
  else
    mv -f "${TORQPROCESSES}.tmp" "${TORQPROCESSES}"
  fi
fi
unset _vtsfile _vtifile

# --- data and logs -----------------------------------------------------------
# ONE directory for the database. No separate wdb/hdb areas: the writer writes where
# the readers read, and nothing moves at end of day. KDBHDB and KDBWDB are kept as
# aliases because TorQ core and the stock settings read them by name.
export KDBDB="${TORQDATAHOME}/db"
export KDBWDB="${KDBDB}"
export KDBHDB="${KDBDB}"
export KDBLOG="${TORQDATAHOME}/logs"
export KDBTPLOG="${TORQDATAHOME}/tplogs"

# --- kdb-x -------------------------------------------------------------------
# these are usually absent from the shell profile. without QLIC q reports
# "license error: no license loaded"; without QPATH `use` cannot resolve modules.
export QHOME="${QHOME:-$HOME/.kx/q}"
export QLIC="${QLIC:-$HOME/.kx}"
export QPATH="${QPATH:-$HOME/.kx/mod}"
export QCMD="${QCMD:-q}"
export RLWRAP="${RLWRAP:-rlwrap}"
export QCON="${QCON:-qcon}"

export KDBBASEPORT="${KDBBASEPORT:-6000}"

# Create the roots that will actually be written to. With one stack that is KDBDB; with
# several, each writer has its own and KDBDB is vestigial - creating it anyway leaves an
# empty directory that looks like somewhere data might be going, and would hide the very
# leak this pack cares about (a writer whose hdbdir was not moved with its savedir writes
# its enumeration file there, silently).
mkdir -p "${KDBLOG}" "${KDBTPLOG}"
if [ "$VTSTACKS" -gt 1 ]; then
  _i=1; while [ "$_i" -le "$VTSTACKS" ]; do mkdir -p "$(vtroot $_i)"; _i=$((_i+1)); done
  unset _i
else
  mkdir -p "${KDBDB}"
fi
