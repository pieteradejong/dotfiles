# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

This is a personal development workspace containing many independent projects under `/projects/` and a reusable template system under `templates/`.

## Templates System (`templates/`)

Four stacks, each with `minimal-mvp` and `production-ready` variants:

| Stack | Dir | Description |
|-------|-----|-------------|
| Python FastAPI | `templates/py-fastapi/` | REST API with Pydantic, optional PostgreSQL/Redis/JWT |
| TypeScript React | `templates/ts-web/` | Vite + React, optional Tailwind/React Query/Vitest |
| Node.js Express | `templates/node-express/` | Express + TypeScript, optional PostgreSQL/Docker |
| React Native + Supabase | `templates/rn-supabase/` | Expo + Supabase auth and database |

### Universal workflow

```bash
cd templates/<stack>/<variant>
./init.sh        # set up venv or node_modules, create .env from template
./run.sh         # start dev server (default command)
./run.sh build   # production build
./run.sh test    # run tests (production-ready variants only)
./run.sh lint    # run linters
./run.sh format  # auto-format code
```

Production-ready variants additionally support `./run.sh prod`, `./run.sh debug`, `./run.sh type-check`.

### Stack-specific dev servers

- **py-fastapi**: `http://localhost:8000` — API docs at `/docs`
- **ts-web**: `http://localhost:5173`
- **node-express**: `http://localhost:3000`
- **rn-supabase**: Expo QR code; press `w` for web

### Production stack extras

- **py-fastapi/production-ready**: requires Docker for PostgreSQL + Redis; `./run.sh` auto-runs `alembic upgrade head` on start
- **rn-supabase/production-ready**: requires Supabase CLI; `./run.sh` starts local Supabase stack at `http://localhost:54321`

## Dependency management

All templates use exact version pinning (no `^` or `~`). Proven stable combinations are documented in `templates/DEPENDENCY_MATRIX.md`. System requirements: Python 3.11+, Node.js 18+, npm 8+, Docker 20+ (production templates).

When creating new projects from templates, copy the template directory and do not modify dependency versions until after running `./init.sh` successfully.

## Python linting & formatting (production-ready)

```bash
./run.sh lint    # black --check + ruff check + mypy
./run.sh format  # black + ruff --fix
```

## TypeScript linting & formatting

```bash
./run.sh lint         # ESLint
./run.sh lint:fix     # ESLint with auto-fix
./run.sh format       # Prettier
./run.sh type-check   # tsc --noEmit
```
