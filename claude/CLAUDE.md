# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## System

- **OS**: macOS 26.4.1 (Darwin 25.4.0), Apple Silicon ARM64 (M1 Pro, T6000)
- **Hardware**: 10 CPU cores, 32 GB RAM
- All binaries should be ARM64-native unless a specific x86 tool is required. Avoid suggesting Rosetta workarounds unless necessary.

## Shell & Terminal

- **Shell**: zsh 5.9 with oh-my-zsh and Powerlevel10k theme
- **Terminal**: iTerm2 3.6.10
- Use `zsh`-compatible syntax in all shell scripts and commands. Avoid bash-isms.
- The `zsh` git plugin is active — aliases like `gst`, `gco`, `gcmsg` are available.

## Package Managers

| Manager | Version | Use for |
|---------|---------|---------|
| Homebrew | 5.1.8 | macOS system packages |
| npm | 11.7.0 | Node.js packages (default) |
| pnpm | 10.26.1 | Node.js (prefer when already in use in a project) |
| yarn | 1.22.22 | Node.js (use only if project already uses it) |
| pip / pip3 | 26.1 | Python packages |
| gem | 3.0.3.1 | Ruby gems |

Prefer `brew` for system-level installs. For Node projects, default to `npm` unless the project already uses `pnpm` or `yarn`. Never mix package managers within a single project.

## Languages & Runtimes

| Language | Version | Path |
|----------|---------|------|
| Node.js | 22.16.0 | managed via nvm 0.40.3 |
| Python | 3.14.4 | `/opt/homebrew/bin/python3` |
| Go | 1.20.3 | system |
| Swift | 6.2.1 | Xcode toolchain |
| Ruby | 2.6.10 | system (macOS built-in) |
| Java | OpenJDK 17.0.1 | system |
| PHP | 8.5.5 | Homebrew |

Node versions are managed with **nvm** — when suggesting Node version changes or `.nvmrc` files, use nvm commands. Python is Homebrew-managed (3.14); always use `python3`, never `python`. Ruby 2.6 is the system fallback — for new projects, check if a newer Homebrew Ruby is needed.

## Key Dev Tools

| Tool | Version |
|------|---------|
| git | 2.54.0 |
| gh (GitHub CLI) | 2.92.0 |
| Docker | 25.0.3 |
| Docker Compose | v2.24.5 |
| kubectl | v1.29.1 |
| Terraform | v1.14.9 |
| Supabase CLI | 2.95.4 |
| jq | 1.8.1 |
| curl | 8.7.1 |
| wget | 1.25.0 |

Docker Desktop is installed — prefer `docker compose` (v2, no hyphen) over the legacy `docker-compose`. The GitHub CLI (`gh`) is available for PR/issue operations.

## Editors & IDEs

- **VS Code** 1.96.0 — `code` command available in PATH
- **Cursor** 3.2.18 — `cursor` command available
- **Sublime Text** Build 4200 — `subl` command available
- **Vim** 9.1 — available as `vim` and `vi`

When opening files or projects for the user, prefer `code` unless the user indicates otherwise.

## Paths & Environment

- Homebrew prefix: `/opt/homebrew` (ARM64 location)
- Custom scripts: `~/scripts` is in PATH
- When constructing paths to Homebrew tools, use `/opt/homebrew/bin/` not `/usr/local/bin/`
