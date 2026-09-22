# AI assistant instructions

How instruction files for AI coding assistants are layered in this workspace, and what goes where.
Written against Claude Code's `CLAUDE.md`; the layering applies to any assistant that reads a
per-directory instruction file.

---

## Layers

All loaded files apply together; a more specific one adds to the broader ones.

| Layer | File | Holds |
|---|---|---|
| Global | `~/.claude/CLAUDE.md` | Machine facts: OS, shell, toolchain versions, package-manager preferences |
| Workspace | `~/dev/CLAUDE.md` | Rules for every project: hard rules, do-not-touch, session workflow, templates, where policy lives |
| Project | `<project>/CLAUDE.md` | Exact commands and non-obvious conventions for one project |
| Private import | `@path/to/file.md` from any of the above | Material that must not be committed with the importing file |
| Memory | `~/.claude/projects/<workspace-slug>/memory/` | Things that became true while working (see below) |

- **Discovery walks up.** A session started in `~/dev/projects/x` loads the global file, then
  `~/dev/CLAUDE.md`, then `projects/x/CLAUDE.md`. Never repeat a parent's rule in a child.
- **Downward is lazy.** Files in subdirectories load only when a file in that subtree is read or
  edited — a deep `CLAUDE.md` costs nothing until it is relevant.
- **Precedence is specificity.** No override keyword exists; write child files as deltas ("this
  project is the exception to exact pinning because …"), never as weaker restatements.
- **Length costs every request.** A short file that is entirely load-bearing beats a thorough one.

## `AGENTS.md` is a symlink

Other tools read `AGENTS.md`. Never keep two copies:

```zsh
ln -s CLAUDE.md AGENTS.md
```

Edit `CLAUDE.md` only. Word the header so it reads correctly for either tool.

## Imports and private material

- `@relative/path.md` (or `@~/path.md`) on its own line pulls a file in, recursively up to five levels.
  An `@` inside a code span or fenced block is not an import.
- Put private or personal instructions in a gitignored or separate private file and import it.
  `CLAUDE.local.md` is deprecated and doesn't survive worktrees.
- The workspace file imports the do-not-touch register from the private companion repo. Always
  give a fallback instruction for when the imported file is missing.

## What belongs in an instruction file

**Belongs:** exact commands; conventions not inferable from the code; hard prohibitions (files not
to touch, operations not to run); non-obvious environment facts (a required service, env var, port).

**Does not belong:** anything the code, git history or an existing doc already says (a restated
tree is stale in a week); secrets or personal values; speculative rules for work not yet started;
project state or pending decisions (that's memory).

## `CLAUDE.md` vs memory

| | `CLAUDE.md` | Memory |
|---|---|---|
| Origin | Authored deliberately | Accumulated from conversation |
| Location | In the repo, usually committed | Outside the repo, machine-local |
| Loads | Every session in scope | Recalled when relevant |
| Content | True because it was decided | True because it happened while working |

**The test: would this fact survive a fresh clone by someone else?** Build commands, licensing
policy, do-not-touch rules → `CLAUDE.md`. A pending decision, a correction to how the assistant
works, the state of an in-flight migration → memory. Project state in `CLAUDE.md` goes stale where
everyone reads it; a durable rule left in memory is invisible to every other tool and machine.

## Where a new piece of guidance goes

| What you have | Where it goes |
|---|---|
| A command for one project | That project's `CLAUDE.md` § Commands |
| A rule for all projects | A policy doc under `dotfiles/docs/policy/`; a one-line hard rule in `~/dev/CLAUDE.md` if it must load every session |
| A machine or toolchain fact | `~/.claude/CLAUDE.md` |
| A correction about how the assistant works | Memory (feedback), with the why |
| Ongoing project state or a pending decision | Memory (project), with absolute dates |
| A finding, or state naming a real repo | Private companion repo register |
| A long-form investigation | A dated report in the private companion repo |
| Repeated approval prompts for a safe command | That project's `.claude/settings.local.json` |
| "Every time X happens, do Y" | A hook, not an instruction |
| Anything already stated elsewhere | Nowhere — link to it |

## Instructions vs hooks

An instruction shapes a decision; it cannot guarantee an action fires. A rule sat in `CLAUDE.md`
for months ("a public repo publishes the committer email") with no check behind it, and the
exposure accumulated anyway. Anything mechanical — block a command, run a formatter, refuse a
bypass — needs a hook in `settings.json` or a git-level check. The git gate and the
[assistant guardrail](security-and-privacy.md#14-assistant-guardrails) are that layer for security.

| Settings file | Scope |
|---|---|
| `~/.claude/settings.json` | All projects |
| `<project>/.claude/settings.json` | That project, committed |
| `<project>/.claude/settings.local.json` | That project, personal, gitignored |

Permission allowlists govern trust, not instructions — extend one when the same safe command keeps
prompting.

## Per-project files are lazy

Create a project `CLAUDE.md` when the project is a git repo with real build/test/lint tooling, or
when substantive work in it starts. Skip one-off scripts, dormant experiments, forks and upstream
clones. **Never batch-generate them:** a file written from a tree scan by someone who hasn't worked
in the code makes confident, generic, often wrong claims that get trusted — worse than none. Shape:
[repo standards](repo-standards.md#per-project-claudemd-shape).

An instruction file that looks out of place in code you didn't write is usually load-bearing (a
project may deliberately use `CLAUDE.md` for something else). Read the project README before
"fixing" it.

## Decisions need verification

A decision record is not evidence that the work happened. A repo once stayed public for a day after
a log recorded, with the exact command, the decision to make it private — the prose read as done.

- Every decision, remediation or "done" entry carries a **`Verified:` line with the command run
  and its actual output**. `Verified: NOT YET` is an open item; no `Verified:` line is an open item
  pretending not to be.
- Verify the change itself, not a document describing it. Prefer the authoritative check (an
  anonymous fetch of a URL over an API field that may be stale).
- Decision logs are append-only: supersede an entry with a new one that links back.
- Where same-day verification is only partial (a scheduled job), say `PARTIAL` and name when to recheck.

An entry is owed when a choice closes off an alternative someone could reasonably reopen — not for
every commit. The shape, numbered and appended:

```
## N. <what was decided>
**Date:** YYYY-MM-DD
**Context:** why this came up
**Decision:** what was chosen, and what was rejected
**Verified:** the command run and what it returned, or NOT YET
```

Which log: security and privacy decisions go in `docs/design-decisions.md`; a project's own
decisions go in a `DECISIONS.md` at its root; everything else about this workspace — including
anything naming a specific repo or exposure — goes in the private companion repo's `DECISIONS.md`.

## One source of truth for assistant config

Copies of instruction files drift. Keep the dotfiles copies of `~/.claude/CLAUDE.md` and the
workspace `CLAUDE.md` as the source and symlink the live locations to them, rather than copying in
either direction.
