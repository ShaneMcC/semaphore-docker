# semaphore-docker

A [Semaphore UI](https://semaphoreui.com) image that bundles **multiple Ansible
versions side by side** and lets you pick which one runs **per task, at runtime**.

Upstream Semaphore ships a single Ansible version baked into the image, and has
no native way to select a version per task. This image installs several and adds
a thin dispatcher so a task chooses its Ansible (and matching `python`/`pip`) via
a single environment variable.

## Ansible versions

| `USE_ANSIBLE_VERSION` | Ansible | ansible-core | Source |
|----------------------|---------|--------------|--------|
| `2.16` / `9`         | 9.x     | 2.16         | built in this image |
| `2.18` / `11`        | 11.x    | 2.18         | built in this image — **default** |
| `2.20` / `13`        | 13.x    | 2.20         | inherited from the base image |

Each Ansible major maps 1:1 to an ansible-core minor for its whole life
(`9→2.16`, `11→2.18`, `13→2.20`), so selecting a major line is unambiguous.

## Selecting a version

Set `USE_ANSIBLE_VERSION` in a Semaphore **Environment**, in its **Environment
Variables** field (the JSON key/value box — *not* "Extra Variables", which become
`--extra-vars` and never reach the process environment):

```json
{ "USE_ANSIBLE_VERSION": "2.16" }
```

Assign that Environment to a template and its tasks run under ansible-core 2.16.

Accepted values: an ansible-core minor (`2.16`, `2.18`, `2.20`), an ansible major
(`9`, `11`, `13`), or an exact installed dir (e.g. `13.5.0`). Unset → the default
(`2.18`). An unknown value fails fast with a list of what's installed.

`python`, `pip`, and the `ansible*` family all follow `USE_ANSIBLE_VERSION`, so a
playbook that shells out to `python`/`pip` lands in the same venv as its Ansible.

## Python dependencies (`requirements.txt`)

The base image's `server-wrapper` installs `${SEMAPHORE_CONFIG_PATH}/requirements.txt`
at startup. This image's entrypoint installs it into **every** bundled Ansible
venv, so libraries like `netaddr`/`dnspython` are importable whichever version a
task selects — not just the default.

## Images

Published on every `master` build to both:

- `ghcr.io/shanemcc/semaphore-docker`
- `registry.shanemcc.net/public/semaphore-docker`

Tagged `v<semaphore-version>-multi` (e.g. `v2.18.4-multi`), tracking the base
Semaphore image version.

```bash
docker pull registry.shanemcc.net/public/semaphore-docker:v2.18.4-multi
# or
docker pull ghcr.io/shanemcc/semaphore-docker:v2.18.4-multi
```

Use it as a drop-in replacement for `semaphoreui/semaphore` — all the usual
Semaphore configuration (`SEMAPHORE_*` env vars, config volume) works unchanged.

## Building locally

```bash
docker build -t semaphore-docker:dev .
```

Build args:

| Arg                    | Default  | Purpose |
|------------------------|----------|---------|
| `ANSIBLE_MAJORS`       | `9 11`   | Space-separated Ansible majors to build (latest patch of each). |
| `DEFAULT_ANSIBLE_MAJOR`| `11`     | Which version is used when `USE_ANSIBLE_VERSION` is unset. |

```bash
# e.g. also bundle 2.20 explicitly and default to it
docker build \
  --build-arg ANSIBLE_MAJORS="9 11 13" \
  --build-arg DEFAULT_ANSIBLE_MAJOR=13 \
  -t semaphore-docker:dev .
```

Smoke test:

```bash
docker run --rm semaphore-docker:dev ansible --version            # default (2.18)
docker run --rm -e USE_ANSIBLE_VERSION=2.16 semaphore-docker:dev ansible --version
```

## CI/CD

- `.github/workflows/docker-build.yml` — reusable build+push (pushes each tag to
  both registries). Inputs: `version`, `build-args`, `latest`, `scope`, `dockerfile`.
- `.github/workflows/build-and-push.yml` — caller. Builds the default variant on
  `master` pushes and manual dispatch; add jobs here to publish more variants.
- `.github/dependabot.yml` — watches the base image and the Actions; minor/patch
  bumps auto-merge, so a Semaphore patch release rebuilds and re-tags itself.

Requires repo secrets `REGISTRY_USERNAME` / `REGISTRY_PASSWORD` (ghcr uses the
built-in `GITHUB_TOKEN`).

## How it works

The base image lays venvs out at `/opt/semaphore/apps/ansible/<version>/venv`, but
Semaphore itself just invokes `ansible-playbook` by name via `$PATH` (it has no
version awareness). This image exploits that:

1. **`ansible-shim.sh`** is symlinked as every `ansible*`/`python`/`pip` name into
   a dir placed first on `PATH`. It resolves `USE_ANSIBLE_VERSION` to a venv
   (discovering whatever is installed) and `exec`s the real binary from it.
2. A build-time `default` symlink (`apps/ansible/default → <DEFAULT_ANSIBLE_MAJOR>`)
   is the single source of truth for the default — resolved on the filesystem, so
   it works at task-execution time where image env vars don't reach.
3. **`entrypoint.sh`** (wrapped into the base entrypoint) strips the raw venv bin
   dirs from `PATH` so only the shim resolves Ansible, and installs
   `requirements.txt` into every venv.

See [CLAUDE.md](CLAUDE.md) for the design rationale and the non-obvious
constraints behind these choices.
