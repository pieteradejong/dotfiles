# `pwd-gen` — goal, threat model, and what to change next

`bin/pwd-gen` generates passwords and passphrases. Usage is in `pwd-gen --help`; the decisions
behind it are D38 (design), D82 (randomness tests) and D83 (hardening) in
[`design-decisions.md`](design-decisions.md).

## Goal

**Strong passwords that are almost impossible to hack, and easy to copy and paste into a web
form.** Those are the two goals, in that order. When they conflict, strength wins, but the default
must never be so awkward to paste that the user goes back to a weaker browser suggestion or an ad
hoc password.

"Almost impossible to hack" has three parts. Each is a different attacker, and each has its own
defence:

| # | Attacker | What they try | Defence |
|---|---|---|---|
| A | Guessing | Offline brute force against a leaked hash, at any speed money can buy | Enough entropy: the default is 122.4 bits (20 chars, 70 symbols, every class present). That is beyond any brute force, even against an unsalted fast hash. A passphrase needs 6+ words (77.5 bits) for an offline attack, and 8 words (103 bits) for a master password. |
| B | Generation-time tampering | Making the output predictable without changing how it looks: a planted module, a biased draw, a swapped wordlist, a tool edited in place | `secrets` (the OS CSPRNG) with no modulo bias. Every-class enforced by redrawing, never by fixed positions. `python3 -I` so nothing beside the script or on `PYTHONPATH` is imported. The shipped wordlist pinned by SHA-256. Chi-square tests on the real output (D82). |
| C | Leakage after generation | Reading the password where it was left: clipboard, scrollback, shell history, process list, logs | Never stored or logged, and never in `argv`. `--copy` prints nothing, and the clipboard is cleared after 30 s unless something else was copied since. The clearer holds only a SHA-256 of the password. |

"Easy to copy and paste":
- one line, no spaces;
- default symbols limited to `!@#$%*-_`, which almost every web form accepts (D64);
- a default length (20) under the usual 32–64 maximums;
- `--copy`, so there is nothing to select at all;
- `--no-symbols`, `--symbols SET` and `-l N` for sites with rules.

Out of scope: storing passwords (the password manager does that), checking a password someone
else chose, and attacks that already have code running as the user while the password is in use.
An attacker who can rewrite `bin/pwd-gen` itself wins. That is caught by git and the gate
(`git status`, `git diff`), not by the tool.

## Status against the goal

| Area | State | Where |
|---|---|---|
| Entropy, A | Met. 122.4 bits by default; the stderr line is exact | D38 |
| Uniform draws, B | Met and tested (exact chi-square, α ≈ 1e-9, power tests) | D82 |
| Planted modules / `PYTHONPATH`, B | Met. `#!/usr/bin/env -S python3 -I` | D83 |
| Swapped wordlist, B | Met. SHA-256 pin, a changed list exits 1 | D83 |
| Clipboard lingering, C | Met. Cleared after 30 s if unchanged (`--clear-after S`, `0` = never) | D83 |
| Scrollback, C | Partly. Plain `pwd-gen` prints to the terminal; only `--copy` avoids it | suggestion 1 |
| Clipboard managers and Universal Clipboard history, C | Open. The copy is not marked concealed | suggestion 2 |
| Weak output by mistake, A | Open. `-l 4` (20.3 bits) and `-w 1` (12.9 bits) are allowed silently under `-q` | suggestion 3 |
| Double-click selection, paste | Open. `!@#$%*` and `-` split a double-click selection | suggestion 4 |

## Suggested changes

In order of value for the goal. Each is open in `TODO.md` § Tooling until done.

1. **On a terminal, copy by default.** When stdout is a TTY and `--print` is not given, behave like
   `--copy`. When it is piped (`pwd-gen | …`), print as now. This keeps the password out of
   scrollback and iTerm2 session logs by default, which is the most common leak (C). The cost is a
   behaviour change for anyone used to seeing it printed, so `--print` must be the way back.
2. **Mark the clipboard copy as concealed.** Write the value with the pasteboard type
   `org.nspasteboard.ConcealedType` (and `org.nspasteboard.TransientType`). Clipboard managers that
   follow the nspasteboard.org convention then skip it. `pbcopy` cannot do this, but
   `osascript -l JavaScript` with the ObjC bridge can, with no new dependency. Check first whether
   Universal Clipboard respects it, and whether the 30 s clear reaches the other devices.
3. **A strength floor.** Below 80 bits, print a warning even under `-q`. Below 64 bits, refuse
   unless `--weak` is given. That stops a typo (`-l 4`, `-w 1`) from producing a guessable password
   with no visible sign (A).
4. **A double-click-safe symbol set.** Browsers and terminals treat only letters, digits and `_` as
   one word, so `-` and `!@#$%*` split a double-click selection. A `--select-safe` preset (letters,
   digits, `_` only: 63 symbols, 117.6 bits at 20 chars) makes manual copying one double-click. It
   matters only when `--copy` is not used, so suggestion 1 makes it less important.
5. **`--copy` with `-n` > 1.** Today it copies every candidate as one block, which pastes as a
   multi-line value. Refuse the combination, or copy only the first and print a count.
6. **Site rules as input.** Accept Apple's `passwordrules` syntax
   (`minlength: 16; maxlength: 24; required: lower; allowed: [-_]`), which many sites publish in
   their HTML. The generator then satisfies the rules exactly instead of being steered by hand with
   `-l` and `--symbols`.
7. **Passphrases that pass class rules.** `--site-safe` capitalises one word and appends a digit, so
   a passphrase gets through "must contain an uppercase letter and a number" forms. The extra
   entropy is counted honestly.

Not worth doing: wiping the password from memory (Python strings cannot be reliably cleared, and an
attacker who can read the process has already won), or NIST SP 800-22-style suites (they test the
OS CSPRNG, which is not in question; D82).
