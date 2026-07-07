FROM semaphoreui/semaphore:v2.18.21

# Extra ansible MAJOR lines to install side by side (latest patch of each major).
# Each ansible major maps 1:1 to an ansible-core minor for its whole life:
#   9  -> ansible-core 2.16   (built here)
#   11 -> ansible-core 2.18   (built here; default when USE_ANSIBLE_VERSION is unset)
#   13 -> ansible-core 2.20   (already shipped by the base image — not rebuilt)
# Runtime selection is via USE_ANSIBLE_VERSION (see ansible-shim.sh), which
# discovers whatever is installed — so bumping the base image needs no change here.
ARG ANSIBLE_MAJORS="9 11"

# Single source of truth for the default ansible version. Used to create the
# `default` symlink (.../apps/ansible/default -> <this>), which the shim resolves
# whenever USE_ANSIBLE_VERSION is unset — for ansible* AND for python/pip. So the
# "ambient" python/pip (server-wrapper's requirements.txt install, the Semaphore
# python/bash apps, `docker exec`) come from this venv, mirroring upstream where
# python/pip live in the single ansible venv; a task that sets USE_ANSIBLE_VERSION
# gets python/pip from that version's venv instead.
ARG DEFAULT_ANSIBLE_MAJOR=11

# --- build deps (root) ---
USER root
RUN apk add --no-cache -U python3-dev build-base openssl-dev libffi-dev cargo

# --- build one venv per ansible major, latest patch (as the semaphore user, uid 1001) ---
USER 1001
RUN set -eux; \
    for M in ${ANSIBLE_MAJORS}; do \
      VENV=/opt/semaphore/apps/ansible/$M/venv; \
      python3 -m venv "$VENV" --system-site-packages; \
      "$VENV/bin/pip" install --upgrade pip; \
      "$VENV/bin/pip" install "ansible>=$M,<$((M+1))" boto3 botocore requests pywinrm passlib; \
      "$VENV/bin/ansible" --version; \
      find "$VENV" -type d -name __pycache__ -prune -exec rm -rf {} +; \
    done

# --- install shim + entrypoint, wire up python/pip, strip build deps (root) ---
USER root
COPY ansible-shim.sh /opt/semaphore/ansible-shim/ansible-dispatch
COPY entrypoint.sh   /opt/semaphore/entrypoint
RUN set -eux; \
    chmod +x /opt/semaphore/ansible-shim/ansible-dispatch /opt/semaphore/entrypoint; \
    ln -sf "${DEFAULT_ANSIBLE_MAJOR}" /opt/semaphore/apps/ansible/default; \
    for c in ansible ansible-playbook ansible-galaxy ansible-config ansible-console \
             ansible-doc ansible-inventory ansible-pull ansible-vault \
             ansible-connection ansible-community ansible-test \
             python python3 python3.12 pip pip3 pip3.12; do \
      ln -sf ansible-dispatch /opt/semaphore/ansible-shim/$c; \
    done; \
    apk del python3-dev build-base openssl-dev libffi-dev cargo; \
    rm -rf /var/cache/apk/*; \
    chown -R semaphore:0 /opt/semaphore/ansible-shim /opt/semaphore/entrypoint
# NB: only the COPY'd shim/entrypoint are root-owned and need chowning. The venvs
# are created as uid 1001 whose primary gid is 0, so they're already semaphore:0.
# chown -R on all of /opt/semaphore would force an overlayfs copy-up of the
# inherited base venv (tens of thousands of files) for no benefit — very slow.

# Shim first for any direct `docker exec`; base PATH (incl. future additions)
# preserved. The entrypoint strips the ansible venv bin dirs for the server
# process so unshimmed ansible binaries can't leak a version; ansible*, python
# and pip all dispatch through the shim (per USE_ANSIBLE_VERSION, else default).
ENV PATH="/opt/semaphore/ansible-shim:$PATH"
# VIRTUAL_ENV (inherited from the base) pointed at the 13.5.0 venv; selection is
# now per-task and python/pip are provided explicitly — clear it to avoid confusion.
ENV VIRTUAL_ENV=""

# Wrap the base entrypoint: keep tini as init, run our entrypoint (PATH fixup +
# requirements.txt install into every venv), then exec the CMD below.
# NB: overriding ENTRYPOINT resets the inherited CMD to null, so CMD must be
# re-declared here (matching the base's /usr/local/bin/server-wrapper) — without
# it our entrypoint's `exec "$@"` runs with no args, exits 0, and the container
# restart-loops.
ENTRYPOINT ["/sbin/tini", "--", "/opt/semaphore/entrypoint"]
CMD ["/usr/local/bin/server-wrapper"]

USER 1001
