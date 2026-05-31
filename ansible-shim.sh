#!/bin/sh
# ansible-shim — dispatch ansible*, python and pip commands to a chosen venv.
#
# Semaphore invokes "ansible-playbook"/"ansible-galaxy" by name and resolves
# them via $PATH, forwarding its own PATH into the task subprocess. This shim
# is placed first on PATH; ansible*, python and pip are all symlinks to this
# script. It reads USE_ANSIBLE_VERSION (set per-task via a Semaphore Environment's
# "Environment Variables" field) and exec's the matching venv's real binary — so
# a `python`/`pip` shelled out from a playbook lands in that task's venv too.
#
# Version selection is DISCOVERY-based, not hardcoded: it finds whatever venvs
# are installed under $BASE. Each ansible package major maps 1:1 to an
# ansible-core minor for its whole life (9->2.16, 11->2.18, 13->2.20, ...), so
# selecting a major line is unambiguous. Accepted USE_ANSIBLE_VERSION values:
#   - ansible major:      9 | 11 | 13
#   - ansible-core minor: 2.16 | 2.18 | 2.20
#   - an exact installed dir name (e.g. 13.5.0)
#   - empty -> the "default" venv
# Because it discovers by major line, bumping the base image (e.g. 13.5.0 ->
# 13.6.0) needs no change here.
set -eu

BASE=/opt/semaphore/apps/ansible

# Empty USE_ANSIBLE_VERSION resolves to $BASE/default — a symlink to the default
# version's dir, created at build time (single source of truth: DEFAULT_ANSIBLE_MAJOR
# in the Dockerfile). Nothing here hardcodes which version is the default.
req="${USE_ANSIBLE_VERSION:-default}"

find_venv() {
  _want=$1
  # 1) exact installed directory (a major-keyed "9"/"11", or a patch "13.5.0")
  if [ -d "$BASE/$_want/venv" ]; then
    printf '%s\n' "$BASE/$_want/venv"; return 0
  fi
  # 2) resolve to an ansible package major line
  case "$_want" in
    2.*) _maj=$(( ${_want#2.} - 7 )) ;;   # core 2.16->9, 2.18->11, 2.20->13
    *)   _maj=${_want%%.*} ;;             # 9 / 11 / 13 / 11.13.0 -> 11
  esac
  # prefer a major-keyed dir we built; else newest version-named dir for that major
  if [ -d "$BASE/$_maj/venv" ]; then
    printf '%s\n' "$BASE/$_maj/venv"; return 0
  fi
  _hit=$(ls -d "$BASE/$_maj".*/venv 2>/dev/null | sort -V | tail -1)
  [ -n "$_hit" ] && { printf '%s\n' "$_hit"; return 0; }
  return 1
}

VENV=$(find_venv "$req") || {
  echo "ansible-shim: no ansible venv found for USE_ANSIBLE_VERSION='$req'" >&2
  echo "ansible-shim: installed under $BASE:" >&2
  ls -1 "$BASE" 2>/dev/null | sed 's/^/ansible-shim:   /' >&2
  exit 2
}

cmd=${0##*/}
target=$VENV/bin/$cmd
if [ ! -x "$target" ]; then
  echo "ansible-shim: '$cmd' not found in $VENV" >&2
  exit 127
fi

# Isolate each venv's collections/roles/tmp/galaxy-cache under its own
# ANSIBLE_HOME so versions never share ~/.ansible. An explicit ANSIBLE_HOME
# from the task environment wins.
export ANSIBLE_HOME="${ANSIBLE_HOME:-${VENV%/venv}/home}"
mkdir -p "$ANSIBLE_HOME" 2>/dev/null || true

exec "$target" "$@"
