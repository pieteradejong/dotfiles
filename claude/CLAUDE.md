# CLAUDE.md

Global guidance for Claude Code on this Mac: the machine, its tools, and conventions that hold in every
project. Workspace rules are in `~/dev/CLAUDE.md`. Versions are major.minor on purpose, and
`~/dev/dotfiles/scripts/claude-md-check.py` checks them against what is installed (`--apply` updates them).

## System

- **OS**: macOS 27.0 (Darwin 27.0), Apple Silicon ARM64 (M1 Pro, T6000)
- **Hardware**: 10 CPU cores, 32 GB RAM
- All binaries should be ARM64-native unless a specific x86 tool is required. Avoid suggesting Rosetta workarounds unless necessary.

## Shell & Terminal

- **Shell**: zsh 5.9 with oh-my-zsh and Powerlevel10k theme
- **Terminal**: iTerm2 3.6.10
- Commands typed at the prompt: `zsh`-compatible syntax. Committed scripts: `#!/usr/bin/env bash`,
  bash 3.2-compatible (macOS `/bin/bash`), unless a project says otherwise — the convention in
  `~/dev/dotfiles/docs/design-decisions.md` D21 and `repo-standards.md`.
- The `zsh` git plugin is active — aliases like `gst`, `gco`, `gcmsg` are available.

## Package Managers

| Manager | Version | Use for |
|---------|---------|---------|
| Homebrew | 7.0 | macOS system packages |
| npm | 11.19 | Node.js packages (default) |
| pnpm | not installed | Node.js (prefer when already in use in a project) |
| yarn | not installed | Node.js (use only if project already uses it) |
| pip / pip3 | 26.2 | Python packages |
| cargo | not installed | Rust crates |
| gem | 3.0 | Ruby gems |

Prefer `brew` for system-level installs. For Node projects, default to `npm` unless the project already uses `pnpm` or `yarn`. Never mix package managers within a single project.

## Languages & Runtimes

| Language | Version | Path |
|----------|---------|------|
| Node.js | 26.7 | managed via nvm 0.40.3 |
| Python | 3.15 | `/opt/homebrew/bin/python3` |
| Go | 1.20 | system |
| Rust | not installed | via cargo |
| Swift | 6.4 | Xcode toolchain |
| Ruby | 2.6 | system (macOS built-in) |
| Java | OpenJDK 17.0 | system |
| PHP | 8.5 | Homebrew |

Node versions are managed with **nvm** — when suggesting Node version changes or `.nvmrc` files, use nvm commands. Python is Homebrew-managed (3.15); always use `python3`, never `python`. Ruby 2.6 is the system fallback — for new projects, check if a newer Homebrew Ruby is needed.

## Key Dev Tools

| Tool | Version |
|------|---------|
| git | 2.56 |
| gh (GitHub CLI) | 2.103 |
| Docker CLI (Homebrew) | 29.9 |
| Docker Compose plugin | 5.6 |
| Colima | 0.10 |
| kubectl | v1.37 |
| Terraform | not installed |
| Supabase CLI | 2.122 |
| jq | 1.8 |
| curl | 8.7 |
| wget | 1.25 |

Docker Desktop is **not** installed. Containers run on **Colima**, started on demand (`colima start`, then `colima stop` when done); nothing container-related starts at login. Prefer `docker compose` (plugin, no hyphen) over the legacy `docker-compose`. Local Postgres for non-Supabase projects is native Homebrew `postgresql@17` + `postgis`, not a container. Details: `~/dev/dotfiles/docs/containers.md`. The GitHub CLI (`gh`) is available for PR/issue operations.

## Editors & IDEs

- **VS Code** 1.96.0 — `code` command available in PATH
- **Cursor** 3.2.18 — `cursor` command available
- **Sublime Text** Build 4200 — `subl` command available
- **Vim** 9.1 — available as `vim` and `vi`

When opening files or projects for the user, prefer `code` unless the user indicates otherwise.

## Paths & Environment

- Homebrew prefix: `/opt/homebrew` (ARM64 location)
- Custom scripts: `~/dev/dotfiles/bin` is in PATH (commands are run in place from the repo)
- When constructing paths to Homebrew tools, use `/opt/homebrew/bin/` not `/usr/local/bin/`
