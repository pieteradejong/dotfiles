#!/usr/bin/env bash
#
# test-mobile-vetting.sh — the mobile-vetting Claude skill (claude/skills/mobile-vetting, D75).
#
#   1 static     exact pin and lockfile, SKILL.md frontmatter, every check id documented both ways,
#                every path SKILL.md names exists, scripts parse, no node_modules tracked, the
#                ~/.claude/skills symlink points here (when present)
#   2 simulator  scripts/ios-simulator.sh against stub xcrun: usage, no Xcode, no iPhone, a booted
#                iPhone (left booted), a shut-down one (booted, then shut down again)
#   3 audit      mobile-audit.mjs over invented fixture pages on a loopback port: good.html and
#                edge.html pass with nothing flagged, bad.html trips every check id it was built to,
#                report counts match the findings, one screenshot per device x page, paths resolve
#                against the first URL, a 404 and an unreachable server fail, usage errors exit 2
#   4 template   templates/mobile.spec.ts with templates/devices.ts in Playwright's runner: passes
#                on good.html on all five devices, fails on bad.html
#
# 1 and 2 need only bash, jq and node. 3 and 4 need the skill's npm ci and Playwright's WebKit:
#   npm ci --prefix claude/skills/mobile-vetting && npx --prefix claude/skills/mobile-vetting playwright install webkit
# Without them 3 and 4 are reported as skipped. CI does not install them yet (TODO.md).
#
# bash 3.2 compatible (D21).

set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
ROOT="$(pwd -P)"

SKILL="$ROOT/claude/skills/mobile-vetting"
AUDIT="$SKILL/scripts/mobile-audit.mjs"
SIM="$SKILL/scripts/ios-simulator.sh"
FIX="$SKILL/tests/fixtures"
PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS + 1)); echo "  ok   $1"; }
bad()  { FAIL=$((FAIL + 1)); echo "  FAIL $1"; }
skip() { SKIP=$((SKIP + 1)); echo "  skip $1"; }
check() { # <description> <command...>: ok when the command succeeds
  local d="$1"; shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
expect_rc() { # <description> <expected> <actual>
  if [ "$3" = "$2" ]; then ok "$1"; else bad "$1 (exit $3, expected $2)"; fi
}

T="$(mktemp -d)"
SRV=""
cleanup() {
  [ -n "$SRV" ] && { kill "$SRV" 2>/dev/null; wait "$SRV" 2>/dev/null; }
  rm -rf "$T"
}
trap cleanup EXIT

# ── 1 static ─────────────────────────────────────────────────────────────────────────────
echo "static"
pin="$(jq -r '.dependencies["@playwright/test"] // empty' "$SKILL/package.json")"
check "@playwright/test is pinned exactly ($pin)" sh -c "printf '%s' '$pin' | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'"
check "package.json has one dependency, no devDependencies" \
  test "$(jq '(.dependencies | length) + (.devDependencies // {} | length)' "$SKILL/package.json")" = 1
check "package-lock.json exists" test -f "$SKILL/package-lock.json"
check "lockfile root dependencies match package.json" \
  test "$(jq -c '.packages[""].dependencies' "$SKILL/package-lock.json")" = "$(jq -c '.dependencies' "$SKILL/package.json")"
check "lockfile resolves @playwright/test to the pin" \
  test "$(jq -r '.packages["node_modules/@playwright/test"].version' "$SKILL/package-lock.json")" = "$pin"
check "lockfile resolves playwright-core to the pin" \
  test "$(jq -r '.packages["node_modules/playwright-core"].version' "$SKILL/package-lock.json")" = "$pin"

check "SKILL.md opens with frontmatter" test "$(head -1 "$SKILL/SKILL.md")" = "---"
fm="$(awk 'NR == 1 { next } /^---$/ { exit } { print }' "$SKILL/SKILL.md")"
check "frontmatter name is the directory name" test "$(printf '%s\n' "$fm" | sed -n 's/^name: //p')" = "mobile-vetting"
desc="$(printf '%s\n' "$fm" | sed -n 's/^description: //p')"
check "frontmatter has a description" test -n "$desc"
check "description is at most 1024 characters (${#desc})" test "${#desc}" -le 1024
for word in responsive iPhone deploy; do
  check "description names the trigger '$word'" sh -c "printf '%s' \"\$1\" | grep -qi '$word'" _ "$desc"
done

for p in scripts/mobile-audit.mjs scripts/ios-simulator.sh templates/mobile.spec.ts templates/devices.ts references/checklist.md; do
  check "SKILL.md names $p and it exists" sh -c "grep -qF '$p' '$SKILL/SKILL.md' && test -f '$SKILL/$p'"
done

script_ids="$(grep -oE "(add\(|check: )'[a-z0-9-]+'" "$AUDIT" | grep -oE "'[a-z0-9-]+'" | tr -d "'" | sort -u)"
doc_ids="$(grep -oE '^\| `[a-z0-9-]+`' "$SKILL/references/checklist.md" | tr -d '|` ' | sort -u)"
check "the audit defines at least 15 check ids ($(printf '%s\n' "$script_ids" | wc -l | tr -d ' '))" \
  test "$(printf '%s\n' "$script_ids" | wc -l)" -ge 15
for id in $script_ids; do
  printf '%s\n' "$doc_ids" | grep -qxF "$id" || bad "check id $id is not in references/checklist.md"
done
for id in $doc_ids; do
  printf '%s\n' "$script_ids" | grep -qxF "$id" || bad "checklist documents $id, which the audit never reports"
done
ok "check ids in the script and the checklist agree"

if command -v node >/dev/null 2>&1; then
  check "mobile-audit.mjs parses (node --check)" node --check "$AUDIT"
else
  skip "node not installed: mobile-audit.mjs not parsed"
fi
check "ios-simulator.sh parses (bash -n)" bash -n "$SIM"
check "ios-simulator.sh is executable" test -x "$SIM"
check "no node_modules or test output tracked under the skill" \
  test -z "$(git ls-files "$SKILL" | grep -E 'node_modules/|test-results/')"
if [ -e "$HOME/.claude/skills/mobile-vetting" ] || [ -L "$HOME/.claude/skills/mobile-vetting" ]; then
  check "the skill symlink ~/.claude/skills/mobile-vetting points here" \
    test "$(cd "$HOME/.claude/skills/mobile-vetting" 2>/dev/null && pwd -P)" = "$(cd "$SKILL" && pwd -P)"
else
  skip "the skill symlink ~/.claude/skills/mobile-vetting is not installed on this machine"
fi

# ── 2 simulator, against stub xcrun ─────────────────────────────────────────────────────
echo "simulator"
"$SIM" >/dev/null 2>&1; expect_rc "ios-simulator.sh with no arguments is a usage error" 2 $?
"$SIM" "$T/sim" >/dev/null 2>&1; expect_rc "ios-simulator.sh with no URL is a usage error" 2 $?

make_xcrun() { # <dir> <device list line or empty>: a stub xcrun that logs its calls
  mkdir -p "$1"
  cat >"$1/xcrun" <<STUB
#!/usr/bin/env bash
echo "\$*" >>"$1/calls"
case "\$*" in
  "simctl help") exit 0 ;;
  "simctl list devices available") printf '%s\n' "== Devices ==" "-- iOS 26.0 --" "$2" ;;
  simctl\ io\ *\ screenshot\ *) : >"\${5}" ;;
esac
exit 0
STUB
  chmod +x "$1/xcrun"
}
mkdir -p "$T/noxcode"; printf '#!/usr/bin/env bash\nexit 1\n' >"$T/noxcode/xcrun"; chmod +x "$T/noxcode/xcrun"
PATH="$T/noxcode:$PATH" "$SIM" "$T/sim" http://x/ >"$T/sim.log" 2>&1; rc=$?
expect_rc "no Xcode: skipped with exit 3" 3 "$rc"
check "no Xcode: says skipped" grep -q '^skipped: xcrun simctl not available' "$T/sim.log"

make_xcrun "$T/noiphone" "    iPad Air (ABCDEF01-2345-6789-ABCD-EF0123456789) (Shutdown)"
PATH="$T/noiphone:$PATH" "$SIM" "$T/sim" http://x/ >"$T/sim.log" 2>&1; rc=$?
expect_rc "no iPhone simulator: skipped with exit 3" 3 "$rc"
check "no iPhone simulator: says skipped" grep -q '^skipped: no iPhone simulator' "$T/sim.log"

U=11111111-2222-3333-4444-555555555555
make_xcrun "$T/booted" "    iPhone 17 ($U) (Booted)"
PATH="$T/booted:$PATH" SIM_WAIT=0 "$SIM" "$T/sim-b" http://a/ http://b/ >"$T/sim.log" 2>&1; rc=$?
expect_rc "booted iPhone: exit 0" 0 "$rc"
check "booted iPhone: opens both URLs on that device" \
  test "$(grep -c "^simctl openurl $U http://[ab]/$" "$T/booted/calls")" = 2
check "booted iPhone: one screenshot per URL" test -f "$T/sim-b/ios-safari-1.png" -a -f "$T/sim-b/ios-safari-2.png"
check "booted iPhone: not booted again" sh -c "! grep -q '^simctl boot ' '$T/booted/calls'"
check "booted iPhone: left running (no shutdown)" sh -c "! grep -q '^simctl shutdown' '$T/booted/calls'"
check "booted iPhone: prints the device name per URL" test "$(grep -c '^iPhone 17  http' "$T/sim.log")" = 2

make_xcrun "$T/shutdown" "    iPhone SE (3rd generation) ($U) (Shutdown)"
PATH="$T/shutdown:$PATH" SIM_WAIT=0 "$SIM" "$T/sim-s" http://a/ >"$T/sim.log" 2>&1; rc=$?
expect_rc "shut-down iPhone: exit 0" 0 "$rc"
check "shut-down iPhone: booted by the script" grep -q "^simctl boot $U$" "$T/shutdown/calls"
check "shut-down iPhone: shut down again afterwards" grep -q "^simctl shutdown $U$" "$T/shutdown/calls"

# ── 3 audit, 4 template: need the browsers ──────────────────────────────────────────────
if ! command -v node >/dev/null 2>&1 || [ ! -d "$SKILL/node_modules/@playwright/test" ]; then
  skip "audit and template runs: node or $SKILL/node_modules missing (npm ci --prefix there first)"
  echo "mobile-vetting: $PASS passed, $FAIL failed, $SKIP skipped"
  [ "$FAIL" = 0 ]; exit
fi

PORT=$(( 20000 + $$ % 20000 ))
python3 -m http.server "$PORT" --bind 127.0.0.1 --directory "$FIX" >/dev/null 2>&1 &
SRV=$!
i=0
until curl -sf -o /dev/null "http://127.0.0.1:$PORT/good.html"; do
  i=$((i + 1)); [ "$i" -gt 50 ] && { bad "fixture server did not start on port $PORT"; exit 1; }
  perl -e 'select undef, undef, undef, 0.1'
done
B="http://127.0.0.1:$PORT"
ids() { jq -r '[.results[].findings[] | select(.level != "INFO") | .check] | unique | .[]' "$1/report.json"; }

echo "audit"
node "$AUDIT" "$B/good.html" --out "$T/good" --no-throttle >"$T/good.log" 2>&1; rc=$?
expect_rc "good.html passes on every device" 0 "$rc"
[ "$rc" = 0 ] || sed 's/^/       /' "$T/good.log" | head -40
check "good.html: nothing flagged, not even a WARN" test -z "$(ids "$T/good")"
check "good.html: five devices, one screenshot each" test "$(find "$T/good/screenshots" -name '*.png' | wc -l | tr -d ' ')" = 5
check "good.html: report.md says no FAIL" grep -q '^\*\*0 FAIL · 0 WARN\*\*' "$T/good/report.md"

node "$AUDIT" "$B/edge.html" --out "$T/edge" --no-throttle >"$T/edge.log" 2>&1; rc=$?
expect_rc "edge.html passes" 0 "$rc"
flagged="$(ids "$T/edge" | tr '\n' ' ')"
check "edge.html: nothing flagged${flagged:+ (got: $flagged)}" test -z "$flagged"
for id in hover-only tap-target tap-target-small small-text word-split body-scroller safe-area js-errors h-overflow media-width 100vh; do
  ids "$T/edge" | grep -qxF "$id" && bad "edge.html is wrongly flagged $id"
done
ok "edge.html: hover in @media (hover), :focus-within twin, hover lift, label target, sr-only text, env() in a linked sheet, inline link, footnote link in <sup>, adjacent [1][2] footnotes in a sentence, Vercel insights 404, a 40-character hash in a narrow box, hyphens:auto, scroll container, table in a scroller, missing favicon: none flagged"
check "edge.html: stacked 18 px links pass on WCAG 2.5.8 spacing (tap-target-spaced)" \
  sh -c "jq -r '.results[].findings[].check' '$T/edge/report.json' | grep -qx tap-target-spaced"

node "$AUDIT" "$B/rounding.html" --devices iphone-se,pixel-7 --out "$T/round" --no-throttle >/dev/null 2>&1; rc=$?
expect_rc "rounding.html: a 23.995 px target counts as 24 (WARN only, exit 0)" 0 "$rc"
check "rounding.html: reported as tap-target-small, not tap-target" \
  test "$(ids "$T/round" | tr '\n' ' ')" = "tap-target-small "

node "$AUDIT" "$B/bad.html" --out "$T/bad" --devices iphone-se,pixel-7 >"$T/bad.log" 2>&1; rc=$?
expect_rc "bad.html fails" 1 "$rc"
found="$(jq -r '[.results[].findings[].check] | unique | .[]' "$T/bad/report.json")"
for id in viewport-zoom h-overflow tap-target tap-target-small input-zoom small-text word-split safe-area \
          fixed-cover js-errors hover-only 100vh media-width img-srcset slow-lcp; do
  if printf '%s\n' "$found" | grep -qxF "$id"; then ok "bad.html reports $id"; else bad "bad.html does not report $id"; fi
done
check "bad.html: summary.fail equals the FAIL findings" \
  test "$(jq '.summary.fail' "$T/bad/report.json")" = "$(jq '[.results[].findings[] | select(.level == "FAIL")] | length' "$T/bad/report.json")"
check "bad.html: summary.warn equals the WARN findings" \
  test "$(jq '.summary.warn' "$T/bad/report.json")" = "$(jq '[.results[].findings[] | select(.level == "WARN")] | length' "$T/bad/report.json")"
check "bad.html: report.md headline matches the JSON" \
  grep -q "^\*\*$(jq '.summary.fail' "$T/bad/report.json") FAIL · $(jq '.summary.warn' "$T/bad/report.json") WARN\*\*" "$T/bad/report.md"
check "bad.html: the throttled load is reported as its own row" \
  test "$(jq '[.results[] | select(.device == "pixel-7-throttled")] | length' "$T/bad/report.json")" = 1
check "bad.html: two adjacent 16 px icons fail (spacing exception does not apply)" \
  sh -c "jq -r '.results[0].findings[] | select(.check == \"tap-target\") | .examples[]' '$T/bad/report.json' | grep -q 'a.icon \"share\"'"
check "bad.html: an uncaught exception is reported with its message" \
  sh -c "jq -r '.results[].findings[] | select(.check == \"js-errors\") | .examples[]' '$T/bad/report.json' | grep -q 'pageerror: fixture error'"
check "bad.html: a failed resource names its URL" \
  sh -c "jq -r '.results[].findings[] | select(.check == \"js-errors\") | .examples[]' '$T/bad/report.json' | grep -q '/missing-image.png)'"
check "bad.html: adjacent [3][2] markers in a table cell (not a sentence) fail" \
  sh -c "jq -r '.results[0].findings[] | select(.check == \"tap-target\") | .examples[]' '$T/bad/report.json' | grep -qF '\"[3]\"'"
check "bad.html: word-split names the broken word" \
  sh -c "jq -r '.results[0].findings[] | select(.check == \"word-split\") | .examples[]' '$T/bad/report.json' | grep -q '\"Contact\"'"
check "bad.html: overflow names the offending element" \
  sh -c "jq -r '.results[].findings[] | select(.check == \"h-overflow\") | .examples[]' '$T/bad/report.json' | grep -q 'div.wide'"
check "bad.html: the run's stdout is the markdown report" grep -q '^# Mobile audit' "$T/bad.log"

node "$AUDIT" "$B/good.html" /edge.html --devices iphone-se,ipad-mini --out "$T/multi" --no-throttle >/dev/null 2>&1; rc=$?
expect_rc "two pages on two devices pass" 0 "$rc"
check "a path resolves against the first URL" \
  test "$(jq -r '.urls[1]' "$T/multi/report.json")" = "$B/edge.html"
check "two pages x two devices = four screenshots" test "$(find "$T/multi/screenshots" -name '*.png' | wc -l | tr -d ' ')" = 4
check "--devices limits the devices" test "$(jq -c '.devices' "$T/multi/report.json")" = '["iphone-se","ipad-mini"]'

node "$AUDIT" "$B/bad.html" --devices iphone-se --no-throttle --out "$T/ign" \
  --ignore-errors 'fixture error' --ignore-errors 'missing-image' >/dev/null 2>&1
check "--ignore-errors (repeated) drops the matching errors" \
  sh -c "! jq -r '.results[].findings[].check' '$T/ign/report.json' | grep -qx js-errors"
check "--ignore-errors leaves the other checks failing" \
  sh -c "jq -r '.results[].findings[].check' '$T/ign/report.json' | grep -qx h-overflow"

node "$AUDIT" "$B/noviewport.html" --devices iphone-se --no-throttle --out "$T/novp" >/dev/null 2>&1; rc=$?
expect_rc "noviewport.html fails" 1 "$rc"
check "noviewport.html reports viewport-meta" sh -c "jq -r '.results[].findings[].check' '$T/novp/report.json' | grep -qx viewport-meta"
node "$AUDIT" "$B/narrowviewport.html" --devices iphone-se --no-throttle --out "$T/narrowvp" >/dev/null 2>&1; rc=$?
expect_rc "narrowviewport.html (width=1024) fails" 1 "$rc"
check "narrowviewport.html reports viewport-meta" sh -c "jq -r '.results[].findings[].check' '$T/narrowvp/report.json' | grep -qx viewport-meta"

for z in noscale maxscale; do
  node "$AUDIT" "$B/zoom-$z.html" --devices iphone-se --no-throttle --out "$T/zoom-$z" >/dev/null 2>&1; rc=$?
  expect_rc "zoom-$z.html fails" 1 "$rc"
  check "zoom-$z.html reports viewport-zoom" sh -c "jq -r '.results[].findings[].check' '$T/zoom-$z/report.json' | grep -qx viewport-zoom"
done

node "$AUDIT" "$B/scroller.html" --devices iphone-se,pixel-7 --no-throttle --out "$T/scroller" >/dev/null 2>&1; rc=$?
expect_rc "scroller.html fails" 1 "$rc"
for id in body-scroller h-overflow; do
  check "scroller.html reports $id (overflow measured on the body scroller)" \
    sh -c "jq -r '.results[].findings[].check' '$T/scroller/report.json' | grep -qx $id"
done

node "$AUDIT" "$B/missing.html" --devices iphone-se --out "$T/404" --no-throttle >/dev/null 2>&1; rc=$?
expect_rc "a 404 page fails" 1 "$rc"
check "a 404 page reports http-status" sh -c "jq -r '.results[].findings[].check' '$T/404/report.json' | grep -qx http-status"

DEAD=$(( PORT + 1 ))
node "$AUDIT" "http://127.0.0.1:$DEAD/" --devices iphone-se --out "$T/dead" --no-throttle >/dev/null 2>&1; rc=$?
expect_rc "an unreachable server fails" 1 "$rc"
check "an unreachable server reports load" sh -c "jq -r '.results[].findings[].check' '$T/dead/report.json' | grep -qx load"

node "$AUDIT" >/dev/null 2>&1; expect_rc "no URL is a usage error" 2 $?
node "$AUDIT" "$B/" --devices nokia-3310 >/dev/null 2>&1; expect_rc "an unknown device is a usage error" 2 $?
node "$AUDIT" "not a url" >/dev/null 2>&1; expect_rc "a non-URL is a usage error" 2 $?
node "$AUDIT" "$B/" --frobnicate >/dev/null 2>&1; expect_rc "an unknown option is a usage error" 2 $?
node "$AUDIT" "$B/" --ignore-errors '(' >/dev/null 2>&1; expect_rc "an invalid --ignore-errors regex is a usage error" 2 $?
node "$AUDIT" "$B/" --out /dev/null/x >/dev/null 2>&1; expect_rc "an uncreatable --out is a usage error" 2 $?

echo "template"
run_template() { # <route> <out>
  (cd "$SKILL" && BASE_URL="$B" MOBILE_ROUTES="$1" PW_OUT="$2" \
    node node_modules/@playwright/test/cli.js test -c tests/playwright.config.ts >"$2.log" 2>&1)
}
run_template /good.html "$T/tpl-good"; rc=$?
expect_rc "template spec passes on good.html" 0 "$rc"
[ "$rc" = 0 ] || sed 's/^/       /' "$T/tpl-good.log" | tail -30
check "template spec ran 25 tests (5 checks x 5 devices)" grep -Eq '25 passed' "$T/tpl-good.log"
run_template /bad.html "$T/tpl-bad"; rc=$?
expect_rc "template spec fails on bad.html" 1 "$rc"
check "template spec fails all 5 checks on bad.html, on every device" grep -Eq '25 failed' "$T/tpl-bad.log"

echo "mobile-vetting: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" = 0 ]
