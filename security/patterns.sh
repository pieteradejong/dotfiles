#!/usr/bin/env bash
#
# patterns.sh — the one list of what must never be published.
#
# Sourced, never executed, by:
#   security/gate.sh              the commit/push gate, over staged or pushed changes
#   scripts/audit/30-privacy.sh   dotaudit, over tracked files across ~/dev
#
# Change a rule here and both enforce it. This file is PUBLIC: it holds shapes,
# never real values. Exact personal values (the real email, real hostnames) live
# in private/security/personal-patterns.conf, which only the gate loads.
#
# Everything is bash 3.2 compatible (macOS /bin/bash).
#
# shellcheck disable=SC2034 # every variable here is used by the files that source it
#
# NOTE ON FILENAMES: dotfiles/.gitignore ignores *secret*, *token*, *password*,
# *credential*, *api_key*, *.local and *.log. A new file here with one of those
# in its name is silently untracked. See docs/dev-audit.md § Gotchas.

# Filenames that should never be committed, as shell glob patterns matched
# against each path. "<rule-name>|<glob>".
TRACKED_FILE_RULES='
env-file|.env
env-file|*/.env
env-file|.env.*
env-file|*/.env.*
private-key|*.key
private-key|*.p12
private-key|*.pfx
ssh-key|*id_rsa
ssh-key|*id_ed25519
ssh-key|*id_ecdsa
shell-history|*.zsh_history
shell-history|*.bash_history
aws-credentials|*.aws/credentials
'

# Gate-only additions. Kept apart from TRACKED_FILE_RULES so dotaudit's
# established baseline does not shift under it; the gate only ever sees new
# changes, so it can be stricter from day one. Promote a rule into
# TRACKED_FILE_RULES once the workspace is clean of it.
GATE_FILE_RULES='
private-key|*.pem
private-key|*.ppk
ssh-key|*id_dsa
deploy-env|.deploy-env
deploy-env|*/.deploy-env
package-auth|.npmrc.local
package-auth|.pypirc
package-auth|*/.pypirc
netrc|.netrc
netrc|*/.netrc
'

# Secret-shaped content. Matched with grep -l (filenames only), never -o.
# "<rule-name>|<ERE>". gitleaks' default ruleset is the primary scanner; these
# are dotaudit's fallback when gitleaks is absent.
CONTENT_RULES='
service-account-json|"type"[[:space:]]*:[[:space:]]*"service_account"
private-key-block|-----BEGIN [A-Z ]*PRIVATE KEY-----
github-token|gh[pousr]_[A-Za-z0-9]{36}
aws-access-key|AKIA[0-9A-Z]{16}
openai-key|sk-[A-Za-z0-9]{32}
slack-token|xox[abprs]-[A-Za-z0-9-]{10}
google-api-key|AIza[0-9A-Za-z_-]{35}
'

# The bare "grep for api[_-]?key|secret|token|password" is unusable as a check —
# `password` appears in ordinary code in most repos. So it is narrowed to the
# shape that actually indicates a committed value: the keyword, an assignment
# operator, then a quoted literal of at least 8 characters. Placeholders
# (${VAR}, <fill-me>, "", "changeme") do not match. A heuristic: WARN, not FAIL.
SECRETISH_RE='(api[_-]?key|secret|token|password|passwd|pwd)[[:space:]]*[:=][[:space:]]*["'"'"'][^"'"'"'$<{ ]{8,}'

EMAIL_RE='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
HOMEPATH_RE='/Users/[a-z][a-z0-9._-]*/'

# Phone numbers: E.164 (+ then 10-15 digits) or a separated 3-3-4 North American
# number. Requires the separators or the plus, so version strings, dates and
# long IDs do not match.
PHONE_RE='(\+[1-9][0-9]{9,14}([^0-9]|$))|((^|[^0-9])\(?[2-9][0-9]{2}\)?[-. ][2-9][0-9]{2}[-. ][0-9]{4}([^0-9]|$))'

# Addresses that are safe to publish on a commit: GitHub's noreply forms.
NOREPLY_RE='users\.noreply\.github\.com$|^noreply@github\.com$'

# Addresses that are conventions, not contacts: the noreply form, clone URLs,
# and the fake domains fixtures use. Matched against ONE extracted address.
EMAIL_PLACEHOLDER_RE='users\.noreply\.github\.com|^git@(github|gitlab|bitbucket)\.|(example|acme|domain|other|different|personal|invalid|test)\.(com|org|net)|^(user|username|email|name|you|your)[-_.@]|@(localhost|host|hostname|server|remote-server|work-server|domain)|@[xy]\.com|your[-_.]'

# Files that legitimately contain these shapes: templates, examples, fixtures.
# A test file is *supposed* to contain john.doe@example.com.
# Two spellings of the same rule — a case pattern for shell loops and an ERE for
# awk pipelines. Change both together.
is_example_path() {
  case "$1" in
    *.example|*.example.*|*.template|*.template.*|*.sample|*.sample.*) return 0 ;;
    *test*|*fixture*|*mock*|*spec*) return 0 ;;
  esac
  return 1
}
EXAMPLE_PATH_ERE='\.(example|template|sample)($|\.)|test|fixture|mock|spec'
