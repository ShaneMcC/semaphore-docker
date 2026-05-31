#!/bin/sh
# Custom entrypoint prep — run by tini before the real command (server-wrapper).
# Does two jobs, then exec's whatever command it was given ("$@"):
#
#   1. PATH: make /opt/semaphore/ansible-shim the ONLY resolver for ansible*.
#      Strip just the ansible venv bin dirs (.../apps/ansible/<x>/venv/bin) and
#      prepend the shim, preserving every other PATH entry the base image sets
#      now or in future. python/pip are provided from the default venv via
#      symlinks in the shim dir (see Dockerfile), mirroring upstream.
#
#   2. requirements.txt: install user python deps into EVERY ansible venv, using
#      each venv's own pip (so no PEP 668 / externally-managed error). This makes
#      libs like netaddr/dnspython importable regardless of which ansible version
#      a task selects. server-wrapper also installs them into the default venv via
#      the pip symlink — that pass then just reports "already satisfied".
set -eu

# --- 1. PATH ---
_new=""
IFS=:
for _d in $PATH; do
  case "$_d" in
    /opt/semaphore/apps/ansible/*/venv/bin) continue ;;  # drop ansible venvs
  esac
  _new="${_new:+$_new:}$_d"
done
unset IFS
export PATH="/opt/semaphore/ansible-shim:$_new"

# --- 2. requirements.txt into every ansible venv ---
_req="${SEMAPHORE_CONFIG_PATH:-/etc/semaphore}/requirements.txt"
if [ -f "$_req" ]; then
  for _v in /opt/semaphore/apps/ansible/*/venv; do
    [ -x "$_v/bin/pip" ] || continue
    echo "entrypoint: installing $_req into $_v" >&2
    "$_v/bin/pip" install --upgrade -r "$_req" \
      || echo "entrypoint: WARNING: pip install into $_v failed" >&2
  done
fi

exec "$@"
