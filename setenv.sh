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

# --- how many capture stacks -------------------------------------------------
# 1 (the default) is the pack as described everywhere else: one tickerplant, writer, feed and
# reader. 2 adds a SECOND complete capture stack at {KDBBASEPORT}+100, writing into the SAME
# database root as the first - the arrangement documented in section 8.3.2.
#
#   VTSTACKS=2 SETENV=$PWD/setenv.sh $TORQHOME/torq.sh start all
#   VTSTACKS=2 ./deploy/bin/torq.sh start all        # in an installed tree
#
# VTSTACKS has to be set on every torq.sh call for that stack, `stop` and `summary` included:
# torq.sh only knows about the processes in the file this picks.
#
# The second stack captures a DISJOINT instrument universe (appconfig/settings/feed2.q). That is
# not a nicety: the same (date;instrument) written under one root by two writers is served twice,
# with no error and nothing in any log (8.3.1).
export VTSTACKS="${VTSTACKS:-1}"
case "$VTSTACKS" in
  1) export TORQPROCESSES="${KDBAPPCONFIG}/process.csv" ;;
  2) export TORQPROCESSES="${KDBAPPCONFIG}/process-2stack.csv" ;;
  *) echo "setenv.sh: WARNING - VTSTACKS='${VTSTACKS}' is not 1 or 2, starting one stack" >&2
     export VTSTACKS=1
     export TORQPROCESSES="${KDBAPPCONFIG}/process.csv" ;;
esac

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

mkdir -p "${KDBDB}" "${KDBLOG}" "${KDBTPLOG}"
