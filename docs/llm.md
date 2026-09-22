# `llm` — run a prompt against a local model, never the cloud

`bin/llm`. Discovers whichever local inference backend is running, classifies the
models it finds into coder / reasoner roles **by name**, and routes each prompt to
one of them.

The zero-cloud guarantee is structural rather than a convention — see
[Zero-cloud guards](#zero-cloud-guards). The daemon-side half (how the local
server itself is bound and what egress was verified) is machine-specific and
deliberately not in this repo.

## Usage

```bash
llm "why is my sourdough flat?"      # auto-routed by intent
llm code "fix this regex"            # forced: coder model
llm reason "plan my week"            # forced: reasoner model

llm --list                           # backend, models, roles, what's resident
llm --dry-run "..."                  # show the routing decision, infer nothing
llm                                  # interactive REPL

git diff | llm code "review these"   # stdin is prepended as context
cat err.log | llm "what went wrong?"
```

## Routing, in priority order

1. `-m TAG` — an exact model, beats everything.
2. `code` / `reason` command — forces that role.
3. Only one model installed — use it regardless of role.
4. Code-intent heuristic on the prompt text — coder if it matches.
5. Otherwise — reasoner.

`code` / `reason` count as commands **only in the first prompt-word position**, so
the words remain usable in ordinary prompts:

| Invocation | Treated as |
|---|---|
| `llm code "fix this regex"` | command → coder |
| `llm -q code "..."` | command → coder (flags may come first) |
| `llm "code review this"` | prompt (one quoted word) → auto |
| `llm explain this code` | prompt (not the first word) → auto |
| `llm "the reason it fails"` | prompt → auto |

When the word *is* swallowed as a command, it names the role the prompt wanted
anyway — so the failure mode is benign by construction.

Roles are derived from model names, not a hardcoded tag list, so `ollama pull
<something>` routes correctly with no edit to the script:

| Name matches | Role |
|---|---|
| `coder`, `code`, `devstral`, `codestral`, `starcoder`, `codegemma`, `codellama` | coder |
| `r1`, `qwq`, `magistral`, `reason`, `thinking`, `deepthink` | reasoner |
| anything else | general |

## Options

| Flag | Effect |
|---|---|
| `-m`, `--model TAG` | force an exact model; errors if not available locally |
| `-s`, `--system TXT` | system prompt |
| `-t`, `--think` | stream the model's reasoning too (default: answer only) |
| `-l`, `--list` | backend, models, roles, resident model |
| `-q`, `--quiet` | suppress the stderr routing notes |
| `--dry-run` | print the routing decision and exit |
| `-h`, `--help` | usage |
| `--` | end of options; everything after is prompt text |

## Environment

| Variable | Meaning |
|---|---|
| `LLM_ENDPOINTS` | comma-separated `host:port` probe list. Loopback only. |
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
for the output filter (ships with macOS). A local backend must be running —
normally the Homebrew `ollama` service. Default probe targets are the stock
loopback ports: `11434` (Ollama), `1234` (LM Studio), `8080` (llama.cpp).

## Gotcha worth knowing

**Ollama 0.33.0 ignores `"think": false`.** `deepseek-r1` streams its reasoning in
a separate `.message.thinking` field regardless, so suppression happens
client-side in `llm`. The tokens are generated either way — hiding the reasoning
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
into this repo from an unversioned directory on 2026-09-22.
