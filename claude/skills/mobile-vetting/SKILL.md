---
name: mobile-vetting
description: Vet any web page or web app for mobile phones and tablets before calling it done. Use whenever you build, change, review or deploy web UI (HTML, CSS, React, Vue, Svelte, Next.js, Astro, Vite, static sites, dashboards, artifacts served locally), when a task mentions mobile, responsive, phone, iPhone, Android, iPad, touch or viewport, and before any deploy or go-public step. Runs a Playwright audit on five phone/tablet viewports (horizontal overflow, tap targets, iOS input zoom, small text, viewport meta, safe areas, hover-only content, 100vh, fixed overlays, wide media, JS errors, throttled load), gives screenshots to look at, and supplies a drop-in Playwright spec so the checks stay in the project's CI.
---

# Mobile vetting

Web UI is not done until it works on a phone. The proof is the audit's output, pasted into the
summary, not a statement that it "should be responsive". Why it is built this way: dotfiles D75.

## When

- Any change to a page's markup, CSS or layout, in any project, before you say it is done.
- Reviewing a web app, before a deploy, before a repo goes public.
- Skip only for changes with no rendered output (API-only, build config, docs).
- Forks, upstream clones and do-not-touch repos: run the audit if asked, but never add the template
  files to them.

## Steps

1. **Get a URL.** Start the project's dev or preview server (its `run.sh`, `npm run dev` or `npm run
   preview`), or use the deployed preview URL. List the pages that matter: the home page, one of each
   page type, any form, and any page with a table, chart or map.
2. **Run the audit.** First time on a machine, install once:
   `npm ci --prefix ~/.claude/skills/mobile-vetting && npx --prefix ~/.claude/skills/mobile-vetting playwright install webkit`
   ```sh
   node ~/.claude/skills/mobile-vetting/scripts/mobile-audit.mjs http://localhost:5173/ /about /contact \
     --out <scratchpad>/mobile-audit
   ```
   Devices: `iphone-se` (375 px, the narrowest that matters), `iphone-se-landscape`, `iphone-17-pro`,
   `pixel-7` (Chromium), `ipad-mini`, plus a throttled Pixel 7 load (4x CPU, Slow 4G). `--devices`
   narrows the list, `--no-throttle` skips the slow load, and `--ignore-errors REGEX` drops console
   errors that aren't the page's fault (say which ones, and why, in the summary). Exit 0 means no FAIL, 1 means at least one
   FAIL, 2 means a usage or browser error.
3. **Look at the screenshots.** Read at least `iphone-se--*.png` and `ipad-mini--*.png` for every page.
   The script can't see a layout that is technically within bounds but broken: overlapping text,
   a cramped nav, a cut-off chart, a hero that is all image.
4. **Fix every FAIL.** `references/checklist.md` has the fix for each check id. Fix the WARNs that
   matter on mobile, or say why one stays. Re-run until it exits 0.
5. **Do the manual checks the script can't automate** (checklist § Manual). Use Claude in Chrome at
   375 px wide, or the simulator below. Cover: the on-screen keyboard covering a focused field,
   rotating mid-task, any swipe or drag interaction, and the page offline if it claims to work offline.
6. **Real iOS Safari, when Xcode is present:**
   `~/.claude/skills/mobile-vetting/scripts/ios-simulator.sh <out-dir> <url> ...` screenshots the pages
   in the Simulator's Safari, with the browser bars, notch and home indicator that Playwright's WebKit lacks.
   Exit 3 means skipped (no Xcode or no iPhone simulator). Say it was skipped; it is not a failure.
7. **Keep it checked.** If the project already uses Playwright, offer to add
   `templates/mobile.spec.ts` as `e2e/mobile.spec.ts` and `templates/devices.ts` as
   `e2e/mobile-devices.ts`, then spread `mobileProjects` into its config's `projects`. Pin
   `@playwright/test` exactly. If it has no Playwright, propose adding it as its own change, not as a
   side effect.
8. **Report.** Put the audit's summary table (from `report.md`) and the exit code in the closing
   summary, along with what was fixed, what WARNs remain and why, and whether the simulator pass ran.
   Open items go to the repo's `TODO.md`.

## What it does not cover

Native apps (React Native or Expo: use the simulator and the device), real-device performance, and
screen-reader behaviour beyond what the checks touch. For accessibility in depth, also run axe if the
project has it.
