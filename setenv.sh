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
# VTSTACKS  how many capture stacks (tickerplant + feed + writer), each with its own root.
# VTIDBS    how many readers. Every reader attaches every root.
#
#   VTSTACKS=3 VTIDBS=2 ./deploy/bin/torq.sh start all
#
# Both are remembered in $TORQDATAHOME, so stop and summary see the same processes as start.
# Anything other than 1x1 is generated into $TORQDATAHOME/process-generated.csv; the shipped
# appconfig/process.csv is used as-is for 1x1. Ports: stack i at +100*(i-1) with tickerplant
# +0, writer +5, feed +14; reader j at +30 of block j; discovery +1, compression +40.
_vtsfile="${TORQDATAHOME}/.vtstacks"
_vtifile="${TORQDATAHOME}/.vtidbs"
if [ -z "${VTSTACKS:-}" ] && [ -r "$_vtsfile" ]; then VTSTACKS="$(cat "$_vtsfile" 2>/dev/null)"; fi
if [ -z "${VTIDBS:-}"   ] && [ -r "$_vtifile" ]; then VTIDBS="$(cat "$_vtifile" 2>/dev/null)"; fi
VTSTACKS="${VTSTACKS:-1}"
VTIDBS="${VTIDBS:-1}"
case "$VTSTACKS" in ''|*[!0-9]*|0) echo "setenv.sh: WARNING - VTSTACKS='${VTSTACKS}' is not a positive integer, using 1" >&2; VTSTACKS=1 ;; esac
case "$VTIDBS"   in ''|*[!0-9]*|0) echo "setenv.sh: WARNING - VTIDBS='${VTIDBS}' is not a positive integer, using 1" >&2;   VTIDBS=1 ;; esac
export VTSTACKS VTIDBS

# A reader holds about 3 connections per capture stack. Where the licence caps connections,
# a reader past the cap keeps capturing but refuses clients with 'conn. The cap is read from
# the licence rather than assumed: .Q.lim[] gives conns as a number on a capped licence and
# as a cur/lim row on an uncapped one, which is what the type test below is for.
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

# One stack keeps the stock root and domain. Several get one each: the reader binds a global
# named after the domain file, so two roots sharing a name cannot be read together (8.3.1).
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
    # pin writer and feed to their own tickerplant - a lookup by process type takes
    # whichever is found first, which is a coin toss with several stacks
    _wx="-.wdb.tickerplantname stp${_i}"
    _fx="-.feed.tickerplantname stp${_i}"
    if [ "$VTSTACKS" -gt 1 ]; then
      # savedir and hdbdir must move together: hdbdir is where .Q.en writes the domain file
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
    # every reader attaches every root. .vtidb.multiwriter is needed whenever there is more
    # than one writer, separate roots included: one live partition is held across all roots
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

# Create only the roots that will be written to. With several stacks KDBDB is unused, and an
# empty directory there would look like somewhere data might be going.
mkdir -p "${KDBLOG}" "${KDBTPLOG}"
if [ "$VTSTACKS" -gt 1 ]; then
  _i=1; while [ "$_i" -le "$VTSTACKS" ]; do mkdir -p "$(vtroot $_i)"; _i=$((_i+1)); done
  unset _i
else
  mkdir -p "${KDBDB}"
fi
