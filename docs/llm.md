# `llm` — run a prompt against a local model, never the cloud

`bin/llm`. Discovers whichever local inference backend is running (starting the
Ollama daemon if it is down), gives each model a role from the lineup file or
else **by name**, and routes each prompt to one of them. It also installs and
manages the models, so it is the only command needed day to day.

The zero-cloud guarantee is structural rather than a convention — see
[Zero-cloud guards](#zero-cloud-guards). The daemon-side half (how the local
server itself is bound and what egress was verified) is machine-specific and
deliberately not in this repo.

## Usage

```bash
llm "why is my sourdough flat?"      # auto-routed by intent
llm code "fix this regex"            # forced: coder model
llm reason "plan my week"            # forced: reasoner model
llm fast "rename these vars"         # forced: fast coder (falls back to coder)

llm status                           # daemon, version skew, lockdown env, bind, disk, lineup
llm models                           # installed models, role, size (= --list)
llm update                           # install the lineup, remove the rest (asks first)
llm free                             # unload resident models, release their memory
llm restart                          # restart the Ollama daemon
llm --dry-run "..."                  # show the routing decision, infer nothing
llm                                  # interactive REPL

git diff | llm code "review these"   # stdin is prepended as context
cat err.log | llm "what went wrong?"
```

## Routing, in priority order

1. `-m TAG` — an exact model, beats everything.
2. `code` / `fast` / `reason` command — forces that role.
3. Only one model installed — use it regardless of role.
4. Code-intent heuristic on the prompt text — coder if it matches.
5. Otherwise — reasoner.

Command words (`code`, `fast`, `reason`, `status`, `models`, `update`, `free`,
`restart`) count as commands **only in the first prompt-word position**, so the
words remain usable in ordinary prompts:

| Invocation | Treated as |
|---|---|
| `llm code "fix this regex"` | command → coder |
| `llm -q code "..."` | command → coder (flags may come first) |
| `llm "code review this"` | prompt (one quoted word) → auto |
| `llm explain this code` | prompt (not the first word) → auto |
| `llm "the reason it fails"` | prompt → auto |
| `llm "status of the build"` | prompt (one quoted word) → auto |
| `llm status of the build` | error: `status` takes no prompt — never silently guessed |

When the word *is* swallowed as a command, it names the role the prompt wanted
anyway — so the failure mode is benign by construction.

## The lineup

`config/llm/lineup` declares which models this machine should have and which
role each plays, one `role tag download_GB` per line:

```
reasoner    qwen3.8:27b               18
coder       qwen3.6:27b-coding        18
```

Roles: `coder` (`llm code`), `fast` (`llm fast`), `reasoner` (`llm reason`, and
non-code prompts), `general`. The first listed model of a role gets it. A
missing role borrows the nearest one (`fast` → `coder`, `reasoner` → `general`).
`:cloud` tags and unknown roles are hard errors. `LLM_LINEUP` points elsewhere.

`llm update` makes the machine match it. This is acquire mode, the one command
that downloads:

1. Shows the plan (pulls, removals, disk before and after) and refuses it if it
   would leave less than `LLM_MIN_FREE_GB` (default 15) free.
2. Asks once (`--yes` skips the prompt, `--dry-run` stops after the plan).
3. Pulls one model at a time. Before each pull it removes models that are not in
   the lineup until the pull fits, so the disk never fills mid-download.
4. Checks each pulled model through `/api/show`: it must have no `remote_host`
   and a `FROM /…` local blob. If not, the model is deleted again and `update`
   stops.

To change models, edit the lineup, then run `llm update`.

Models that aren't in the lineup (an ad-hoc `ollama pull`) are classified by name
and routed anyway, but the next `llm update` offers to remove them:

| Name matches | Role |
|---|---|
| `coder`, `code`, `coding`, `devstral`, `codestral`, `starcoder`, `codegemma`, `codellama` | coder |
| `r1`, `qwq`, `magistral`, `reason`, `thinking`, `deepthink` | reasoner |
| anything else | general |

## Options

| Flag | Effect |
|---|---|
| `-m`, `--model TAG` | force an exact model; errors if not available locally |
| `-s`, `--system TXT` | system prompt |
| `-t`, `--think` | stream the model's reasoning too (default: answer only) |
| `-l`, `--list` | same as `llm models` |
| `-q`, `--quiet` | suppress the stderr routing notes |
| `-y`, `--yes` | `llm update` proceeds without asking |
| `--dry-run` | print the routing decision (or the update plan) and exit |
| `-h`, `--help` | usage |
| `--` | end of options; everything after is prompt text |

## Environment

| Variable | Meaning |
|---|---|
| `LLM_ENDPOINTS` | comma-separated `host:port` probe list. Loopback only. Setting it also disables auto-start. |
| `LLM_LINEUP` | lineup file (default `config/llm/lineup` beside `bin/`) |
| `LLM_MIN_FREE_GB` | disk that must stay free after a pull (default 15) |
| `LLM_NO_AUTOSTART` | never start the daemon when it is down |
| `LLM_FREE_GB` | test hook: pretend this much disk is free |
| `LLM_MLX_MODEL` | model path/id for the mlx-lm fallback backend |
| `OLLAMA_HOST` | honoured for the Ollama probe. Loopback only — a remote value is a hard error, not a silent fallback. |

Deliberately **not** read: `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, or any other
`*_API_KEY`.

## Zero-cloud guards

Enforced in the script itself, independently of any daemon-side lockdown:

- every endpoint must resolve to loopback, or it's a hard error;
- any model tag containing `cloud` as a word is refused;
- no API key is ever read or forwarded (local servers that demand a header get a
  literal `Authorization: Bearer local`).

Each of these has a test in `scripts/test-bin.sh`, including a canary assertion
that an exported `OPENAI_API_KEY` never reaches an outbound request.

## Requirements

`curl` and `jq` (checked at startup, with a `brew install jq` hint), plus `perl`
for the output filter (ships with macOS). The backend is normally the Homebrew
`ollama` service. If nothing answers and `LLM_ENDPOINTS` is unset, `llm` runs
`brew services start ollama` and waits up to 20 s. The idle daemon costs a few MB
of RAM and no CPU. Memory goes to a model only while it is loaded, until
`OLLAMA_KEEP_ALIVE` expires or `llm free`. Default probe targets are the stock
loopback ports: `11434` (Ollama), `1234` (LM Studio), `8080` (llama.cpp).

Homebrew renamed the service's launchd label from `homebrew.mxcl.ollama` to
`sh.brew.ollama` (seen 2026-10-06). `llm status` reads either.

## Gotcha worth knowing

**`"think": false` is not always honoured.** Ollama 0.33.0 let `deepseek-r1`
stream its reasoning in a separate `.message.thinking` field regardless, so
suppression happens client-side in `llm`. The tokens are generated either way — hiding the reasoning
is a display choice, not a speedup, and `llm reason` is slow either way.

## Name collision to be aware of

`llm` is also the name of Simon Willison's widely-used CLI (`brew install llm` /
`pip install llm`). Nothing by that name is installed here, so the name is free —
but if it ever is, whichever directory comes first in `PATH` wins.

## History

Replaces two earlier things, both **deleted** rather than aliased, so there is
exactly one entry point:

- `ollm.zsh` — a zsh *function* with model tags hardcoded in it. Went stale
  whenever the lineup changed, and being a function it couldn't be used in a pipe
  or a non-interactive shell.
- `ailocal` — this same script under its original name, which forced the role
  through `--code` / `--reason` flags instead of commands.

Renamed 2026-09-07; `AILOCAL_*` env vars became `LLM_*` at the same time. Moved
into this repo from an unversioned directory on 2026-09-22. Gained the lineup
file and the `status` / `models` / `update` / `free` / `restart` commands, plus
auto-start, on 2026-10-06.
