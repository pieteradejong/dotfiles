#!/usr/bin/env bash
#
# template-canary.sh — run the curated templates' real GitHub workflows, on GitHub (D79).
#
# Six of the seven curated template directories are not git repos, so their
# .github/workflows/ci.yml — and the security-reusable.yml call in it — never ran
# until someone scaffolded a project and pushed it. This copies each template the
# way a new project starts (no .git, node_modules, venvs, build output or env
# files; the template's own .gitignore decides the rest), commits it as a single
# orphan commit on branch canary/<stack>-<variant> through the normal gate, pushes
# that branch to a private canary repo, waits for every run on that commit, and
# writes one row per template. rn-supabase is left out: it is its own repo
# (rn-supabase-template), whose CI already runs weekly and which ci-status.py reads.
#
# The templates trigger on `push: branches: [main]`, so the COPY gets
# 'canary/**' added to that filter. The template itself is never changed, and
# main is never pushed: a branch that does not start with canary/ is refused.
#
# Usage:  scripts/template-canary.sh [--dry-run] [--only STACK/VARIANT]... [--summary]
#         scripts/template-canary.sh --list
#   --dry-run   build and commit each branch (the gate runs) in a scratch repo; push nothing
#   --only T    one template (repeatable), e.g. --only ts-web/minimal-mvp
#   --summary   LEVEL<TAB>text lines (security-audit.sh): WARN per red template, INFO per green
#   --list      the templates and their branch names; touch nothing
# Exit:   0 every template green (or dry-run built) · 1 at least one red · 2 bad usage or setup
#         (no template dir, rewrite failed for every template, repo unreachable) · 3 --out in a git repo
# Env:    CANARY_REPO (pieteradejong/template-ci-canary) · TEMPLATES_ROOT (~/dev/templates) ·
#         CANARY_OUT (~/dev/audit-reports/template-canary) · CANARY_TIMEOUT (2400 s per run) ·
#         CANARY_POLL (30 s) · GH (gh) · TODAY (YYYY-MM-DD, tests) · CANARY_KEEP=1 keeps the
#         scratch repo and prints its path (to inspect a dry run) · CANARY_REMOTE (the push URL;
#         default git@github.com:$CANARY_REPO.git — tests point it at a local bare repo)
#
# bash 3.2 compatible (macOS /bin/bash).

set -u

CANARY_REPO="${CANARY_REPO:-pieteradejong/template-ci-canary}"
TEMPLATES_ROOT="${TEMPLATES_ROOT:-$HOME/dev/templates}"
CANARY_OUT="${CANARY_OUT:-$HOME/dev/audit-reports/template-canary}"
CANARY_TIMEOUT="${CANARY_TIMEOUT:-2400}"
CANARY_POLL="${CANARY_POLL:-30}"
GH="${GH:-gh}"
TODAY="${TODAY:-$(date +%Y-%m-%d)}"
# The curated templates that are not their own repo (templates/CLAUDE.md; scripts/template-versions.py CURATED).
CANARY_TEMPLATES="py-fastapi/minimal-mvp py-fastapi/production-ready ts-web/minimal-mvp ts-web/production-ready node-express/minimal-mvp node-express/production-ready vercel-stack"

DRY=0; LIST=0; SUMMARY=0; ONLY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY=1 ;;
    --list)    LIST=1 ;;
    --summary) SUMMARY=1 ;;
    --only)    [ $# -ge 2 ] || { echo "--only needs a template" >&2; exit 2; }; ONLY="$ONLY $2"; shift ;;
    -h|--help) awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [ -n "$ONLY" ]; then
  for t in $ONLY; do
    case " $CANARY_TEMPLATES " in *" $t "*) ;; *) echo "not a canary template: $t (see --list)" >&2; exit 2 ;; esac
  done
  CANARY_TEMPLATES="${ONLY# }"
fi

branch_of() { printf 'canary/%s' "$(printf '%s' "$1" | tr '/' '-')"; }

if [ "$LIST" = 1 ]; then
  for t in $CANARY_TEMPLATES; do printf '%-32s %s\n' "$t" "$(branch_of "$t")"; done
  exit 0
fi

say() { [ "$SUMMARY" = 1 ] && return 0; printf '%s\n' "$*" >&2; }

inside_git() { # <dir> — true when the dir or an ancestor has .git
  local d="$1"
  while [ -n "$d" ] && [ "$d" != / ]; do
    [ -e "$d/.git" ] && return 0
    d="$(dirname "$d")"
  done
  return 1
}

mkdir -p "$CANARY_OUT" 2>/dev/null
OUT_ABS="$(cd "$CANARY_OUT" 2>/dev/null && pwd -P)" || { echo "cannot create $CANARY_OUT" >&2; exit 2; }
if inside_git "$OUT_ABS"; then
  echo "refused: $OUT_ABS is inside a git repo — audit output never goes there" >&2; exit 3
fi
[ -d "$TEMPLATES_ROOT" ] || { echo "no templates at $TEMPLATES_ROOT" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/template-canary.XXXXXX")"
if [ -n "${CANARY_KEEP:-}" ]; then say "keeping the scratch repo: $WORK/canary"; else trap 'rm -rf "$WORK"' EXIT; fi
REPO_DIR="$WORK/canary"
git init -q -b canary-base "$REPO_DIR" || exit 2
DEFAULT_REMOTE="git@github.com:$CANARY_REPO.git"
git -C "$REPO_DIR" remote add origin "${CANARY_REMOTE:-$DEFAULT_REMOTE}"

if [ "$DRY" = 0 ]; then
  if ! "$GH" repo view "$CANARY_REPO" --json visibility -q .visibility > "$WORK/vis" 2> "$WORK/vis.err"; then
    echo "cannot reach $CANARY_REPO: $(head -1 "$WORK/vis.err") — create it first (docs/maintenance.md § Template canary)" >&2
    exit 2
  fi
  if [ "$(cat "$WORK/vis")" != PRIVATE ]; then
    echo "refused: $CANARY_REPO is $(cat "$WORK/vis"), not PRIVATE" >&2; exit 2
  fi
fi

# add_canary_trigger <file> — give every push branch filter 'canary/**'. Fails when a workflow
# has a push trigger the rewrite could not reach, so a template never silently goes untested.
add_canary_trigger() {
  local f="$1"
  sed -E "s/^([[:space:]]+branches:[[:space:]]*\[)[[:space:]]*main[[:space:]]*\]/\1main, 'canary\/**']/" "$f" > "$f.new" && mv "$f.new" "$f"
  if grep -qE '^[[:space:]]+push:[[:space:]]*$' "$f" && ! grep -q "canary/\*\*" "$f"; then
    return 1
  fi
  if grep -qE '^on:.*push|^[[:space:]]+push:' "$f"; then return 0; fi
  return 1   # no push trigger at all: nothing would run
}

# Results, one TSV row per template: template branch status runs detail
RES="$WORK/results.tsv"; : > "$RES"
row() { printf '%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" >> "$RES"; }

PUSHED=""   # "template|branch|sha" words
for t in $CANARY_TEMPLATES; do
  b="$(branch_of "$t")"
  case "$b" in canary/?*) ;; *) row "$t" "$b" red 0 "refused: branch is not canary/*"; continue ;; esac
  src="$TEMPLATES_ROOT/$t"
  if [ ! -d "$src/.github/workflows" ]; then row "$t" "$b" red 0 "no .github/workflows in the template"; continue; fi
  say "── $t → $b"
  git -C "$REPO_DIR" checkout -q --orphan "$b" 2>/dev/null || git -C "$REPO_DIR" checkout -q -B "$b"
  git -C "$REPO_DIR" rm -rfq --cached . >/dev/null 2>&1
  find "$REPO_DIR" -mindepth 1 -maxdepth 1 ! -name .git -exec rm -rf {} +
  rsync -a --exclude .git --exclude node_modules --exclude .venv --exclude venv --exclude __pycache__ \
    --exclude dist --exclude build --exclude .next --exclude coverage --exclude .DS_Store \
    --exclude .pytest_cache --exclude .mypy_cache --exclude .ruff_cache \
    --include .env.example --include .env.template --exclude '.env' --exclude '.env.*' \
    "$src/" "$REPO_DIR/"
  ok=1
  for f in "$REPO_DIR"/.github/workflows/*.yml "$REPO_DIR"/.github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    add_canary_trigger "$f" || { ok=0; row "$t" "$b" red 0 "cannot add a canary/** push trigger to ${f##*/}"; break; }
  done
  [ "$ok" = 1 ] || continue
  git -C "$REPO_DIR" add -A
  if ! git -C "$REPO_DIR" commit -q -m "canary: $t ($TODAY)" > "$WORK/commit.out" 2>&1; then
    row "$t" "$b" red 0 "commit blocked: $(grep -E 'BLOCK' "$WORK/commit.out" | head -2 | tr '\n' ' ' | cut -c1-300)"
    continue
  fi
  sha="$(git -C "$REPO_DIR" rev-parse HEAD)"
  if [ "$DRY" = 1 ]; then
    row "$t" "$b" built 0 "dry run: committed $(git -C "$REPO_DIR" ls-files | wc -l | tr -d ' ') files as ${sha:0:12}, not pushed"
    continue
  fi
  # The one push this script makes: this canary branch, by explicit refspec, forced (each run is a
  # fresh orphan commit). Never main.
  if ! git -C "$REPO_DIR" push -q --force origin "refs/heads/$b:refs/heads/$b" > "$WORK/push.out" 2>&1; then
    row "$t" "$b" red 0 "push failed: $(grep -E 'BLOCK|error|fatal' "$WORK/push.out" | head -2 | tr '\n' ' ' | cut -c1-300)"
    continue
  fi
  PUSHED="$PUSHED $t|$b|$sha"
done

# wait_runs <sha> — prints "status<TAB>runs<TAB>detail" once every run on the commit has finished.
wait_runs() {
  local sha="$1" start now n pending red detail id names
  start="$(date +%s)"
  while :; do
    if "$GH" run list -R "$CANARY_REPO" --commit "$sha" --json databaseId,status,conclusion,workflowName \
         > "$WORK/runs.json" 2> "$WORK/runs.err"; then
      n="$(jq 'length' "$WORK/runs.json")"
      pending="$(jq '[.[] | select(.status != "completed")] | length' "$WORK/runs.json")"
      if [ "$n" -gt 0 ] && [ "$pending" = 0 ]; then
        red="$(jq -r '[.[] | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral")] | length' "$WORK/runs.json")"
        if [ "$red" = 0 ]; then
          printf 'green\t%s\t%s\n' "$n" "$(jq -r '[.[].workflowName] | sort | join(", ")' "$WORK/runs.json")"
        else
          detail=""
          for id in $(jq -r '.[] | select(.conclusion != "success" and .conclusion != "skipped" and .conclusion != "neutral") | .databaseId' "$WORK/runs.json"); do
            names="$("$GH" run view "$id" -R "$CANARY_REPO" --json workflowName,conclusion,jobs \
              -q '.workflowName + " (" + .conclusion + ": " + ([.jobs[] | select(.conclusion != "success" and .conclusion != "skipped") | .name + " → " + ([.steps[]? | select(.conclusion == "failure") | .name][0] // "")] | join("; ")) + ")"' 2>/dev/null)"
            detail="$detail${detail:+ · }${names:-run $id failed}"
          done
          printf 'red\t%s\t%s\n' "$n" "$detail"
        fi
        return 0
      fi
    fi
    now="$(date +%s)"
    if [ $((now - start)) -ge "$CANARY_TIMEOUT" ]; then
      if [ "${n:-0}" -gt 0 ] 2>/dev/null; then
        printf 'red\t%s\ttimed out after %ss with %s run(s) unfinished\n' "$n" "$CANARY_TIMEOUT" "$pending"
      else
        printf 'red\t0\tno workflow run started within %ss (trigger not matched?)\n' "$CANARY_TIMEOUT"
      fi
      return 0
    fi
    sleep "$CANARY_POLL"
  done
}

for p in $PUSHED; do
  t="${p%%|*}"; rest="${p#*|}"; b="${rest%%|*}"; sha="${rest#*|}"
  say "── waiting for $t (${sha:0:12})"
  IFS="$(printf '\t')" read -r st n detail <<EOF
$(wait_runs "$sha")
EOF
  row "$t" "$b" "$st" "$n" "$detail"
done

# --- report ---------------------------------------------------------------------------------------
MD="$OUT_ABS/template-canary-$TODAY.md"; TSV="$OUT_ABS/template-canary-$TODAY.tsv"
umask 077
{
  printf 'template\tbranch\tstatus\truns\tdetail\n'; cat "$RES"
} > "$TSV"
{
  printf '# Template canary — %s\n\n' "$TODAY"
  # shellcheck disable=SC2016 # the backticks are markdown code spans
  printf 'The curated templates'"'"' own workflows, run on GitHub in `%s`%s. Made by `dotfiles/scripts/template-canary.sh` (D79).\n\n' \
    "$CANARY_REPO" "$([ "$DRY" = 1 ] && echo ' — **dry run: nothing pushed**')"
  printf '| Template | Branch | Status | Runs | Detail |\n|---|---|---|---|---|\n'
  while IFS="$(printf '\t')" read -r t b st n detail; do
    # shellcheck disable=SC2016 # the backticks are markdown code spans
    printf '| %s | `%s` | %s | %s | %s |\n' "$t" "$b" "$st" "$n" "$(printf '%s' "$detail" | sed 's/|/\\|/g')"
  done < "$RES"
} > "$MD"
chmod 600 "$MD" "$TSV"

N_RED="$(awk -F'\t' '$3 == "red"' "$RES" | wc -l | tr -d ' ')"
if [ "$SUMMARY" = 1 ]; then
  while IFS="$(printf '\t')" read -r t b st n detail; do
    case "$st" in
      red)   printf 'WARN\ttemplate %s: CI red on GitHub — %s\n' "$t" "$detail" ;;
      green) printf 'INFO\ttemplate %s: CI green on GitHub (%s run(s))\n' "$t" "$n" ;;
      *)     printf 'INFO\ttemplate %s: %s — %s\n' "$t" "$st" "$detail" ;;
    esac
  done < "$RES"
else
  cat "$MD"
fi
[ "$N_RED" = 0 ] || exit 1
exit 0
