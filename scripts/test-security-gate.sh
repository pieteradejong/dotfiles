#!/usr/bin/env bash
#
# test-security-gate.sh — test suite for security/gate.sh.
#
# Every case builds throwaway repos under a temp dir, with a fixture global git
# config that registers the gate exactly as ~/.gitconfig does, bare repos as
# remotes, and a stub `gh` that answers PUBLIC / PRIVATE / fails. Nothing here
# touches a real repo, the real ~/.gitconfig, or the network.
#
# Fixture secrets are generated at runtime from /dev/urandom, so this file
# contains no secret-shaped string for gitleaks (or the gate itself) to find.
#
# Run: ./scripts/test-security-gate.sh [--verbose]      Exit: 0 all passed, 1 otherwise.
#
# shellcheck disable=SC2015 # `cond && pass || fail` is safe here: pass/fail always return 0

set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
GATE="$DOTFILES_DIR/security/gate.sh"
VERBOSE=false
[ "${1:-}" = "--verbose" ] && VERBOSE=true

RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; CYAN="\033[36m"; BOLD="\033[1m"; NC="\033[0m"
PASS_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); echo -e "  ${RED}✗ FAIL${NC}: $1"; $VERBOSE || [ ! -s "$OUT" ] || sed 's/^/      | /' "$OUT"; }
skip() { SKIP_COUNT=$((SKIP_COUNT + 1)); echo -e "  ${YELLOW}- SKIP${NC}: $1"; }
header() { echo ""; echo -e "${BOLD}${CYAN}── $1 ──${NC}"; }

# --- sandbox --------------------------------------------------------------------
T="$(mktemp -d "${TMPDIR:-/tmp}/gate-test.XXXXXX")"
trap 'rm -rf "$T"' EXIT
OUT="$T/out"; : > "$OUT"
SECRETS="$T/generated-secrets"; : > "$SECRETS"

export HOME="$T/home"
export GIT_CONFIG_NOSYSTEM=1
export GIT_CONFIG_GLOBAL="$HOME/.gitconfig"
export SECURITY_GATE_CACHE_DIR="$T/cache"
export SECURITY_GATE_BYPASS_LOG="$T/state/bypass.log"
export NO_COLOR=1
unset SECURITY_GATE_BYPASS GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE
mkdir -p "$HOME" "$T/bin" "$T/remotes/github.com/test"

cat > "$GIT_CONFIG_GLOBAL" <<EOF
[user]
    name = Test
    email = test@users.noreply.github.com
[init]
    defaultBranch = main
[commit]
    gpgsign = false
[hook "security-gate-commit"]
    event = pre-commit
    command = $GATE pre-commit
[hook "security-gate-push"]
    event = pre-push
    command = $GATE pre-push
EOF

# Stub gh: answer from $T/gh-answer (PUBLIC | PRIVATE | fail), log every call.
cat > "$T/bin/gh" <<EOF
#!/bin/sh
echo "\$*" >> "$T/gh-calls"
case "\$*" in
  "auth status"*) exit 0 ;;
esac
a="\$(cat "$T/gh-answer" 2>/dev/null)"
[ "\$a" = fail ] && exit 1
echo "\$a"
EOF
chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH"
answer() { echo "$1" > "$T/gh-answer"; rm -rf "$SECURITY_GATE_CACHE_DIR"; }
answer PRIVATE

# Bounded input on purpose: `tr < /dev/urandom | head` relies on SIGPIPE to stop
# tr, and CI runners that ignore SIGPIPE leave it spinning forever (it hung the
# first CI run for 20 minutes). 8 KB of random bytes yields ~1.9 KB of [A-Za-z0-9].
rnd() { head -c 8192 /dev/urandom | LC_ALL=C tr -dc "$1" | head -c "$2"; }
gen_pat() { local s; s="ghp_$(rnd 'A-Za-z0-9' 36)"; echo "$s" >> "$SECRETS"; printf '%s' "$s"; }
gen_aws() { local s; s="AKIA$(rnd 'A-Z2-7' 16)"; echo "$s" >> "$SECRETS"; printf '%s' "$s"; }
gen_key() { printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n%s\n%s\n%s\n-----END OPENSSH PRIVATE KEY-----\n' "$(rnd 'A-Za-z0-9+/' 70)" "$(rnd 'A-Za-z0-9+/' 70)" "$(rnd 'A-Za-z0-9+/' 70)"; }
bigfile() { if command -v mkfile >/dev/null 2>&1; then mkfile -n "${2}m" "$1"; else dd if=/dev/zero of="$1" bs=1048576 count="$2" 2>/dev/null; fi; }

# newrepo <name> — a repo with one clean commit, cwd set to it.
newrepo() {
  cd "$T" || exit 1
  rm -rf "${T:?}/${1:?}"; git init -q "$T/$1"; cd "$T/$1" || exit 1
  echo base > README.md; git add README.md; git commit -qm base >/dev/null 2>&1
}
# bare <path under remotes/> — create a bare remote, print its path.
bare() { git init -q --bare "$T/remotes/$1"; printf '%s' "$T/remotes/$1"; }

# expect <rc> <description> <command...> — run, capture output, assert exit code.
expect() {
  local want="$1" desc="$2" rc; shift 2
  "$@" > "$OUT" 2>&1; rc=$?
  if [ "$rc" = "$want" ]; then pass "$desc"; else fail "$desc (exit $rc, wanted $want)"; fi
  $VERBOSE && sed 's/^/      | /' "$OUT"
  return 0
}
out_has()     { if grep -qE -- "$1" "$OUT"; then pass "$2"; else fail "$2 (output lacks /$1/)"; fi; }
out_lacks()   { if grep -qE -- "$1" "$OUT"; then fail "$2 (output has /$1/)"; else pass "$2"; fi; }
unstage_all() { git reset -q >/dev/null 2>&1; git clean -qfdx >/dev/null 2>&1; }

# ================================================================================
header "Preconditions"
if ! command -v gitleaks >/dev/null 2>&1; then echo "gitleaks is required for this suite"; exit 1; fi
v="$(git version | awk '{print $3}')"
case "$v" in 2.5[4-9]*|2.[6-9][0-9]*|[3-9].*) pass "git $v supports config-based hooks" ;;
  *) echo "git $v is too old for config-based hooks (need 2.54+)"; exit 1 ;; esac
newrepo pre
if git hook list pre-commit 2>/dev/null | grep -q security-gate-commit; then pass "fixture config registers the gate"; else fail "fixture config does not register the gate"; fi

# ================================================================================
header "pre-commit: secrets (gitleaks)"
newrepo secrets
printf 'token = "%s"\n' "$(gen_pat)" > config.py; git add config.py
expect 1 "GitHub token in staged file is blocked" git commit -qm pat
out_has 'BLOCK gitleaks: 1 secret' "finding names the rule count"
out_has 'github-pat' "finding names the gitleaks rule"
out_has 'config\.py' "finding names the file"
unstage_all

printf 'aws_access_key_id = %s\n' "$(gen_aws)" > aws.ini; git add aws.ini
expect 1 "AWS access key id is blocked" git commit -qm aws
unstage_all

gen_key > deploy_key.txt; git add deploy_key.txt
expect 1 "private key block in an innocuous filename is blocked" git commit -qm key
unstage_all

# A repo-level .gitleaks.toml that disables everything must not help: the gate passes -c explicitly.
printf '[allowlist]\npaths = [".*"]\n' > .gitleaks.toml; git add .gitleaks.toml; git commit -qm "allow all" >/dev/null 2>&1
printf 'k = "%s"\n' "$(gen_pat)" > sneaky.py; git add sneaky.py
expect 1 "repo .gitleaks.toml allowlist cannot switch off the gate" git commit -qm sneaky
unstage_all

# ================================================================================
header "pre-commit: forbidden files"
newrepo files
# .env.test, tests/… and fixture/… paths: a path containing "test" must not exempt a real
# key or env file from the file-name rules (a blind spot until 2026-09-14).
for f in .env config/.env.production id_rsa certs/server.pem keys/app.key .deploy-env .netrc home/.pypirc \
         .env.test tests/fixtures/id_rsa config/test/.env spec/keys/deploy.key; do
  mkdir -p "$(dirname "$f")"; echo x > "$f"; git add -f "$f"
  expect 1 "$f is blocked" git commit -qm "add $f"
  unstage_all
done
for f in .env.example config/.env.template id_rsa.pub; do
  mkdir -p "$(dirname "$f")"; echo 'KEY=' > "$f"; git add -f "$f"
  expect 0 "$f is allowed" git commit -qm "add $f"
done

echo x > .env; git add -f .env; SECURITY_GATE_BYPASS="fixture: tracking .env to test untracking" git commit -qm "track .env" >/dev/null 2>&1
git rm -q --cached .env
expect 0 "untracking a committed .env (deletion) is allowed" git commit -qm "untrack .env"
rm -f .env

bigfile big.bin 51; git add big.bin
expect 1 "51 MB file is blocked" git commit -qm big
out_has 'large-file.*big\.bin \(51 MB\)' "large-file finding names file and size"
unstage_all

# ================================================================================
header "pre-commit: personal data (warn, never block)"
newrepo personal
printf 'path = "/Users/somebody/projects/x"\n' > paths.py; git add paths.py
expect 0 "home path: commit proceeds" git commit -qm home
out_has 'WARN +home-path: .*paths\.py' "home path is warned with the file name"
out_lacks 'somebody' "warning does not echo the matched value"

printf 'contact: real.person@company.io\n' > contact.md; git add contact.md
expect 0 "real email: commit proceeds" git commit -qm email
out_has 'WARN +email: .*contact\.md' "real email is warned"
out_lacks 'real\.person' "warning does not echo the address"

printf 'maintainer: user@example.com, git@github.com:org/repo.git, 1856262+x@users.noreply.github.com\n' > ok.md; git add ok.md
expect 0 "placeholder emails commit" git commit -qm placeholders
out_lacks 'email' "placeholder, clone-URL and noreply addresses are not flagged"

printf 'call +31612345678 or (415) 555-2671\n' > phone.txt; git add phone.txt
expect 0 "phone number: commit proceeds" git commit -qm phone
out_has 'WARN +phone-number: .*phone\.txt' "phone number is warned"

printf 'version 1.2.3, released 2026-09-14, id 20260914123456, port 8080\n' > notphone.txt; git add notphone.txt
expect 0 "versions/dates/ids commit" git commit -qm notphone
out_lacks 'phone-number' "versions, dates and long ids are not phone numbers"

printf 'fixture = "/Users/somebody/x"  # security-gate:allow\n' > allowed.py; git add allowed.py
expect 0 "allow-marked line commits" git commit -qm allowed
out_lacks 'home-path' "security-gate:allow silences personal-data rules on that line"

mkdir -p tests; printf 'email = "someone@company.io"\n' > tests/fixture_users.py; git add tests
expect 0 "test fixture with personal data commits" git commit -qm fixture
out_lacks 'WARN' "test/fixture paths are exempt from personal-data rules"

printf '{"deprecated": "unsupported, contact real.maintainer@npmjs-mail.io"}\n' > package-lock.json; git add package-lock.json
expect 0 "lockfile with a third-party maintainer email commits" git commit -qm lock
out_lacks 'email' "dependency lockfiles are exempt from personal-data rules"
printf '{"resolved": "https://registry.example", "token": "%s"}\n' "$(gen_pat)" > yarn.lock; git add yarn.lock
expect 1 "a secret inside a lockfile is still blocked" git commit -qm locksecret
out_has 'BLOCK gitleaks' "gitleaks still scans lockfiles"
unstage_all

printf 'x\n' > note.txt; git add note.txt
expect 0 "non-noreply author: commit proceeds" git -c user.email=someone@company.io commit -qm author
out_has 'WARN +author-email' "non-noreply author address is warned at commit time"

# ================================================================================
header "pre-commit: dotfiles private/ companion repo"
newrepo dotfiles
git remote add origin "$T/remotes/github.com/pieteradejong/dotfiles.git"
mkdir -p private/registers; echo "register" > private/registers/x.md; git add -f private
expect 1 "private/ staged in the dotfiles repo is blocked" git commit -qm private
out_has 'private-companion-repo' "finding names the rule"
unstage_all
newrepo other
mkdir -p private; echo "fine" > private/readme.md; git add private
expect 0 "a private/ directory in any other repo is allowed" git commit -qm private

# ================================================================================
header "pre-commit: fail closed"
newrepo closed
NOLEAKS="$T/path-without-gitleaks"; mkdir -p "$NOLEAKS"
old_ifs="$IFS"; IFS=:
for d in $PATH; do
  [ -d "$d" ] || continue
  for f in "$d"/*; do
    b="$(basename "$f")"; [ "$b" = gitleaks ] && continue
    [ -e "$NOLEAKS/$b" ] || ln -s "$f" "$NOLEAKS/$b" 2>/dev/null
  done
done
IFS="$old_ifs"
echo x > x.txt; git add x.txt
expect 1 "gitleaks missing blocks every commit" env PATH="$NOLEAKS" git commit -qm x
out_has 'gitleaks-missing' "finding explains gitleaks is missing"
unstage_all

# ================================================================================
header "bypass"
newrepo bypass
echo x > .env; git add -f .env
expect 1 "SECURITY_GATE_BYPASS with a short reason is rejected" env SECURITY_GATE_BYPASS=short git commit -qm env
out_has 'under 10 characters' "explains why the reason was rejected"
expect 0 "SECURITY_GATE_BYPASS with a real reason lets the commit through" env SECURITY_GATE_BYPASS="fixture env file for test" git commit -qm env
out_has 'BYPASSED' "bypass is announced"
if [ -f "$SECURITY_GATE_BYPASS_LOG" ] && grep -q 'fixture env file for test' "$SECURITY_GATE_BYPASS_LOG" && grep -q 'env-file' "$SECURITY_GATE_BYPASS_LOG"; then
  pass "bypass log records reason and rule"
else
  fail "bypass log missing reason or rule"
fi
perm="$(stat -f %Lp "$SECURITY_GATE_BYPASS_LOG" 2>/dev/null || stat -c %a "$SECURITY_GATE_BYPASS_LOG" 2>/dev/null)"
[ "$perm" = 600 ] && pass "bypass log is mode 600" || fail "bypass log mode is $perm"

# ================================================================================
header "coexistence with each repo's own hooks"
newrepo hookdir
cat > .git/hooks/pre-commit <<'EOF'
#!/bin/sh
touch .git/local-hook-ran
EOF
chmod +x .git/hooks/pre-commit
echo x > x.txt; git add x.txt
expect 0 ".git/hooks repo: clean commit passes" git commit -qm x
[ -f .git/local-hook-ran ] && pass ".git/hooks/pre-commit still runs after the gate" || fail ".git/hooks/pre-commit did not run"

newrepo hookspath
mkdir -p .githooks; printf '#!/bin/sh\necho "LOCAL HOOK REJECTS" >&2\nexit 1\n' > .githooks/pre-commit; chmod +x .githooks/pre-commit
git config core.hooksPath .githooks
echo x > x.txt; git add x.txt
expect 1 "repo with local core.hooksPath: its own rejecting hook still blocks" git commit -qm x
out_has 'LOCAL HOOK REJECTS' "local hook output is shown"
printf 'k = "%s"\n' "$(gen_pat)" > s.py; git add s.py
git config core.hooksPath .githooks-none
expect 1 "repo with local core.hooksPath: gate still blocks a secret" git commit -qm s
out_has 'BLOCK gitleaks' "gate ran in the core.hooksPath repo"
unstage_all

if command -v pre-commit >/dev/null 2>&1; then
  newrepo precommit
  cat > .pre-commit-config.yaml <<'EOF'
repos:
  - repo: local
    hooks:
      - id: always-fail
        name: always-fail-marker
        entry: "false"
        language: system
        pass_filenames: false
EOF
  git add .pre-commit-config.yaml
  expect 0 "pre-commit install still works (no global core.hooksPath)" pre-commit install
  expect 1 "pre-commit framework hook runs after the gate" git commit -qm x
  out_has 'always-fail-marker' "pre-commit framework output is shown"
else
  skip "pre-commit not installed — framework coexistence not tested"
fi

# ================================================================================
header "pre-push: visibility decides personal data"
newrepo push
printf 'contact real.person@company.io\n' > contact.md; git add contact.md; git commit -qm contact >/dev/null 2>&1

answer PRIVATE
git remote add priv "$(bare github.com/test/priv.git)"
expect 0 "personal data pushed to a PRIVATE remote: allowed" git push -q priv main
out_has 'visibility: PRIVATE' "push announces remote visibility"
out_has 'WARN +email' "personal data is warned on a private push"

answer PUBLIC
git remote add pub "$(bare github.com/test/pub.git)"
expect 1 "personal data pushed to a PUBLIC remote: blocked" git push -q pub main
out_has 'BLOCK email' "email is a blocking finding on a public push"

answer fail
git remote add unk "$(bare github.com/test/unknown.git)"
expect 1 "visibility lookup fails: treated as public, blocked" git push -q unk main
out_has 'UNKNOWN \(treated as public\)' "unknown visibility is stated"

git remote add local "$(bare notgithub/local.git)"
expect 1 "non-GitHub remote: treated as public, blocked" git push -q local main

answer PUBLIC
expect 0 "bypass with reason on a public push" env SECURITY_GATE_BYPASS="fixture contact is a public address" git push -q pub main

# ================================================================================
header "pre-push: what is scanned"
newrepo scope
answer PRIVATE
git remote add origin "$(bare github.com/test/scope.git)"
expect 0 "first push of a clean repo" git push -q origin main
printf 'k = "%s"\n' "$(gen_pat)" > leak.py; git add leak.py; git commit -n -qm "no-verify commit" >/dev/null 2>&1
expect 1 "secret committed with -n is caught at push, even to a PRIVATE remote" git push -q origin main
out_has 'BLOCK gitleaks: 1 secret\(s\) in 1 pushed commit' "push scans only the new commit"
git reset -q --hard HEAD~1

git checkout -q -b feature; echo f > f.txt; git add f.txt; git commit -qm f >/dev/null 2>&1
expect 0 "new branch push" git push -q origin feature
out_has 'scanning 1 commit\(s\)' "new branch: only commits not on the remote are scanned"
expect 0 "branch deletion push is allowed" git push -q origin :feature

git checkout -q main
bigfile big.bin 51; git add big.bin; git commit -n -qm big >/dev/null 2>&1
expect 1 "51 MB file committed with -n is caught at push" git push -q origin main
out_has 'large-file' "large-file finding on push"
git reset -q --hard HEAD~1

echo y > y.txt; git add y.txt; git -c user.email=someone@company.io commit -qm author >/dev/null 2>&1
answer PUBLIC
git remote add pub "$(bare github.com/test/scope-pub.git)"
expect 1 "non-noreply author pushed to PUBLIC is blocked" git push -q pub main
out_has 'BLOCK author-email' "author-email finding on public push"
answer PRIVATE
expect 0 "non-noreply author pushed to PRIVATE is allowed" git push -q origin main
out_has 'WARN +author-email' "author-email is a warning on private push"

expect 0 "push by URL instead of remote name" git push -q "$T/remotes/github.com/test/scope.git" main

newrepo dotfiles-push
answer PUBLIC
git remote add origin "$(bare github.com/pieteradejong/dotfiles.git)"
mkdir -p private; echo r > private/r.md; git add -f private; git commit -n -qm private >/dev/null 2>&1
expect 1 "private/ committed with -n into dotfiles is caught at push" git push -q origin main
out_has 'private-companion-repo' "private-companion-repo finding on push"

# ================================================================================
header "pre-push: visibility cache"
newrepo viscache   # not "cache": that is $SECURITY_GATE_CACHE_DIR, which answer() deletes
answer PUBLIC; : > "$T/gh-calls"
git remote add origin "$(bare github.com/test/viscache.git)"
git push -q origin main >/dev/null 2>&1
echo z > z.txt; git add z.txt; git commit -qm z >/dev/null 2>&1
git push -q origin main >/dev/null 2>&1
n="$(grep -c 'repo view' "$T/gh-calls")"
[ "$n" = 1 ] && pass "second push to the same repo uses the cached visibility" || fail "gh repo view called $n times, expected 1"

# ================================================================================
header "scan-tree"
newrepo tree
printf 'k = "%s"\n' "$(gen_pat)" > untracked.py
echo x > .env
expect 1 "scan-tree finds problems in untracked files" "$GATE" scan-tree
out_has 'gitleaks' "scan-tree runs gitleaks on untracked content"
out_has 'env-file' "scan-tree applies file-name rules to untracked files"
if [ -z "$(git diff --cached --name-only)" ]; then pass "scan-tree leaves the real index untouched"; else fail "scan-tree modified the real index"; fi
rm -f untracked.py .env
expect 0 "scan-tree on a clean tree passes" "$GATE" scan-tree

# ================================================================================
header "status"
newrepo status
"$GATE" status > "$OUT" 2>&1
out_has 'ok +hook\.security-gate-commit registered for pre-commit' "status sees the commit hook"
out_has 'ok +hook\.security-gate-push registered for pre-push' "status sees the push hook"
git config hook.security-gate-commit.enabled false
"$GATE" status > "$OUT" 2>&1; rc=$?
[ "$rc" != 0 ] && pass "status fails when a repo disables the gate" || fail "status passed with the gate disabled"
out_has 'disabled \(enabled=false\)' "status names the disabled hook"

# ================================================================================
header "performance"
newrepo perf
for i in $(seq 1 200); do printf 'line %s\nvalue = %s\n' "$i" "$i" > "file$i.txt"; done
git add .
start="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
git commit -qm many >/dev/null 2>&1; rc=$?
end="$(perl -MTime::HiRes=time -e 'printf "%.3f", time')"
secs="$(awk -v a="$start" -v b="$end" 'BEGIN { printf "%.2f", b - a }')"
[ "$rc" = 0 ] && pass "200-file commit passes" || fail "200-file commit failed"
awk -v s="$secs" 'BEGIN { exit !(s < 5) }' && pass "200-file commit gated in ${secs}s (< 5s)" || fail "200-file commit took ${secs}s"

# ================================================================================
header "no secret value ever printed"
leaked=0
for f in "$T"/out "$SECURITY_GATE_BYPASS_LOG"; do
  [ -f "$f" ] || continue
  grep -qF -f "$SECRETS" "$f" && leaked=1
done
[ "$leaked" = 0 ] && pass "no generated secret appears in gate output or the bypass log" || fail "a generated secret was printed"

# ================================================================================
header "Summary"
echo -e "  ${GREEN}Passed${NC}: $PASS_COUNT"
echo -e "  ${RED}Failed${NC}: $FAIL_COUNT"
[ "$SKIP_COUNT" -gt 0 ] && echo -e "  ${YELLOW}Skipped${NC}: $SKIP_COUNT"
[ "$FAIL_COUNT" -eq 0 ]
