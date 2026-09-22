# `bin/` — executables on `PATH`

This directory is on `PATH`, set in `shell/.zshrc`:

```zsh
export PATH="$HOME/dev/dotfiles/bin:$PATH"
```

Everything here is executable and self-contained; nothing needs `source`-ing from
a shell rc file. Files are run **in place** out of the repo — there is no second
copy in `~` to keep in sync, so an edit here takes effect immediately. That is the
opposite of most of this repo, where the live file in `~` is what the system reads
and the repo holds a copy (see [docs/system-overview.md](../docs/system-overview.md)).

| Script | What it is |
|---|---|
| [`llm`](../docs/llm.md) | Run a prompt against a local model. Never the cloud. |
| `weekly-disk-cleanup.sh` | Reclaims disk from caches, build dirs and Trash older than 7 days. Runs weekly via launchd, which points at this path. See [docs/maintenance.md](../docs/maintenance.md). |

## `bin/` vs `scripts/`

`scripts/` is management tooling for this repo itself — `sync-dotfiles.sh`,
`dev-audit.sh`, the `test-*.sh` suites. It is deliberately **not** on `PATH`;
putting it there would turn every one of those into a global command.

`bin/` is the PATH directory: general-purpose commands meant to be typed.

## Testing

`zsh -n` syntax checks plus behavioral tests run from the repo root:

```zsh
./test.sh zsh-syntax
./test.sh bin
```

These scripts are zsh, so they are not covered by the `shellcheck` suite —
shellcheck does not parse zsh. `weekly-disk-cleanup.sh` is never executed by the
tests (it deletes things); it is asserted statically instead.

