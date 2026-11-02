# CLAUDE.md — `~/dev/templates`

Copied from `~/dev/dotfiles/claude/templates-CLAUDE.md`; edit there, then copy here
(`scripts/test-docs.py` checks the pair). Workspace rules: `~/dev/CLAUDE.md`.

Five curated stacks. Three have `minimal-mvp` and `production-ready` variants; `rn-supabase` and
`vercel-stack` are single production-oriented layouts (`templates/DEPENDENCY_MATRIX.md`).

| Stack | Dir | Variants | Description |
|---|---|---|---|
| Python FastAPI | `templates/py-fastapi/` | minimal-mvp, production-ready | REST API, Pydantic; optional PostgreSQL/Redis/JWT |
| TypeScript React | `templates/ts-web/` | minimal-mvp, production-ready | Vite + React; optional Tailwind/React Query/Vitest |
| Node.js Express | `templates/node-express/` | minimal-mvp, production-ready | Express + TypeScript; optional PostgreSQL/Docker |
| React Native + Supabase | `templates/rn-supabase/` | single | Expo + Supabase auth and database |
| Next.js on Vercel | `templates/vercel-stack/` | single | Next.js App Router + Supabase auth/Postgres |

```bash
cd templates/<stack>/<variant>   # or templates/rn-supabase
./init.sh        # venv or node_modules; .env from template
./run.sh         # dev server (default)
./run.sh build   # production build
./run.sh test    # tests (production-ready variants)
./run.sh lint    # linters
./run.sh format  # auto-format
```

Production-ready variants add `./run.sh prod`, `./run.sh debug`, `./run.sh type-check`.

Dev servers: py-fastapi `http://localhost:8000` (docs at `/docs`) · ts-web `http://localhost:5173` ·
node-express `http://localhost:3000` · vercel-stack `http://localhost:3000` (don't run with
node-express) · rn-supabase: Expo QR code, `w` for web.

- **py-fastapi/production-ready** needs a running Docker daemon — `colima start` first (PostgreSQL + Redis); `./run.sh` runs `alembic upgrade head`.
- **rn-supabase** needs Node 24 (`.nvmrc`), the Supabase CLI and a running Docker daemon (`colima start`); `./init.sh` starts local Supabase at `http://localhost:54321`. Every check: `./test.sh` (`--integration` for the live Supabase round-trip, `--scaffold` for the new-app test). Releases: its `docs/RELEASE.md`.
- Every template ships `.github/workflows/ci.yml`; it runs once the new project is pushed.
- Scaffold by copying the directory; don't change dependency versions until `./init.sh` succeeds.
  **`rn-supabase` is its own git repo** (private `rn-supabase-template`): create a new app with
  `templates/rn-supabase/scripts/scaffold.sh <app-dir>` (copies without `.git`, `node_modules`, env
  files or local Supabase state; a plain copy that keeps `.git` is refused by its `init.sh`).
- **node-express/production-ready** needs a running Docker daemon for anything that touches the
  database (`colima start`, then `docker compose up -d db redis` and `./run.sh migrate`); its unit
  and supertest tests run without one. Repaired 2026-10-17 (`templates/AUDIT_2026-10-17.md`).
- **Not templates:** `general/`, `py-django/`, `py-flask/`, `py-fullstack/`, `ts-server/`,
  `rn-supabase-legacy/` and the `base-app` / `base-api` / `framework-base` subdirs are separate
  repos with their own remotes, several with uncommitted work. Don't scaffold from them and don't
  include them in sweeps over `templates/`. Per-directory state: `templates/INVENTORY.md`.
  `templates/` itself is not a git repo; of the curated templates only `rn-supabase` is one.
