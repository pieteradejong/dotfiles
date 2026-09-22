# Containers and local databases

How this Mac runs containers and databases since 2026-09-15, and why. In short: Docker Desktop is
gone, **Colima** runs only while you need it, Postgres for non-Supabase work is native, and
deployed apps live on Vercel with hosted databases. `scripts/containers-doctor.sh` checks the
setup; the reasoning is in [Decisions](#decisions).

| Need | Use |
|---|---|
| Local Supabase stack (Supabase projects and templates) | `colima start`, then `supabase start` or the project's script; `colima stop` when done |
| Postgres + PostGIS for a non-Supabase project | Homebrew `postgresql@17` + `postgis`: `brew services run postgresql@17` |
| A deployed app and its database | Vercel, with hosted Supabase or Neon through the Vercel Marketplace |
| Building or testing a Docker image | GitHub Actions, or locally on Colima |
| Nothing | Nothing runs: no VM, no RAM, no CPU |

---

## Colima

Installed from `tools/Brewfile`: `colima`, `docker`, `docker-compose`, `docker-buildx`,
`docker-credential-helper`.

```zsh
colima start      # boots the VM with the saved profile: 4 CPU, 8 GiB, 40 GiB disk, vz + virtiofs
colima status
colima stop       # frees all CPU and RAM; images, containers and volumes are kept
```

- The profile was created once with
  `colima start --cpu 4 --memory 8 --disk 40 --vm-type vz --mount-type virtiofs`. To change CPU or
  memory: `colima stop`, then `colima start --cpu 2 --memory 4`. The disk can only grow.
- 8 GiB matches Supabase's recommendation for the full local stack. While running, the VM holds its
  whole allocation, which is why it is stopped when not in use.
- **Never `brew services start colima`.** Nothing container-related starts at login; the doctor
  fails if Colima does.
- Everything lives in `~/.colima` (the VM disk is under `~/.colima/_lima/_disks`): 9.4 GB after the
  first local Supabase start. `colima delete` removes the VM and every image and volume in it.
- `~/.docker/config.json` has `"credsStore": "osxkeychain"` and
  `"cliPluginsExtraDirs": ["/opt/homebrew/lib/docker/cli-plugins"]`, so the Homebrew compose and
  buildx plugins are found. Colima creates the `colima` docker context and makes it current on
  `colima start`, and restores the previous context (normally `default`) on `colima stop`.
- With Colima stopped, `docker` commands fail with "Cannot connect to the Docker daemon". That is
  expected. Scripts detect it with `docker info` (the weekly disk cleanup, project database
  wrapper scripts, the templates' `init.sh`/`run.sh`) and skip or explain.

## Supabase

**Local development** runs the Supabase CLI's stack in Colima. Which CLI commands need it:

| Needs Colima running | Works without Docker |
|---|---|
| `supabase start`, `stop`, `status` | `supabase link` |
| `supabase db reset`, `db diff`, `db pull`, `db dump` | `supabase db push --linked` |
| `supabase test db` | `supabase migration new` |
| | `supabase gen types --linked`, `supabase functions deploy`: the CLI reference lists no Docker requirement; not yet exercised here |

- **The Supabase CLI must be 2.110.0 or newer on Colima.** Older releases start `supabase_vector`
  with the host's socket path and fail (supabase/cli#5073, fixed by PR #5820). Verified with 2.117.0
  on 2026-09-15: all 12 containers of a local stack healthy. The doctor enforces the minimum. If it ever
  regresses, `supabase start -x vector` skips log collection.
- To save about 2 GiB when logs aren't needed, set `[analytics] enabled = false` in the project's
  `supabase/config.toml`. That drops the logflare and vector containers.
- The CLI comes from the `supabase/tap` tap, trusted per formula
  (`brew trust --formula supabase/tap/supabase`; `trusted: true` in the Brewfile).

**Deployed apps** use a hosted Supabase project, connected to Vercel with the Marketplace
integration (`vercel integration add supabase`); migrations go up with `supabase link` and
`supabase db push`. The free plan (as of 2026-09) allows two active projects, pauses a project after
a week without database activity, and caps the database at 500 MB.

## Native Postgres

For projects that only need Postgres, including PostGIS work, use Homebrew's server rather than a
container:

```zsh
brew services run postgresql@17     # starts it now; `start` would also register it at login
brew services stop postgresql@17    # when done
```

- Homebrew's `pg_hba.conf` trusts local connections, so project passwords are not checked.
- PostGIS 3.6.4 from the `postgis` formula is built for both `postgresql@17` and `postgresql@18`.
- A container publishing port 5432 conflicts with it; stop one before starting the other.

## Vercel is not a Docker host

Vercel runs container images (`Dockerfile.vercel`) as Functions: stateless, scaled to zero after 5
minutes without traffic, no persistent disk, no long-lived process. That suits deploying an app. It
does not replace a daemon for Postgres, Redis or a `supabase start` stack. `vercel dev` with a
container image needs a local daemon, which here means Colima.

## What still needs a Docker daemon

| Kind of project | Where it runs |
|---|---|
| Local Supabase development: projects, `templates/vercel-stack`, `templates/rn-supabase` | Colima locally; hosted Supabase when deployed |
| `templates/py-fastapi/production-ready`: Postgres + Redis via compose | Colima locally; Neon + Upstash when deployed |
| A project whose compose file only runs its Postgres | Native Postgres by default; the compose file stays optional |
| Compose stacks of an app plus Postgres or Mongo | When revived: Vercel + Neon or MongoDB Atlas |
| A Dockerfile that exists only for a hosting platform's build | Builds on that platform; no local daemon needed |
| The dotfiles restore test (`scripts/test/`): `docker run` in Debian | Colima locally, or a GitHub Actions job |

Which repo falls in which row is per-repo state, so it lives in the private companion
(`private/registers/containers.md`), not here.

## Cautions

- **`purge_dev_caches`** in `shell/.zshrc` runs `docker system prune -a --volumes -f`. With Colima
  running, that deletes every local Supabase database. Stop Colima first, or dump what you need.
- **Volumes never move between runtimes.** Before replacing or deleting a runtime, dump each database
  (`docker exec <container> pg_dump -Fc …`), then restore into the new one and compare row counts.
  Dumps go outside any git repo, mode 600.
- The weekly disk cleanup's `docker system prune -f` only runs when a daemon answers, so it is
  normally skipped. See [maintenance.md](maintenance.md#weekly-disk-cleanup).

## Checking the setup

```zsh
~/dev/dotfiles/scripts/containers-doctor.sh           # read-only; exit 1 on any FAIL
~/dev/dotfiles/scripts/containers-doctor.sh --quiet   # problems only
~/dev/dotfiles/test.sh containers                     # the doctor's own tests (hermetic, also run in CI)
```

The doctor checks, without changing anything, that:

- Docker Desktop is gone: no `Docker.app`, no `com.docker.socket` privileged helper, no symlinks into
  `Docker.app` in `/usr/local/bin` or `~/.docker/cli-plugins`;
- `~/.docker/config.json` is valid JSON, its `credsStore` isn't Docker Desktop's, and it points at
  the Homebrew plugin directory;
- the docker CLI and compose plugin work, and the context isn't `desktop-linux`;
- Colima is installed and does not start at login;
- the Supabase CLI is at least 2.110.0;
- PostGIS is available to `postgresql@17`.

---

## Decisions

### C1 — Docker Desktop replaced by Colima, started on demand · 2026-09-15

**Problem.** Docker Desktop was installed but not in use. Idle, its VM held about 8.2 GB of RAM and
used about four cores while its containers used about 15% of one, and its disk image was 18–31 GB. It
also left a privileged socket helper and CLI symlinks in `/usr/local/bin`.

**Decision.** Uninstall Docker Desktop. Use the Homebrew docker CLI and plugins against Colima
(Apple Virtualization.framework, virtiofs), started by hand and stopped after use, never at login.

**Rejected.** Keeping Desktop with smaller limits: still a heavyweight app whose VM holds its full
allocation while up. OrbStack: fastest, and returns memory to macOS dynamically, but closed source
with a paid licence for commercial use. Podman or Rancher Desktop: supported by Supabase, but more
moving parts than this needs.

**Cost.** No GUI. The Supabase CLI needed an upgrade to work on Colima; the doctor pins the minimum.
Volumes don't carry over, so the two databases worth keeping were dumped and restored, with matching
row counts.

### C2 — No remote Docker host; Vercel and hosted databases instead · 2026-09-15

**Problem.** Dockerized work was wanted off the laptop, and Vercel was already in use. Would Vercel do?

**Decision.** No VPS and no remote docker context. Apps deploy to Vercel; their databases are hosted
Supabase or Neon through the Vercel Marketplace. Docker-only projects move there when revived;
container tests run in GitHub Actions. Local Supabase development stays on Colima.

**Rejected.** A small VPS as a remote docker context: another server to patch, secure and pay for,
for work that isn't happening. Vercel as a Docker host: it isn't one, because its containers are
stateless functions that scale to zero.

**Cost.** Hosted Supabase's free plan allows two active projects and pauses idle ones. Anything that
needs a long-running container runs locally on Colima.

### C3 — Native Postgres for PostGIS work · 2026-09-15

**Problem.** A PostGIS project's only container was its database, and its tests need a live one.

**Decision.** Homebrew `postgresql@17` (already installed) plus `postgis`, started with
`brew services run`. Restored from a dump with identical per-table row counts; the project's tests
pass.

**Rejected.** Neon: tests would need the network, and free-tier compute is metered. The compose file
as the default: a whole VM for one database.

**Cost.** PostGIS moved from 3.5 to 3.6.4 on restore. Port 5432 is shared with any container that
publishes it.
