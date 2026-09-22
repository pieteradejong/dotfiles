#!/usr/bin/env bash
#
# test-security-tools.sh — tests for everything around the gate:
#
#   claude/hooks/guard-git-bypass.sh    the assistant cannot switch the gate off
#   scripts/github-security-sweep.sh    GitHub settings sweep (stub gh, no network)
#   scripts/security-audit.sh           the weekly audit (--quick, stub gh)
#   scripts/audit/50-gate.sh            dotaudit's gate module
#   scripts/sync-dotfiles.sh            the sanitizers that keep personal values
#                                       out of this PUBLIC repo on the way in
#
# Run: ./scripts/test-security-tools.sh [--verbose]     Exit: 0 all passed, 1 otherwise.
#
# shellcheck disable=SC2015 # `cond && pass || fail` is safe here: pass/fail always return 0

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
VERBOSE=false
[ "${1:-}" = "--verbose" ] && VERBOSE=true

RED="\033[31m"; GREEN="\033[32m"; CYAN="\033[36m"; BOLD="\033[1m"; NC="\033[0m"
PASS_COUNT=0; FAIL_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}✗ FAIL${NC}: $1"
  if [ -s "$OUT" ]; then if $VERBOSE; then sed 's/^/      | /' "$OUT"; else sed 's/^/      | /' "$OUT" | head -20; fi; fi
}
header() { echo ""; echo -e "${BOLD}${CYAN}── $1 ──${NC}"; }

T="$(mktemp -d "${TMPDIR:-/tmp}/security-tools-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
OUT="$T/out"; : > "$OUT"
REAL_PATH="$PATH"
first() { local f; for f in "$@"; do [ -e "$f" ] && { printf '%s' "$f"; return 0; }; done; return 1; }

# ================================================================================
header "guard-git-bypass.sh (Claude Code PreToolUse hook)"
GUARD="$DOTFILES_DIR/claude/hooks/guard-git-bypass.sh"
guard() { # <expected exit> <command string>
  local want="$1" c="$2" rc json
  if command -v jq >/dev/null 2>&1; then json="$(jq -n --arg c "$c" '{tool_name: "Bash", tool_input: {command: $c}}')"
  else json="{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$c\"}}"; fi
  printf '%s' "$json" | "$GUARD" > "$OUT" 2>&1; rc=$?
  if [ "$rc" = "$want" ]; then pass "$([ "$want" = 2 ] && echo denies || echo allows): $c"
  else fail "$([ "$want" = 2 ] && echo 'should deny' || echo 'should allow'): $c (exit $rc)"; fi
}
guard 2 'git commit --no-verify -m x'
guard 2 'git push --no-verify origin main'
guard 2 'git commit --no-veri -m x'
guard 2 "git commit '--no-verify' -m x"
guard 2 'git commit -nm "msg"'
guard 2 'git commit -n'
guard 2 'git -C repo commit -an -m x'
guard 2 'cd repo && git commit -m x -n'
guard 2 'SECURITY_GATE_BYPASS="because" git push'
guard 2 'export SECURITY_GATE_BYPASS=x'
guard 2 'SECURITY_GATE_CACHE_DIR=/tmp git push'
guard 2 'git config --global core.hooksPath /tmp/h'
guard 2 'git -c core.hooksPath=/dev/null commit -m x'
guard 2 'git config hook.security-gate-commit.enabled false'
guard 2 'git -c hook.security-gate-push.enabled=false push'
guard 2 'git config --global --unset-all hook.security-gate-commit.command'
guard 2 'git config --global --remove-section hook.security-gate-commit'
guard 2 'GIT_CONFIG_GLOBAL=/dev/null git commit -m x'
guard 2 'GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=x GIT_CONFIG_VALUE_0=y git push'
guard 2 'HOME=/tmp git commit -m x'
guard 2 '/usr/bin/git commit -m x'
guard 0 'git commit -m "fix -n flag parsing"'
guard 0 "git commit -m 'document --no-verify in the policy'"
guard 0 'git commit -m x'
guard 0 'git commit --amend --no-edit'
guard 0 'git push origin main'
guard 0 'git log --oneline -n 5'
guard 0 'git status'
guard 0 'git hook list pre-commit'
guard 0 'git commit-tree HEAD^{tree} -m x'
guard 0 '/opt/homebrew/bin/git commit -m x'
guard 0 'grep -rn -- --no-verify docs'
guard 0 'npm run build -- -n'
guard 0 'ls -la'
printf '{"tool_name":"Read","tool_input":{"file_path":"/x"}}' | "$GUARD" > "$OUT" 2>&1 && pass "allows non-Bash tool input" || fail "non-Bash tool input was denied"
printf '%s' '{"tool_name":"Bash","tool_input":{"command":"git commit --no-verify"}}' | "$GUARD" > "$OUT" 2>&1
grep -q 'Blocked by guard-git-bypass' "$OUT" && pass "denial explains itself on stderr" || fail "denial message missing"

# ================================================================================
header "github-security-sweep.sh (stub gh)"
SWEEP="$DOTFILES_DIR/scripts/github-security-sweep.sh"
S="$T/sweep"; mkdir -p "$S/bin" "$S/state" "$S/out"
printf 'skip:do-not-touch:fixture\n' > "$S/skiplist.conf"
# State per repo: ss (secret scanning+push protection) and dep (alerts).
printf 'enabled\tenabled\n'         > "$S/state/pub-ok.ss";      echo enabled  > "$S/state/pub-ok.dep"
printf 'disabled\tdisabled\n'       > "$S/state/pub-drift.ss";   echo disabled > "$S/state/pub-drift.dep"
printf 'unavailable\tunavailable\n' > "$S/state/priv.ss";        echo disabled > "$S/state/priv.dep"
printf 'unavailable\tunavailable\n' > "$S/state/do-not-touch.ss"; echo disabled > "$S/state/do-not-touch.dep"
cat > "$S/bin/gh" <<EOF
#!/bin/bash
echo "\$*" >> "$S/calls"
st="$S/state"
case "\$*" in
  "auth status"*) exit 0 ;;
  "repo list"*)
    printf 'pub-ok\towner/pub-ok\tPUBLIC\tfalse\tfalse\towner\n'
    printf 'pub-drift\towner/pub-drift\tPUBLIC\tfalse\tfalse\towner\n'
    printf 'priv\towner/priv\tPRIVATE\tfalse\tfalse\towner\n'
    printf 'a-fork\towner/a-fork\tPUBLIC\ttrue\tfalse\towner\n'
    printf 'old\towner/old\tPUBLIC\tfalse\ttrue\towner\n'
    printf 'do-not-touch\towner/do-not-touch\tPRIVATE\tfalse\tfalse\towner\n'
    printf 'theirs\tsomeone/theirs\tPUBLIC\tfalse\tfalse\tsomeone\n'
    exit 0 ;;
  "api -X PATCH repos/owner/"*) r="\${4#repos/owner/}"; printf 'enabled\tenabled\n' > "\$st/\$r.ss"; exit 0 ;;
  "api -X PUT repos/owner/"*"/vulnerability-alerts"*) r="\${4#repos/owner/}"; r="\${r%/vulnerability-alerts}"; echo enabled > "\$st/\$r.dep"; exit 0 ;;
  "api repos/owner/"*"/vulnerability-alerts"*) r="\${2#repos/owner/}"; r="\${r%/vulnerability-alerts}"; [ "\$(cat "\$st/\$r.dep")" = enabled ]; exit \$? ;;
  "api repos/owner/"*) r="\${2#repos/owner/}"; cat "\$st/\$r.ss"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$S/bin/gh"
sweep() { PATH="$S/bin:$REAL_PATH" SKIPLIST_FILE="$S/skiplist.conf" "$SWEEP" --owner owner --out "$S/out" "$@" > "$OUT" 2>&1; }

: > "$S/calls"; sweep; rc=$?
[ "$rc" = 0 ] && pass "dry run exits 0" || fail "dry run exit $rc"
grep -q 'owner/pub-drift.*would change' "$OUT" && pass "dry run reports the drifted public repo" || fail "dry run missed pub-drift"
grep -q 'owner/priv.*enable-dependabot-alerts' "$OUT" && pass "private repo: only Dependabot alerts planned" || fail "private repo plan wrong"
grep -q 'owner/priv.*enable-secret-scanning' "$OUT" && fail "private repo should not get a secret-scanning change" || pass "secret scanning not attempted on private repo"
grep -qE 'PATCH|PUT' "$S/calls" && fail "dry run made changes" || pass "dry run makes no changes"
grep -q 'a-fork\|owner/old\|someone/theirs' "$S/calls" && fail "forks/archived/other owners were queried" || pass "forks, archived and other owners' repos are never touched"
grep -q 'repos/owner/do-not-touch' "$S/calls" && fail "skip-listed repo was queried" || pass "skip-listed repo is never queried"
tsv="$(first "$S"/out/github-security-*.tsv)"
[ -n "$tsv" ] && pass "TSV report written" || fail "no TSV report"
perm="$(stat -f %Lp "$tsv" 2>/dev/null || stat -c %a "$tsv" 2>/dev/null)"
[ "$perm" = 600 ] && pass "TSV report is mode 600" || fail "TSV mode $perm"

sweep --check; rc=$?
[ "$rc" = 1 ] && pass "--check exits 1 on drift" || fail "--check exit $rc"

: > "$S/calls"; sweep --apply; rc=$?
[ "$rc" = 0 ] && pass "--apply exits 0" || fail "--apply exit $rc"
grep -q 'api -X PATCH repos/owner/pub-drift' "$S/calls" && pass "--apply PATCHes the drifted public repo" || fail "no PATCH for pub-drift"
[ "$(grep -c 'api -X PATCH' "$S/calls")" = 1 ] && pass "--apply PATCHes nothing else" || fail "unexpected PATCH calls"
grep -q 'api -X PUT repos/owner/priv/vulnerability-alerts' "$S/calls" && pass "--apply enables alerts on the private repo" || fail "no alerts PUT for priv"
grep -q 'pub-ok.*-X\|-X.*pub-ok' "$S/calls" && fail "compliant repo was modified" || pass "compliant repo is left alone"

sweep --check; rc=$?
[ "$rc" = 0 ] && pass "--check exits 0 after --apply" || fail "--check after apply exit $rc"

PATH="$S/bin:$REAL_PATH" SKIPLIST_FILE="$S/missing.conf" "$SWEEP" --owner owner --out "$S/out" > "$OUT" 2>&1; rc=$?
[ "$rc" = 2 ] && pass "missing skip list fails closed (exit 2)" || fail "missing skip list exit $rc"
git init -q "$S/repo-out"
sweep --out "$S/repo-out"; rc=$?
[ "$rc" = 3 ] && pass "refuses to write its report into a git repo" || fail "report into git repo exit $rc"

# ================================================================================
header "security-audit.sh --quick (stub gh, fixture workspace)"
A="$T/audit"; mkdir -p "$A/bin" "$A/home" "$A/dev/projects" "$A/out"
cat > "$A/bin/gh" <<'EOF'
#!/bin/bash
case "$*" in
  "auth status"*)   echo "  - Token scopes: 'repo'"; exit 0 ;;
  "api user/keys --jq length"*) echo 2; exit 0 ;;
  "api user/keys"*) echo "2024-01-01T00:00:00Z"; exit 0 ;;
  "repo list"*)     exit 0 ;;
esac
exit 1
EOF
chmod +x "$A/bin/gh"
printf 'recovery\n' > "$A/dev/github-recovery-codes.txt"
git init -q "$A/dev/projects/app"
printf 'x\n' > "$A/dev/projects/app/deploy.key"
printf 'KEY=\n' > "$A/dev/projects/app/.env.example"
mkdir -p "$A/dev/templates/stack/variant" "$A/dev/templates/loose"
printf '.env\n.env.*\n!.env.template\n' > "$A/dev/templates/stack/.gitignore"
printf 'SECRET=x\n' > "$A/dev/templates/stack/variant/.env.production"
printf 'SECRET=x\n' > "$A/dev/templates/loose/.env"
cat > "$A/home/.gitconfig" <<EOF
[user]
    email = t@users.noreply.github.com
[hook "security-gate-commit"]
    event = pre-commit
    command = $DOTFILES_DIR/security/gate.sh pre-commit
[hook "security-gate-push"]
    event = pre-push
    command = $DOTFILES_DIR/security/gate.sh pre-push
EOF
HOME="$A/home" GIT_CONFIG_GLOBAL="$A/home/.gitconfig" GIT_CONFIG_NOSYSTEM=1 DEV_ROOT="$A/dev" \
  SKIPLIST_FILE="$S/skiplist.conf" SECURITY_GATE_BYPASS_LOG="$A/bypass.log" PATH="$A/bin:$REAL_PATH" \
  "$DOTFILES_DIR/scripts/security-audit.sh" --quick --no-notify --out "$A/out" > "$OUT" 2>&1
rc=$?
report="$(first "$A"/out/security-audit-*.md)"
[ -n "$report" ] && pass "report written" || fail "no report written"
[ "$rc" = 1 ] && pass "exits 1 when there is a FAIL" || fail "exit $rc, expected 1"
grep -q 'FAIL\*\* outside any repo.*github-recovery-codes.txt' "$report" 2>/dev/null && pass "loose credential file outside any repo is a FAIL" || fail "loose file outside repo not reported"
grep -q 'WARN\*\* untracked and NOT ignored.*projects/app/deploy.key' "$report" 2>/dev/null && pass "untracked, unignored key inside a repo is a WARN" || fail "untracked key not reported"
grep -q '\.env\.example' "$report" 2>/dev/null && fail ".env.example was reported" || pass ".env.example is not reported"
grep -q '^- outside any repo, but ignored by templates/stack/.gitignore.*templates/stack/variant/.env.production' "$report" 2>/dev/null \
  && pass "env file outside a repo but covered by an ancestor .gitignore is info, not FAIL" || fail "covered env file not reported as info"
grep -q 'FAIL\*\* outside any repo.*templates/loose/.env' "$report" 2>/dev/null \
  && pass "env file outside a repo with no covering .gitignore is a FAIL" || fail "uncovered env file not a FAIL"
[ -z "$(find "$A/dev/templates" -name '.git' 2>/dev/null)" ] && pass "gitignore coverage check writes nothing into the scanned tree" || fail "a .git appeared under the scanned tree"
grep -q '## 3. GitHub repo settings' "$report" 2>/dev/null && pass "report has the GitHub settings section" || fail "GitHub section missing"
grep -q 'skipped (--quick)' "$report" 2>/dev/null && pass "--quick skips the slow steps and says so" || fail "--quick not reflected"
grep -q 'SSH keys on the account: 2' "$report" 2>/dev/null && pass "account section lists SSH key count" || fail "account section missing SSH keys"
perm="$(stat -f %Lp "$report" 2>/dev/null || stat -c %a "$report" 2>/dev/null)"
[ "$perm" = 600 ] && pass "report is mode 600" || fail "report mode $perm"
git init -q "$A/repo-out"
HOME="$A/home" DEV_ROOT="$A/dev" PATH="$A/bin:$REAL_PATH" "$DOTFILES_DIR/scripts/security-audit.sh" --quick --no-notify --out "$A/repo-out" > "$OUT" 2>&1; rc=$?
[ "$rc" = 3 ] && pass "refuses to write its report into a git repo" || fail "report into git repo exit $rc"

# ================================================================================
header "dotaudit gate module (50-gate.sh)"
D="$T/dotaudit"; mkdir -p "$D/dev/projects" "$D/out" "$D/home"
git init -q "$D/dev/projects/r1"; git init -q "$D/dev/projects/r2"
git -C "$D/dev/projects/r2" config hook.security-gate-commit.enabled false
runaudit() { HOME="$D/home" GIT_CONFIG_GLOBAL="$1" GIT_CONFIG_NOSYSTEM=1 DEV_ROOT="$D/dev" SKIPLIST_FILE="$S/skiplist.conf" \
  SECURITY_GATE_BYPASS_LOG="$D/bypass.log" "$DOTFILES_DIR/scripts/dev-audit.sh" --only gate --quiet --out "$D/out" > "$OUT" 2>&1; }
: > "$D/empty.gitconfig"
runaudit "$D/empty.gitconfig"; rc=$?
tsv="$(first "$D"/out/findings-*.tsv)"
grep -q $'^FAIL\tgate\t-\tgate-not-registered' "$tsv" && pass "unregistered gate is a FAIL" || fail "unregistered gate not reported"
[ "$rc" = 1 ] && pass "dotaudit exits 1 when the gate is not registered" || fail "exit $rc"
grep -q $'^WARN\tgate\tr2\tgate-disabled' "$tsv" && pass "repo disabling the gate is a WARN" || fail "disabled gate not reported"
grep -q $'\tr1\tgate-disabled' "$tsv" && fail "r1 wrongly reported" || pass "repo with the gate enabled is silent"
printf '%s\t/x\tpre-push\temail\tfixture reason\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$D/bypass.log"
runaudit "$A/home/.gitconfig"
grep -q 'gate-not-registered' "$tsv" && fail "registered gate still reported" || pass "registered gate is silent"
grep -q $'^WARN\tgate\t-\tgate-bypassed' "$tsv" && pass "recent bypass is a WARN" || fail "recent bypass not reported"

# ================================================================================
# The sanitizers are the reason a backup of a live config can be committed to a
# public repo at all. They run on the way IN, so a regression here republishes a
# real value on the next `dotbackup` — with nothing to notice it but the gate.
header "sync-dotfiles.sh sanitizers"

# Extract ONLY the sanitizer function bodies. Sourcing the script's whole
# prologue instead would also define its log/success/warn/fail helpers, and its
# fail() calls `exit 1` — which silently replaces this suite's fail(), so the
# first failing assertion would abort the run before the summary instead of
# being counted. Its log() also writes to the real ~/.dotfiles-backup/sync.log.
awk '/^(sanitize|desanitize|expand)_[a-z_]+\(\) \{/,/^\}/' \
  "$DOTFILES_DIR/scripts/sync-dotfiles.sh" > "$T/sanitizers.sh"
# shellcheck source=/dev/null
. "$T/sanitizers.sh"

n_fn="$(grep -c '^\(sanitize\|desanitize\|expand\)_[a-z_]*() {' "$T/sanitizers.sh")"
[ "$n_fn" -ge 6 ] && pass "extracted $n_fn sanitizers from sync-dotfiles.sh" \
                  || fail "expected at least 6 sanitizers, extracted $n_fn"
# The extraction must not have dragged in the script's own fail(), which exits.
grep -q '^fail()' "$T/sanitizers.sh" \
  && fail "the extraction pulled in sync-dotfiles.sh's fail() and would abort this suite" \
  || pass "the extraction defines sanitizers only, not the script's helpers"

# --- gitconfig: absolute home paths become ~/ --------------------------------
printf 'excludesfile = /Users/someone/.gitignore_global\n' > "$T/gc"
out="$(sanitize_gitconfig < "$T/gc")"
case "$out" in
  *"/Users/"*) fail "sanitize_gitconfig rewrites an absolute home path" ;;
  *"~/.gitignore_global"*) pass "sanitize_gitconfig rewrites an absolute home path" ;;
  *) fail "sanitize_gitconfig rewrites an absolute home path (got: $out)" ;;
esac

# --- ssh config: host, user and port are replaced by placeholders ------------
printf 'Host h\n  HostName real.example.net\n  User someone\n  Port 2222\n' > "$T/ssh"
out="$(sanitize_ssh_config < "$T/ssh")"
case "$out" in
  *real.example.net*|*someone*|*2222*) fail "sanitize_ssh_config removes host, user and port" ;;
  *) pass "sanitize_ssh_config removes host, user and port" ;;
esac

# --- home-path sanitizer: XML and JSON, both round-tripping losslessly -------
# The stored marker is a literal $HOME, not ~. That is the correctness argument:
# iTerm2's real prefs already contain a genuine ~/Library/... value, and a
# ~-based marker cannot tell a tilde the sanitizer produced from one that was
# always there. The first version of this did exactly that and silently
# rewrote a real value on the way out.
cat > "$T/agent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
	<key>ProgramArguments</key>
	<array>
		<string>/Users/someone/dev/dotfiles/bin/weekly-disk-cleanup.sh</string>
	</array>
	<key>StandardOutPath</key>
	<string>/Users/someone/.weekly-disk-cleanup.launchd.log</string>
	<key>Working Directory</key>
	<string>/Users/someone</string>
	<key>PreExistingTilde</key>
	<string>~/Library/Application Support/Thing/Scripts</string>
</dict>
</plist>
PLIST

cat > "$T/settings.json" <<'JSON'
{
    "projectManager.git.baseFolders": [
        "/Users/someone/dev"
    ],
    "some.tildePath": "~/already/a/tilde"
}
JSON

for fixture in agent.plist settings.json; do
  sanitize_home_paths < "$T/$fixture" > "$T/$fixture.san"
  grep -qE '/Users/[a-z]' "$T/$fixture.san" \
    && fail "sanitize_home_paths leaves no absolute home path ($fixture)" \
    || pass "sanitize_home_paths leaves no absolute home path ($fixture)"

  # Lossless round-trip against what the live file would be on THIS machine.
  sed -e "s#/Users/someone#$HOME#g" "$T/$fixture" > "$T/$fixture.expected"
  expand_home_paths < "$T/$fixture.san" > "$T/$fixture.rt"
  diff -q "$T/$fixture.expected" "$T/$fixture.rt" >/dev/null \
    && pass "sanitize | expand round-trips losslessly ($fixture)" \
    || { cp "$T/$fixture.rt" "$OUT"; fail "sanitize | expand round-trips losslessly ($fixture)"; }
done

# The bare form: a home path with nothing after it is still a home path. A
# trailing-slash-only rule misses iTerm2's "Working Directory" entirely.
# shellcheck disable=SC2016 # $HOME is the literal marker being asserted, not an expansion
grep -q '<string>$HOME</string>' "$T/agent.plist.san" \
  && pass "sanitize_home_paths catches a bare /Users/<name> with no trailing slash" \
  || fail "sanitize_home_paths catches a bare /Users/<name> with no trailing slash"

# A tilde that was ALREADY in the file must survive untouched, in both directions.
grep -q '<string>~/Library/Application Support/Thing/Scripts</string>' "$T/agent.plist.rt" \
  && pass "a pre-existing ~ is not rewritten by the round-trip (XML)" \
  || fail "a pre-existing ~ is not rewritten by the round-trip (XML)"
grep -q '"~/already/a/tilde"' "$T/settings.json.rt" \
  && pass "a pre-existing ~ is not rewritten by the round-trip (JSON)" \
  || fail "a pre-existing ~ is not rewritten by the round-trip (JSON)"

# Both formats must still parse after expansion, or restore installs a broken file.
if command -v plutil >/dev/null 2>&1; then
  plutil -lint "$T/agent.plist.rt" > "$OUT" 2>&1 \
    && pass "the round-tripped plist is still valid" \
    || fail "the round-tripped plist is still valid"
fi
if command -v python3 >/dev/null 2>&1; then
  python3 -m json.tool "$T/settings.json.rt" > "$OUT" 2>&1 \
    && pass "the round-tripped JSON is still valid" \
    || fail "the round-tripped JSON is still valid"
fi

# Every sanitize_copy call must name a function that exists — the check that
# catches a rename orphaning a caller.
miss=0
: > "$OUT"
grep -oE 'sanitize_copy [^|]*[[:space:]](sanitize_[a-z_]+)' "$DOTFILES_DIR/scripts/sync-dotfiles.sh" \
  | awk '{print $NF}' | sort -u > "$T/called-fns"
while read -r fn; do
  [ -n "$fn" ] || continue
  grep -q "^${fn}() {" "$T/sanitizers.sh" || { miss=1; echo "missing: $fn" >> "$OUT"; }
done < "$T/called-fns"
[ "$miss" = 0 ] && pass "every sanitize_copy call names a sanitizer that exists" \
                || fail "every sanitize_copy call names a sanitizer that exists"

# --- THE regression guard ----------------------------------------------------
# No tracked file in this PUBLIC repo may contain this machine's real home path.
# Fixtures using /Users/alice, /Users/someone and /Users/somebody stay allowed —
# they are the inputs to the rules above. The real $USER is not.
#
# Without this, the next `dotbackup` of an editor settings or prefs file
# silently republishes it and only the weekly audit notices. It is the same idea
# as the per-file plist check it replaces, applied to the whole tree.
: > "$OUT"
( cd "$DOTFILES_DIR" && git grep -lE "/Users/$(id -un)([/\"<]|$)" -- . ) > "$OUT" 2>/dev/null
[ -s "$OUT" ] \
  && fail "no tracked file contains this machine's real home path" \
  || pass "no tracked file contains this machine's real home path"

# iTerm2's prefs are stored as XML so they are diffable AND scannable. That
# visibility is the point: as an opaque binary the file was skipped by text
# scanners entirely. It also means its machine-local `NoSync*` state must be
# stripped — a saved-window UUID under NoSyncSavedWindowPositions reads as a
# high-entropy string and gitleaks' generic-api-key rule calls it a secret.
ITERM="$DOTFILES_DIR/macos/com.googlecode.iterm2.plist"
if [ -f "$ITERM" ]; then
  head -1 "$ITERM" | grep -q '<?xml' \
    && pass "the committed iTerm2 prefs are XML, not an opaque binary" \
    || fail "the committed iTerm2 prefs are XML, not an opaque binary"
  grep -q '<key>NoSync' "$ITERM" \
    && fail "machine-local NoSync* state is stripped from the committed iTerm2 prefs" \
    || pass "machine-local NoSync* state is stripped from the committed iTerm2 prefs"
fi

# The whole tree must survive the scan dotaudit actually runs: default rules,
# --no-git (so untracked files count too). The gate's own narrow ruleset passing
# is not the same assurance — it was clean while this was failing.
if command -v gitleaks >/dev/null 2>&1; then
  : > "$OUT"
  gitleaks detect --redact --no-banner --no-git --exit-code 0 --report-format json \
    --report-path "$T/gl.json" --source "$DOTFILES_DIR" >/dev/null 2>&1
  # grep -c prints 0 AND exits 1 when nothing matches, so `|| echo 0` would
  # append a second zero and make "0" compare unequal to 0.
  n="$(grep -c '"RuleID"' "$T/gl.json" 2>/dev/null)" || n=0
  [ -n "$n" ] || n=0
  if [ "$n" = 0 ]; then
    pass "gitleaks default rules over the working tree: no findings"
  else
    grep -o '"File": "[^"]*"' "$T/gl.json" | sort -u > "$OUT"
    fail "gitleaks default rules over the working tree: $n finding(s)"
  fi
fi

# ================================================================================
header "Summary"
echo -e "  ${GREEN}Passed${NC}: $PASS_COUNT"
echo -e "  ${RED}Failed${NC}: $FAIL_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
