#!/usr/bin/env bash
#
# run.sh — everyday commands for this repo. Each one wraps a script that already exists,
# so there is still one place for every check: ./test.sh (D63).
#
#   ./run.sh                 status (the default)
#   ./run.sh status          maintenance and security warnings, gate status, dotfiles drift
#   ./run.sh warnings        bin/maintenance-status: the red/yellow lines (docs/warnings-runbook.md)
#   ./run.sh test [ARGS]     exec ./test.sh ARGS: every check, or one suite (./run.sh test gate)
#   ./run.sh lint            the lint suites only: coverage, shellcheck, zsh-syntax, ruff
#   ./run.sh format          ruff format over the Python files test.sh lints (changes files)
#   ./run.sh audit           the security audit, quick: scripts/security-audit.sh --quick --no-notify
#   ./run.sh doctor          check this Mac's installed dotfiles: scripts/test-dotfiles-setup.sh
#   ./run.sh -h              this help
#
# There is no build: nothing here compiles. Setup is ./init.sh.
# Exit: the wrapped command's exit code · 2 usage.

set -euo pipefail
cd "$(dirname "$0")"

usage() { awk 'NR > 2 && /^#/ { sub(/^# ?/, ""); print; next } NR > 2 { exit }' "$0"; }

python_files() { sed -n '/^PYTHON_FILES="/,/^"/p' test.sh | grep -v '"'; }

cmd="${1:-status}"
[ "$#" -gt 0 ] && shift

case "$cmd" in
  status)
    rc=0
    printf '\033[1m== warnings\033[0m\n'
    bin/maintenance-status
    printf '\n\033[1m== gate\033[0m\n'
    security/gate.sh status || rc=1
    printf '\n\033[1m== dotfiles in $HOME vs this repo\033[0m\n'
    scripts/sync-dotfiles.sh status || rc=1
    exit "$rc"
    ;;
  warnings) exec bin/maintenance-status "$@" ;;
  test)     exec ./test.sh "$@" ;;
  lint)
    rc=0
    for s in coverage shellcheck zsh-syntax ruff; do ./test.sh "$s" || rc=1; done
    exit "$rc"
    ;;
  format)
    command -v ruff >/dev/null 2>&1 || { echo "ruff is not installed: ./init.sh" >&2; exit 1; }
    # shellcheck disable=SC2046 # one path per line, no spaces
    exec ruff format $(python_files)
    ;;
  audit)    exec scripts/security-audit.sh --quick --no-notify "$@" ;;
  doctor)   exec bash scripts/test-dotfiles-setup.sh "$@" ;;
  -h|--help|help) usage; exit 0 ;;
  *)        echo "run.sh: unknown command: $cmd" >&2; usage >&2; exit 2 ;;
esac
