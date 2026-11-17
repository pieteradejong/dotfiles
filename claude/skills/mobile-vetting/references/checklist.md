# Mobile checklist: what each check means and how to fix it

Check ids as `scripts/mobile-audit.mjs` reports them. `scripts/test-mobile-vetting.sh` in dotfiles
fails if an id in the script is missing here.

## Automated checks

| Id | Level | What fails | Fix |
|---|---|---|---|
| `viewport-meta` | FAIL | No `<meta name="viewport">`, or no `width=device-width` in it. Phones then render a 980 px page zoomed out. | `<meta name="viewport" content="width=device-width, initial-scale=1">` |
| `viewport-zoom` | FAIL | `user-scalable=no`, or `maximum-scale` below 2. That blocks pinch zoom (WCAG 1.4.4). | Remove both. To stop iOS zooming into a form field, fix `input-zoom` instead. |
| `h-overflow` | FAIL | The page is wider than the viewport, so it scrolls sideways. It's measured on the document, or on the body scroller when there is one. The examples list the outermost elements that stick out. | Find the fixed `width`, long unbroken string, wide table or negative margin. Use `max-width: 100%`, `overflow-wrap: anywhere`, `min-width: 0` on flex/grid children, or wrap tables in `overflow-x: auto`. Don't hide it with `body { overflow-x: hidden }`: that clips content and breaks `position: sticky`. |
| `body-scroller` | FAIL | The page scrolls inside `<body>` or a full-screen wrapper, not the document (`html, body { height: 100%; overflow: auto }`). iOS Safari's bars then never collapse, tapping the status bar doesn't scroll to top, and full-page screenshots stop after one screen. | Let the document scroll: drop `overflow` and the fixed `height` from `html` and `body`. Use `min-height: 100dvh` for full-height layouts. |
| `tap-target` | FAIL | An interactive element smaller than 24×24 CSS px (the WCAG 2.5.8 minimum). Inline links in running text are exempt, footnote links in a `<sup>` within a sentence included, a checkbox or radio counts its label's size, and a target that passes on spacing is exempt (see `tap-target-spaced`). Sizes are rounded to 0.1 px. | Padding or `min-width`/`min-height` on the link or button itself, or a larger label. |
| `tap-target-spaced` | INFO | Targets under 24 px that pass on WCAG 2.5.8's spacing exception: a 24 px circle centred on each touches no other target. | Nothing to fix. Bigger is still easier to hit. |
| `tap-target-small` | WARN | An interactive element between 24 and 44 px (Apple HIG 44 pt; WCAG 2.5.5 AAA). | Aim for 44×44 on primary actions and nav. Dense secondary controls may stay, if they're spaced apart. |
| `input-zoom` | FAIL | An `input`, `select` or `textarea` whose font is under 16 px. iOS Safari zooms the whole page on focus. | `font-size: 16px` (or `1rem`) on form fields. Buttons and inputs don't inherit font by default, so add `button, input, select, textarea { font: inherit; }`. |
| `word-split` | FAIL | A word of 4 to 30 letters broken across two lines with no hyphen ("CONTAC / T"): a box too narrow for it, plus `overflow-wrap: anywhere`, `word-break: break-all` or wide `letter-spacing`. Longer runs (hashes, URLs) and `hyphens: auto` text are exempt. | Give the box room (`min-width: max-content` on buttons, or `flex-wrap` on the row), reduce `letter-spacing` on narrow screens, or use `overflow-wrap: break-word` (breaks only words that cannot fit on a line of their own). |
| `small-text` | FAIL | Visible text under 12 px. Screen-reader-only text, `sup` and `sub` are skipped. Unstyled buttons count, since WebKit gives them 11 px. | Body text 16 px, and nothing under 12. `font: inherit` on form controls. |
| `hover-only` | WARN | A `:hover` rule that reveals content, such as `display` not none, `visibility: visible`, `opacity: 1` or a non-zero `max-height`. It has no `:focus`/`:active`/`:focus-within` twin and is outside `@media (hover: hover)`. Touch users may never see that content. | Add the `:focus-within` twin, make it a tap toggle, or put the rule inside `@media (hover: hover)` and show the content by default. |
| `100vh` | WARN | `height`/`min-height: 100vh`. On phones, `vh` ignores the browser bars, so the bottom is cut off or jumps. | `100dvh` (follows the bars), or `100svh` (the smallest size, so it never jumps). |
| `safe-area` | FAIL | `viewport-fit=cover` with no `env(safe-area-inset-*)` anywhere, so content goes under the notch and the home indicator. | Pad the edges with `env(safe-area-inset-left)` etc. (`max(16px, env(...))`), or drop `viewport-fit=cover`. |
| `fixed-cover` | FAIL | A `position: fixed` element covers over 30% of the screen on load (cookie banner, chat widget, sticky header, interstitial). | Make it smaller, dismissible and compact on narrow screens, or a bottom sheet that starts collapsed. |
| `media-width` | FAIL | An `img`, `video`, `iframe`, `canvas`, `svg`, `table` or `pre` wider than the viewport and not inside a scroll container. | `img, video, svg, canvas { max-width: 100%; height: auto; }`. Wrap tables and `pre` in an `overflow-x: auto` container. |
| `img-srcset` | WARN | An image over 1000 px wide with no `srcset` or `<picture>`, so phones download the full size. | `srcset` + `sizes`, or the framework's image component. |
| `js-errors` | FAIL | A console error or uncaught exception on a mobile device (ignored: `favicon.ico`, and `/_vercel/insights/` and `/_vercel/speed-insights/`, which exist only on a Vercel deploy; `--ignore-errors REGEX` adds more). The failing resource's URL is shown. Often a desktop-only API, a touch/pointer assumption, or a resource 404. | Fix the error. Feature-detect APIs. |
| `http-status` | FAIL | The page answered 400 or above. | Wrong path, or the route is missing. |
| `load` | FAIL | The page didn't load within 30 s, or the server wasn't reachable. | Is the server running on that port? |
| `slow-lcp` | WARN / INFO | Largest Contentful Paint over 4 s on a throttled Pixel 7 (4x CPU, Slow 4G) is a WARN. Otherwise INFO, with the time. | Smaller hero image (`srcset`, AVIF/WebP), `fetchpriority="high"` on the LCP image, less blocking JS/CSS, preloaded fonts with `font-display: swap`. |
| `css-unreadable` | INFO | Cross-origin stylesheets can't be scanned for `hover-only`, `100vh` and `safe-area`. | Nothing to fix. Those three checks are partial for that sheet. |

## Manual checks (the script can't measure these)

- **On-screen keyboard.** Focus each form field at 375 px wide. The field and its submit button stay
  visible, and no fixed footer covers them. Use the right `type` and `inputmode` (email, tel, numeric)
  and `autocomplete`.
- **Orientation.** Rotate mid-task. Nothing resets, and the landscape layout is usable (the audit
  screenshots `iphone-se-landscape`).
- **Gestures.** Every swipe or drag has a tap alternative (WCAG 2.5.7). Horizontal carousels don't
  trap vertical scroll.
- **Navigation.** The menu opens, closes and is reachable with one thumb. The current page is marked.
- **Charts, maps, tables.** They're readable at 375 px: fewer ticks, a stacked layout or a scroll
  container. A map doesn't hijack page scroll.
- **Dark mode and zoom.** At 200% text zoom (iOS Settings → Display → Text Size, or browser zoom) the
  layout reflows without overlapping (WCAG 1.4.10 at 320 px).
- **Offline and slow network**, if the app claims to work offline or under poor connectivity.
- **Real iOS Safari** (`scripts/ios-simulator.sh`). Check the browser bars over fixed footers, the
  notch in landscape, and `position: sticky` under the dynamic toolbar.
