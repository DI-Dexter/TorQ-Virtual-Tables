#!/bin/bash
# Download and install TorQ plus this pack, producing a ready-to-run deploy/ tree.
#
# Designed to be fetched on its own, into an empty directory:
#
#   wget https://raw.githubusercontent.com/DataIntellectTech/TorQ-Virtual-Tables/main/installlatest.sh
#   bash installlatest.sh
#   ./deploy/bin/torq.sh start all
#
# Assumes the community edition of KDB-X is already on the PATH as `q`.
#
# Options:
#   --app-ref <branch|tag>   take the pack from this ref instead of its latest release
#   --torq-version <x.y.z>   pin TorQ instead of taking the latest release
#   --releasedir <dir>       install somewhere other than ./deploy
#   --in-place               skip the deploy tree; just fetch TorQ next to an existing checkout

set -e

TORQ_REPO="DataIntellectTech/TorQ"
APP_REPO="${APP_REPO:-DataIntellectTech/TorQ-Virtual-Tables}"
APP_NAME="TorQ-Virtual-Tables"
APP_REF=""
TORQ_PIN=""
RELEASEDIR="deploy"
INPLACE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --app-ref)       APP_REF="$2"; shift 2 ;;
    --torq-version)  TORQ_PIN="$2"; shift 2 ;;
    --releasedir)    RELEASEDIR="$2"; shift 2 ;;
    --in-place)      INPLACE=1; shift ;;
    -h|--help)       sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

for c in tar sed; do
  command -v "$c" >/dev/null 2>&1 || { echo "ERROR: '$c' is required" >&2; exit 1; }
done
if   command -v curl >/dev/null 2>&1; then GET() { curl -fsSL "$1" -o "$2"; }; API() { curl -fsSL "$1"; }
elif command -v wget >/dev/null 2>&1; then GET() { wget -q "$1" -O "$2"; };    API() { wget -qO- "$1"; }
else echo "ERROR: need curl or wget" >&2; exit 1; fi

latest_tag () { API "https://api.github.com/repos/$1/releases/latest" 2>/dev/null \
                | grep -Po '"tag_name": "\K.*?(?=")' || true; }

validtag () { case "$1" in v[0-9]*.[0-9]*.[0-9]*|[0-9]*.[0-9]*.[0-9]*) return 0 ;; *) return 1 ;; esac; }

# --- TorQ ---------------------------------------------------------------------
if [ -n "$TORQ_PIN" ]; then TORQ_TAG="$TORQ_PIN"; else TORQ_TAG=$(latest_tag "$TORQ_REPO"); fi
[ -n "$TORQ_TAG" ] || { echo "ERROR: could not resolve a TorQ release (network?)" >&2; exit 1; }
validtag "$TORQ_TAG" || { echo "ERROR: TorQ tag '$TORQ_TAG' is not a version, refusing" >&2; exit 1; }
TORQ_VER="${TORQ_TAG#v}"
TORQ_TGZ="TorQ-${TORQ_VER}.tar.gz"

echo "============================================================="
echo " TorQ release : $TORQ_TAG"
echo "============================================================="
GET "https://github.com/${TORQ_REPO}/archive/${TORQ_TAG}.tar.gz" "$TORQ_TGZ"

if [ "$INPLACE" = 1 ]; then
  rm -rf "TorQ-${TORQ_VER}"; tar -xzf "$TORQ_TGZ"; rm -f "$TORQ_TGZ"
  echo ""
  echo "TorQ ${TORQ_VER} at ${DIR}/TorQ-${TORQ_VER}"
  echo "  export TORQHOME=${DIR}/TorQ-${TORQ_VER}"
  echo "  SETENV=\$PWD/setenv.sh \$TORQHOME/torq.sh start all"
  exit 0
fi

# --- this pack ----------------------------------------------------------------
# A release if there is one, otherwise a branch. The tarball is repacked under a
# canonical name because installtorqapp.sh derives the version from the FILENAME.
APP_TAG=""
if [ -z "$APP_REF" ]; then APP_TAG=$(latest_tag "$APP_REPO"); fi

if [ -n "$APP_TAG" ] && validtag "$APP_TAG"; then
  APP_VER="${APP_TAG#v}"; APP_URL="https://github.com/${APP_REPO}/archive/${APP_TAG}.tar.gz"
  echo " ${APP_NAME} release : $APP_TAG"
else
  REF="${APP_REF:-main}"
  # installtorqapp.sh takes everything after the LAST hyphen in the filename as the version,
  # so a branch name like part1-foo-bar would install as "bar". Hyphens and slashes out.
  APP_VER=$(printf '%s' "$REF" | tr -- '-/' '__')
  APP_URL="https://github.com/${APP_REPO}/archive/refs/heads/${REF}.tar.gz"
  echo " ${APP_NAME} : no release found, taking branch '${REF}'"
fi
echo "============================================================="

APP_TGZ="${APP_NAME}-${APP_VER}.tar.gz"
GET "$APP_URL" "_app_raw.tar.gz" || {
  echo "ERROR: could not download the pack from ${APP_URL}" >&2
  echo "       pass --app-ref <branch> if it is not on main yet" >&2; exit 1; }

# repack so the top-level directory matches the filename installtorqapp.sh expects
rm -rf _app && mkdir _app && tar -xzf _app_raw.tar.gz -C _app
INNER=$(ls _app)
# GitHub's archive is frequently named exactly this already (a tag v1.2.3 extracts to
# <repo>-1.2.3), and mv onto an existing directory moves it INSIDE itself.
if [ "$INNER" != "${APP_NAME}-${APP_VER}" ]; then
  mv "_app/${INNER}" "_app/${APP_NAME}-${APP_VER}"
fi
tar -czf "$APP_TGZ" -C _app "${APP_NAME}-${APP_VER}"
rm -rf _app _app_raw.tar.gz

# installtorqapp.sh ships inside the TorQ tarball - no second download needed
tar -xzf "$TORQ_TGZ" "TorQ-${TORQ_VER}/installtorqapp.sh" --strip-components=1

# installtorqapp.sh tries to copy <app>/hdb and <app>/dqe into the data directory, as the
# FSP ships both. This pack has neither, so it prints two "cannot stat" lines - harmless.

echo ""
bash installtorqapp.sh --torq "$TORQ_TGZ" --releasedir "$RELEASEDIR" \
                       --data "${RELEASEDIR}/data" --installfile "$APP_TGZ" || true
rm -f installtorqapp.sh "$TORQ_TGZ" "$APP_TGZ"

if [ ! -x "${RELEASEDIR}/bin/torq.sh" ]; then
  echo "ERROR: ${RELEASEDIR}/bin/torq.sh was not produced - install failed" >&2; exit 1
fi

echo ""
echo "============================================================="
echo " Installed. Start the stack with:"
echo "   ./${RELEASEDIR}/bin/torq.sh start all"
echo "   ./${RELEASEDIR}/bin/torq.sh summary"
echo "============================================================="
