# archive

Retired material, kept so it can be found without digging through git history. Nothing here is
loaded, sourced, scheduled or linked from an active doc, and nothing here is maintained. To bring
something back, copy it out and treat it as new work.

Add a row when something is retired: what, when, why, and what replaced it.

| What | Retired | Why | Replaced by |
|---|---|---|---|
| Branch `document-practices` (tag `archive/document-practices-2026-09-27`, in this repo and in `private/`) | 2026-09-30 | A documentation pass that expanded the policy docs, added decisions D25–D31 and a doc-coverage test. Judged overengineering against the two goals in the README. | Its concrete fixes were kept: the npm/Docker credential scrub, `sanitize_copy` keeping old copies, snapshot outputs out of `docs/`, the `.zshrc.secret` name. `git show archive/document-practices-2026-09-27` to read the rest |
| `bin/mail-report` and `scripts/test-mail-report.py` (now `archive/mail-report`, `archive/test-mail-report.py`) | 2026-11-09 | Mailed the maintenance reports over Gmail SMTP. It was never configured on this Mac, so every run since 2026-10-18 logged `report not mailed (exit 3)`, and Pieter wants no external service in the maintenance path (D60). | A local macOS notification (`bin/notify-local`), a status line at session start (`bin/maintenance-status`), and the dashboard Self-check table |
