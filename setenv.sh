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
export TORQPROCESSES="${KDBAPPCONFIG}/process.csv"

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
