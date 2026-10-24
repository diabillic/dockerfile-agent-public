# dockerfile-agent

Keeps a generated `Dockerfile` (and `.dockerignore`) in every agent repository, current with
whatever is pushed. It watches each private repository and its `-public` copy, and acts within a
minute of a change.

## What it does

Every `POLL_SECONDS` (default 60) it asks GitHub for the head of each watched branch with
`git ls-remote`. That's cheap and needs no inbound webhook. When a head moved:

| Change in | What happens |
|---|---|
| a private repo | Fetches it, regenerates the files, and if the result differs, commits and pushes them to that repository. The repository's own CI then deploys and syncs as usual, so the public copy gets the Dockerfile too. Posts the diff to `NOTIFY_URLS`. |
| its public copy | Checks that the copy is consistent: its Dockerfile matches its code, and its deployment files match the private repository's. The public copy is a generated mirror, and its sync overwrites direct edits, so a mismatch that lasts longer than `PUBLIC_GRACE_MINUTES` (default 20, which covers a sync in progress) is reported. |

The agent's own commit moves `main` once more; it regenerates, finds nothing to change, and stops.
Failures (GitHub unreachable, a missing deploy key) are retried every cycle. A failure is reported
after 3 cycles in a row, and so is the recovery.

## How the Dockerfile is derived

It follows how the agent is deployed today, so it changes when the deployment does:

| Source | Becomes |
|---|---|
| systemd unit in `deploy/lxc/*-install` | image user and group, `WORKDIR`, `ENV` (from `Environment=`), `VOLUME` (from `StateDirectory=`), `CMD` (the `-m <package>` in `ExecStart=`) |
| `deploy/lxc/bootstrap-agent.sh` | `apt-get install` packages, minus what only the LXC needs (python3, venv, rsync, sudo, openssh-server) |
| `requirements.txt` | `pip install` |
| `<package>/config.py` | `EXPOSE` for every `*_PORT` default, and read-only mounts in the run example for `/etc/...` files |

Code changes reach the image through `COPY <package>/`, so they don't change the Dockerfile.
Output is deterministic: the same inputs produce the same bytes, so nothing is committed unless
something relevant changed. Each Dockerfile's header shows how to build and run it. In the
`-public` copies, CI builds the image on every push to prove it still builds.

A repository without a `deploy/lxc/*-install` unit isn't an agent; it's reported once and skipped.
Preview the output for a local checkout with `python -m dockerfile_agent --render <path>`.

## Deployment

Every push to `main` runs the tests. The deploy job then sends the build context (the generated
`Dockerfile` and `.dockerignore`, `requirements.txt` and the package) and a rendered `agent.env` to
a Docker host. There, the root-owned `agent-deploy` builds the image and replaces the container,
and rolls back if the new one doesn't stay up. Each build pulls the newest base image and runs
`apt-get full-upgrade`, so every deployed image is fully patched. State lives in the
`dockerfile-agent-data` volume.

| Variable | Expected value |
|---|---|
| `AGENT_HOST` | Address of the Docker host. |
| `PRIORITY` | `high` (default) or `low`. Picks the deploying runner (`[self-hosted, proxmox]` or `[self-hosted, low-priority]`) and sets the container label `homelab.priority`. |
| `BUS_HOST_PORT` | Optional. Host port for the agent bus when several agents share a host. The container still listens on `AGENT_BUS_PORT`. |

To prepare a Docker host, run `deploy/docker-host.sh` from the dockerfile-agent repository. It
installs `agent-deploy`, creates the `deploy` user, allows only the given runners in, and turns
on unattended security upgrades. With `DOCKER_API_ALLOW=<ip,...>` it also opens the Docker API on
tcp/2375 for a remote manager such as Dockhand, firewalled to those addresses. That API has no
authentication, so anyone who can reach it is root on the host. Run it again without the variable to
close the API. `agent-redeploy start` rebuilds every agent from its last staged build context (a
fresh base image and full upgrade, with no new commit needed), and `agent-redeploy status` reports
the result. The Proxmox janitor uses these for its weekly rebuild, through a key forced to
`agent-redeploy-ssh`.

Third-party apps go through the same path: put a Dockerfile in `deploy/apps/<app>/` and run
`APP=<app> HOST=<docker host> PUBLISH=<host>:<container> deploy/deploy-app.sh`. Base it on the upstream image, add
an `apt-get full-upgrade` layer keyed on `PATCHED_AT`, and declare the data directory as a `VOLUME`. The app is then
built fully patched, kept in `<app>-data`, and rebuilt every week. `apps/uptime-kuma` is an example.

Apps that need more, such as the Docker socket, get root-only run options through `EXTRA`
(`mount=/host:/container[:ro]`, `network=<name>`). It's written to `/etc/agents/<app>.extra`, where staged files can't
reach. `apps/docker-socket-proxy` gives Uptime Kuma a read-only view of a host's containers. On the monitoring
host, share a private network with it (`EXTRA=network=kuma`). Elsewhere, publish it and limit it with `docker-host.sh`'s
`PORT_ALLOW=<port>=<monitoring host>`. Every container is labelled `homelab.kind` (`agent` or `app`), and
`agent-redeploy list` reports them, which is how the Proxmox janitor finds agents to monitor. The LXC deployment below (`deploy/provision.sh`) still works as
an alternative.

### LXC deployment (alternative)

Same pattern as the other agents: a systemd service in its own LXC, deployed by GitHub Actions on
the shared self-hosted runner.

```bash
PVE_HOST=root@<proxmox-ip> REPOS="owner/agent-a owner/agent-b owner/dockerfile-agent" \
  ADMIN_PUBKEY=~/.ssh/id_ed25519.pub deploy/provision.sh
```

It creates the agent LXC and registers a runner instance for this repository. The agent gets one
SSH key per watched repository, because GitHub allows a deploy key on one repository only. Each key
is added there as a **write** deploy key. The script also sets the `AGENT_HOST` and `REPOS`
variables. Public copies are read over anonymous HTTPS, so the agent has no access to them.

To watch another repository, re-run `provision.sh` with it added to `REPOS`. Existing LXCs and keys
are reused.

## Secrets and variables

This repository contains **no secrets**. Set them under **Settings → Secrets and variables →
Actions**; the deploy job stops with a clear error if a required one is missing.

| Kind | Name | Required | Expected value |
|---|---|---|---|
| variable | `AGENT_HOST` | **yes** | IP or hostname of the agent LXC. `provision.sh` sets it. |
| variable | `REPOS` | **yes** | Private repositories to keep a Dockerfile in, comma separated, e.g. `me/agent-a,me/agent-b`. `provision.sh` sets it. |
| secret | `NOTIFY_URLS` | recommended | [Apprise](https://github.com/caronc/apprise/wiki) URL(s). A Discord webhook (`https://discord.com/api/webhooks/<id>/<token>`) gets formatted embeds. |
| secret | `PUBLIC_DEPLOY_KEY` | for the public copy | Private half of a write deploy key on `<repo>-public`, used by the `sync-public` job. |
| variable | `GIT_AUTHOR_NAME`, `GIT_AUTHOR_EMAIL` | optional | Author of the agent's commits. Default `Dockerfile agent` / `dockerfile-agent@localhost`. |
| variable | `BASE_IMAGE` | optional | Default `python:3.13-slim-trixie` (Python 3.13, as on the Debian 13 LXCs). |
| variable | `TIMEZONE` | optional | The images' clock (`TZ`, with `tzdata`), an IANA zone such as `America/New_York`. Default `UTC`. Changing it regenerates every Dockerfile. |
| variable | `POLL_SECONDS`, `PUBLIC_GRACE_MINUTES`, `WATCH_PUBLIC`, `PUBLIC_SUFFIX`, `BRANCH` | optional | Defaults `60`, `20`, `true`, `-public`, `main`. |

## Operating

```bash
ssh root@<agent-ip> journalctl -u dockerfile-agent -f
```

State (last seen heads, pending public mismatches, error counts) is in
`/var/lib/dockerfile-agent/state.json`. Delete it to make the agent re-check everything on its next
cycle. Clones live in `/var/lib/dockerfile-agent/work`.

## Develop

```bash
pip install -r requirements.txt pytest
pytest -q
```
