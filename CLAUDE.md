# CLAUDE.md

Guidance for working in this repo. Read this before changing the Dockerfile,
shim, or entrypoint — several choices here are deliberate workarounds for
non-obvious Semaphore behaviour, and "simplifying" them will reintroduce bugs.

## What this is

A custom `semaphoreui/semaphore` image that bundles multiple Ansible versions and
selects one per task at runtime via the `USE_ANSIBLE_VERSION` env var. Three
files do the work:

- `Dockerfile` — builds a venv per Ansible major, wires up the shim/entrypoint.
- `ansible-shim.sh` — the dispatcher (installed as `…/ansible-shim/ansible-dispatch`).
- `entrypoint.sh` — entrypoint prep (installed as `/opt/semaphore/entrypoint`).

## Semaphore internals this depends on (verified against source)

These are the load-bearing facts. If upstream changes them, this image breaks.

- **Semaphore has no native Ansible version selection.** The `apps` config has a
  `path`, but for the `ansible` app type the binary name `ansible-playbook` /
  `ansible-galaxy` is hardcoded and `apps.ansible.path` is ignored. The
  `/opt/semaphore/apps/ansible/<version>/venv` layout is just a Docker build
  convention; Semaphore never reads the version dir.
- **Ansible is invoked by name via `$PATH`**, and Semaphore forwards its own
  process `$PATH` into the task subprocess. → A shim dir prepended to `PATH`
  (set via `ENV`) wins. This is the entire mechanism.
- **The task subprocess env is curated, not inherited.** Semaphore builds the
  child env explicitly: `PATH` + `ForwardedEnvVars` + config `EnvVars` + the
  task's Environment vars. It sets `cmd.Env`, so the image's `ENV` vars do **not**
  reach the task. → `USE_ANSIBLE_VERSION` works because it's a task Environment
  var; a hypothetical image-level default env var would *not* reach the shim.
  This is why the default version is a **filesystem symlink** (`default`), not an
  env var — the filesystem is always visible at task time.
- **`USE_ANSIBLE_VERSION` must be set in the Environment's "Environment Variables"
  field**, not "Extra Variables" (those become `--extra-vars`, never process env).

## Architecture

- `ansible-shim.sh` is symlinked under `/opt/semaphore/ansible-shim/` as every
  `ansible*` name **and** `python`/`python3`/`python3.12`/`pip`/`pip3`/`pip3.12`.
  It reads `${USE_ANSIBLE_VERSION:-default}`, resolves it to a venv, and execs
  `$VENV/bin/<invoked-name>`. So Ansible *and* a playbook's `python`/`pip` land in
  the same venv.
- **Version resolution is discovery-based**, not hardcoded: exact dir match first,
  else map to an Ansible major (`2.X → X-7`, e.g. `2.18→11`) and prefer a
  major-keyed dir, else glob the newest `<major>.*` dir. → Bumping the base image
  (e.g. `13.5.0 → 13.6.0`) needs no shim change; the `13.*` line is found by glob.
- **`default` symlink** (`apps/ansible/default → $DEFAULT_ANSIBLE_MAJOR`) is the
  single source of truth for the default. The shim resolves empty input to
  `default`; nothing hardcodes the default version in the shim.
- **`entrypoint.sh`** runs inside the entrypoint (`tini -- /opt/semaphore/entrypoint`,
  then `exec "$@"` → the inherited `server-wrapper` CMD). It (1) strips the raw
  `…/ansible/*/venv/bin` dirs from `PATH` so only the shim resolves Ansible while
  preserving all other PATH entries, and (2) installs `requirements.txt` into
  **every** venv (each venv's own pip).
- Each venv is built `--system-site-packages`. `python`/`pip` resolving to the
  default venv mirrors upstream (where `which python pip` points into the venv).

## Gotchas / do-not-do

- **Don't reroute `pip` to system pip.** Alpine's system python is
  externally-managed (PEP 668), so `pip3 install` there fails and (under
  `server-wrapper`'s `set -e`) kills the container. `pip` must resolve to a venv
  pip — which it does, via the shim. This is why we don't strip venvs *and* leave
  pip pointing at the system.
- **Don't `chown -R /opt/semaphore`.** It recursively touches the inherited base
  venv, which lives in a lower overlay layer, forcing a full content copy-up of
  tens of thousands of files (observed: 6+ minutes). We only chown the `COPY`'d
  shim/entrypoint. The built venvs are already `semaphore:0` because the build
  user (uid 1001) has primary gid 0.
- **`__pycache__` cleanup must use `-prune`** (`find … -type d -name __pycache__
  -prune -exec rm -rf {} +`). Plain `-exec rm -rf {} +` self-races (find descends
  into a dir a prior batch already deleted) and exits non-zero → `set -e` aborts.
- **Don't wrap `python` through a *separate* dispatcher target** that changes its
  behaviour — `python -m venv` (used by the Semaphore bash-app pattern) and the
  python app expect a normal interpreter. The shim just execs the venv's real
  `python`, which is fine.
- `VIRTUAL_ENV` is cleared deliberately (no single "active" venv now).

## Build & test

```bash
docker build -t semaphore-docker:dev .

# dispatch smoke test
docker run --rm semaphore-docker:dev sh -c '
  which ansible-playbook python pip
  ansible --version | head -1                                   # default 2.18
  USE_ANSIBLE_VERSION=2.16 ansible --version | head -1          # 2.16
  USE_ANSIBLE_VERSION=13   python -c "import sys;print(sys.executable)"'
```

The per-venv `ansible --version` lines in the build log confirm the resolved
cores. To validate the workflows: `actionlint` (needs a git repo to anchor).

## Bumping the base Semaphore version

Change the `FROM` tag (or let Dependabot do it). The output tag derives from it
(`v<x>-multi`). After a bump, re-check: (1) the base image's bundled Ansible major
is still `13` (the `2.20/13` mapping assumes the base ships a 13.x); (2) the base
python minor still matches each built Ansible's supported controller range
(currently python 3.12 suits cores 2.16–2.20); (3) `python3.<minor>`/`pip3.<minor>`
shim symlinks in the Dockerfile still match the base python minor.

## Conventions

- Keep the shim and entrypoint POSIX `sh` (the base is Alpine/busybox). Verify
  with `sh -n`. Avoid bashisms; `sort -V`, `awk` arithmetic, and globs are
  available in busybox and are relied on.
- The Dockerfile's inline comments capture the *why* for each step — keep them
  current if you change the step.
