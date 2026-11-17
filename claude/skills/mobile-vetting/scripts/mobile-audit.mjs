#!/usr/bin/env node
// mobile-audit.mjs: check a web app's pages on phone and tablet viewports (D75).
//
//   node mobile-audit.mjs <url> [<path-or-url> ...] [--out DIR] [--devices a,b] [--no-throttle]
//
//   <url>          the first page, e.g. http://localhost:5173/ ; it is also the base for later paths
//   <path-or-url>  more pages: /about, /pricing, or full URLs
//   --out DIR      where report.md, report.json and screenshots go (default: a new temp dir)
//   --devices      comma list of keys from DEVICES below (default: all)
//   --no-throttle  skip the slow-phone load (Chromium, 4x CPU, Slow 4G)
//   --ignore-errors REGEX  console/page errors matching it are not js-errors (repeatable). Always ignored:
//                  favicon.ico, and /_vercel/insights|speed-insights/ (served only on a Vercel deploy)
//
// Exit: 0 no FAIL (WARNs allowed) · 1 at least one FAIL · 2 usage or browser launch error.
// Checks and their fixes: ../references/checklist.md. Screenshots are full-page PNGs per device x page.

import { existsSync, mkdirSync, mkdtempSync, writeFileSync } from 'node:fs'
import { tmpdir } from 'node:os'
import { join } from 'node:path'

import { chromium, devices, webkit } from '@playwright/test'

const DEVICES = {
  'iphone-se': 'iPhone SE (3rd gen)',
  'iphone-se-landscape': 'iPhone SE (3rd gen) landscape',
  'iphone-17-pro': 'iPhone 17 Pro',
  'pixel-7': 'Pixel 7',
  'ipad-mini': 'iPad Mini',
}

// A Chromium-family browser already on this machine, so Playwright's own Chromium is optional
// (same lookup as eu27-data-sovereignty/web/playwright.config.ts). CHROME_PATH overrides.
const CHROME_CANDIDATES = [
  '/Applications/Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
]

// Errors that are not defects of the page under test.
const DEFAULT_IGNORE = [/favicon\.ico\)?$/, /\/_vercel\/(insights|speed-insights)\//]

function usage(msg) {
  if (msg) console.error(`mobile-audit: ${msg}`)
  console.error('usage: mobile-audit.mjs <url> [<path-or-url> ...] [--out DIR] [--devices a,b] [--no-throttle] [--ignore-errors REGEX]')
  console.error(`devices: ${Object.keys(DEVICES).join(', ')}`)
  process.exit(2)
}

function parseArgs(argv) {
  const opts = { pages: [], out: null, devices: Object.keys(DEVICES), throttle: true, ignore: [...DEFAULT_IGNORE] }
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i]
    if (a === '-h' || a === '--help') usage()
    else if (a === '--out') opts.out = argv[++i] ?? usage('--out needs a directory')
    else if (a === '--devices') opts.devices = (argv[++i] ?? usage('--devices needs a list')).split(',')
    else if (a === '--no-throttle') opts.throttle = false
    else if (a === '--ignore-errors') {
      const re = argv[++i] ?? usage('--ignore-errors needs a regex')
      try {
        opts.ignore.push(new RegExp(re))
      } catch {
        usage(`not a valid regex: ${re}`)
      }
    }
    else if (a.startsWith('-')) usage(`unknown option: ${a}`)
    else opts.pages.push(a)
  }
  if (!opts.pages.length) usage('no url given')
  for (const d of opts.devices) if (!DEVICES[d]) usage(`unknown device: ${d}`)
  let base
  try {
    base = new URL(opts.pages[0])
  } catch {
    usage(`not a URL: ${opts.pages[0]}`)
  }
  opts.urls = opts.pages.map(p => new URL(p, base).href)
  try {
    opts.out ??= mkdtempSync(join(tmpdir(), 'mobile-audit-'))
    mkdirSync(join(opts.out, 'screenshots'), { recursive: true })
  } catch (e) {
    usage(`cannot create --out directory: ${e.message}`)
  }
  return opts
}

// Runs inside the page. Returns [{ check, level, detail, examples }]. Kept dependency-free.
async function inPageChecks() {
  const out = []
  const add = (check, level, detail, examples = []) => out.push({ check, level, detail, examples: examples.slice(0, 5) })
  const de = document.documentElement
  const vw = de.clientWidth
  const vh = window.innerHeight

  const describe = el => {
    let s = el.tagName.toLowerCase()
    if (el.id) s += `#${el.id}`
    else if (el.classList.length) s += `.${[...el.classList].slice(0, 2).join('.')}`
    const t = (el.getAttribute('aria-label') || el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 30)
    return t ? `${s} "${t}"` : s
  }
  const visible = el => {
    const r = el.getBoundingClientRect()
    if (r.width === 0 || r.height === 0) return false
    const cs = getComputedStyle(el)
    if (cs.visibility === 'hidden' || cs.display === 'none' || Number(cs.opacity) === 0) return false
    // Visually-hidden (sr-only) text: 1px box or clipped.
    if (r.width <= 1 && r.height <= 1) return false
    return true
  }

  // Viewport meta.
  const meta = document.querySelector('meta[name="viewport"]')
  const content = (meta?.getAttribute('content') || '').toLowerCase().replace(/\s/g, '')
  if (!meta) add('viewport-meta', 'FAIL', 'no <meta name="viewport">: phones render a 980 px desktop page zoomed out')
  else {
    if (!content.includes('width=device-width')) add('viewport-meta', 'FAIL', `viewport content lacks width=device-width: "${content}"`)
    if (/user-scalable=(no|0)/.test(content)) add('viewport-zoom', 'FAIL', 'user-scalable=no blocks pinch zoom (WCAG 1.4.4)')
    const max = content.match(/maximum-scale=([\d.]+)/)
    if (max && Number(max[1]) < 2) add('viewport-zoom', 'FAIL', `maximum-scale=${max[1]} blocks zoom to 200% (WCAG 1.4.4)`)
  }

  // Horizontal overflow.
  // An element inside a scroll or clip container (overflow-x not visible) cannot widen the page.
  const clippedByAncestor = el => {
    for (let p = el.parentElement; p && p !== document.body; p = p.parentElement) {
      if (getComputedStyle(p).overflowX !== 'visible') return true
    }
    return false
  }
  // The page should scroll on the document. When <body> (or a full-screen wrapper) is the scroller,
  // iOS Safari's bars never collapse, tapping the status bar does not scroll to top, and full-page
  // screenshots stop at the first screen.
  const scroller = [document.body, ...document.body.children].find(el => {
    const cs = getComputedStyle(el)
    return /(auto|scroll)/.test(cs.overflowY) && el.scrollHeight > el.clientHeight + 1 && el.clientHeight >= vh * 0.9
  })
  if (scroller && de.scrollHeight <= vh + 1) {
    add('body-scroller', 'FAIL', `the page scrolls inside ${describe(scroller)}, not the document: iOS Safari bars stay expanded, status-bar tap-to-top fails, screenshots cut off after one screen`)
  }
  const overflow = Math.max(de.scrollWidth, scroller ? scroller.scrollWidth : 0) - vw
  if (overflow > 1) {
    const offenders = [...document.body.querySelectorAll('*')]
      .filter(el => {
        const r = el.getBoundingClientRect()
        return r.width > 0 && r.right > vw + 1 && !clippedByAncestor(el)
      })
      // Keep the outermost offenders only.
      .filter((el, _, all) => !all.some(o => o !== el && o.contains(el)))
      .map(el => `${describe(el)} (right edge ${Math.round(el.getBoundingClientRect().right)} px)`)
    add('h-overflow', 'FAIL', `page is ${overflow} px wider than the ${vw} px viewport: sideways scrolling`, offenders)
  }

  // Tap targets. Inline links inside running text are exempt (WCAG 2.5.8 inline exception).
  const interactive = document.querySelectorAll(
    'a[href], button, input:not([type="hidden"]), select, textarea, summary, [role="button"], [role="link"], [role="tab"], [role="checkbox"], [onclick], [tabindex]:not([tabindex="-1"])',
  )
  // Sizes are compared after rounding to 0.1 px, so a 24 px box laid out at 23.99 still counts as 24.
  const px = v => Math.round(v * 10) / 10
  const targets = []
  const tinyCandidates = []
  const small = []
  for (const el of interactive) {
    if (!visible(el)) continue
    const cs = getComputedStyle(el)
    if (el.tagName === 'A' && cs.display === 'inline') {
      // In a sentence: the nearest non-inline ancestor (past sup, em, span) holds more text than the link.
      let block = el.parentElement
      while (block && block !== document.body && getComputedStyle(block).display === 'inline') block = block.parentElement
      const blockText = (block?.textContent || '').trim().length
      const ownText = (el.textContent || '').trim().length
      if (blockText > ownText + 10) continue
    }
    // A checkbox or radio wrapped in (or labelled by) a label: the label is the target.
    if (el.matches('input[type="checkbox"], input[type="radio"]')) {
      const label = el.closest('label') || (el.id && document.querySelector(`label[for="${CSS.escape(el.id)}"]`))
      if (label && visible(label)) {
        const lr = label.getBoundingClientRect()
        if (lr.width >= 44 && lr.height >= 44) continue
        if (lr.width >= 24 && lr.height >= 24) { small.push(describe(label)); continue }
      }
    }
    const r = el.getBoundingClientRect()
    targets.push({ el, r })
    const size = `${Math.round(r.width)}x${Math.round(r.height)}`
    if (px(r.width) < 24 || px(r.height) < 24) tinyCandidates.push({ el, r, size })
    else if (px(r.width) < 44 || px(r.height) < 44) small.push(`${describe(el)} ${size}`)
  }
  // WCAG 2.5.8 spacing exception: an undersized target passes when a 24 px circle centred on it meets
  // no other target, and no other undersized target's circle (centres at least 24 px apart).
  const centre = r => [r.left + r.width / 2, r.top + r.height / 2]
  const distToRect = ([x, y], r) => Math.hypot(Math.max(r.left - x, 0, x - r.right), Math.max(r.top - y, 0, y - r.bottom))
  const isTiny = new Set(tinyCandidates.map(c => c.el))
  const tiny = tinyCandidates
    .filter(c => {
      const cc = centre(c.r)
      return targets.some(t => {
        if (t.el === c.el || t.el.contains(c.el) || c.el.contains(t.el)) return false
        if (isTiny.has(t.el)) {
          const tc = centre(t.r)
          return Math.hypot(cc[0] - tc[0], cc[1] - tc[1]) < 24
        }
        return distToRect(cc, t.r) < 12
      })
    })
    .map(c => `${describe(c.el)} ${c.size}`)
  const spaced = tinyCandidates.length - tiny.length
  if (spaced) add('tap-target-spaced', 'INFO', `${spaced} target(s) under 24 px pass on spacing (WCAG 2.5.8 exception)`)
  if (tiny.length) add('tap-target', 'FAIL', `${tiny.length} tap target(s) under 24x24 px (WCAG 2.5.8 minimum)`, tiny)
  if (small.length) add('tap-target-small', 'WARN', `${small.length} tap target(s) under 44x44 px (Apple HIG / WCAG 2.5.5)`, small)

  // Form fields under 16 px: iOS Safari zooms the page on focus.
  const zoomers = [...document.querySelectorAll('input, select, textarea')]
    .filter(el => !/^(hidden|checkbox|radio|range|color|file|submit|button|reset|image)$/.test(el.type || ''))
    .filter(visible)
    .filter(el => parseFloat(getComputedStyle(el).fontSize) < 16)
    .map(el => `${describe(el)} ${getComputedStyle(el).fontSize}`)
  if (zoomers.length) add('input-zoom', 'FAIL', `${zoomers.length} form field(s) under 16 px font: iOS zooms in on focus`, zoomers)

  // Small text.
  const smallText = []
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
  const seen = new Set()
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    const el = n.parentElement
    if (!el || seen.has(el) || !n.textContent.trim()) continue
    seen.add(el)
    if (el.closest('script, style, noscript, sup, sub, svg') || !visible(el)) continue
    const fs = parseFloat(getComputedStyle(el).fontSize)
    if (fs < 12) smallText.push(`${describe(el)} ${fs}px`)
  }
  // Words split across lines mid-word ("CONTAC / T"): a narrow box with overflow-wrap or letter-spacing.
  // Words over 30 characters (hashes, URLs) and hyphenated text may break; that is expected.
  const splitWords = []
  const range = document.createRange()
  const wordWalker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT)
  let scanned = 0
  for (let n = wordWalker.nextNode(); n && scanned < 5000 && splitWords.length < 20; n = wordWalker.nextNode()) {
    const el = n.parentElement
    if (!el || el.closest('script, style, noscript, svg, pre, code') || !visible(el)) continue
    if (getComputedStyle(el).hyphens === 'auto') continue
    for (const m of n.textContent.matchAll(/(?<![\p{L}\p{N}])[\p{L}\p{N}]{4,30}(?![\p{L}\p{N}])/gu)) {
      scanned++
      range.setStart(n, m.index)
      range.setEnd(n, m.index + m[0].length)
      const tops = new Set([...range.getClientRects()].filter(r => r.width > 0).map(r => Math.round(r.top)))
      if (tops.size > 1) splitWords.push(`${describe(el)}: "${m[0]}"`)
    }
  }
  if (splitWords.length) add('word-split', 'FAIL', `${splitWords.length} word(s) broken across lines mid-word`, splitWords)
  if (smallText.length) add('small-text', 'FAIL', `${smallText.length} text element(s) under 12 px`, smallText)

  // Stylesheet scan: hover-only reveals, 100vh, safe-area use. Cross-origin sheets cannot be read.
  let cssText = ''
  const hoverReveal = []
  const vhRules = []
  const unreadable = []
  const focusSelectors = new Set()
  const hoverRules = []
  const walk = (rules, inHoverMedia) => {
    for (const rule of rules) {
      // With CSS nesting every style rule also has cssRules, so test for a selector first.
      if (!rule.selectorText) {
        if (rule.cssRules) {
          const hoverMedia = rule.media && /\(hover:\s*hover\)|\(any-hover:\s*hover\)/.test(rule.media.mediaText)
          walk(rule.cssRules, inHoverMedia || hoverMedia)
        }
        continue
      }
      if (rule.cssRules?.length) walk(rule.cssRules, inHoverMedia)
      cssText += rule.cssText
      const sel = rule.selectorText
      if (/:focus|:active|:focus-within|:focus-visible/.test(sel)) {
        sel.split(',').forEach(s => focusSelectors.add(s.trim().replace(/:(focus-visible|focus-within|focus|active)/g, '')))
      }
      if (sel.includes(':hover') && !inHoverMedia) {
        const st = rule.style
        // A reveal, not a hover effect: shown (display not none, visible, fully opaque, or opened up).
        const reveals =
          (st.display && st.display !== 'none') ||
          st.visibility === 'visible' ||
          st.opacity === '1' ||
          (st.maxHeight && st.maxHeight !== '0px' && st.maxHeight !== '0')
        if (reveals) hoverRules.push(sel)
      }
      const h = `${rule.style?.height || ''} ${rule.style?.minHeight || ''}`
      if (/(^|[^d])100vh/.test(h)) vhRules.push(sel)
    }
  }
  for (const sheet of document.styleSheets) {
    try {
      walk(sheet.cssRules, false)
    } catch {
      unreadable.push(sheet.href)
    }
  }
  // Engines may drop env() from a serialized shorthand, so also search the source text.
  for (const el of document.querySelectorAll('[style]')) cssText += el.getAttribute('style')
  for (const el of document.querySelectorAll('style')) cssText += el.textContent
  for (const link of document.querySelectorAll('link[rel~="stylesheet"][href]')) {
    if (new URL(link.href).origin !== location.origin) continue
    try {
      cssText += await (await fetch(link.href)).text()
    } catch {
      /* unreadable: the rule scan above still ran */
    }
  }
  for (const sel of hoverRules) {
    const parts = sel.split(',').map(s => s.trim()).filter(s => s.includes(':hover'))
    if (parts.some(p => !focusSelectors.has(p.replace(/:hover/g, '')))) hoverReveal.push(sel)
  }
  if (hoverReveal.length) add('hover-only', 'WARN', `${hoverReveal.length} :hover rule(s) reveal content with no :focus/:active twin and outside @media (hover: hover): touch users may never see it`, hoverReveal)
  if (vhRules.length) add('100vh', 'WARN', `${vhRules.length} rule(s) use 100vh: on phones it ignores the browser bars; use 100dvh or 100svh`, vhRules)
  if (content.includes('viewport-fit=cover') && !cssText.includes('safe-area-inset')) {
    add('safe-area', 'FAIL', 'viewport-fit=cover without env(safe-area-inset-*): content goes under the notch and home bar')
  }
  if (unreadable.length) add('css-unreadable', 'INFO', `${unreadable.length} cross-origin stylesheet(s) not scanned`, unreadable)

  // Fixed elements covering much of the screen.
  const covering = [...document.body.querySelectorAll('*')]
    .filter(el => getComputedStyle(el).position === 'fixed' && visible(el))
    .filter(el => {
      const r = el.getBoundingClientRect()
      const w = Math.max(0, Math.min(r.right, vw) - Math.max(r.left, 0))
      const h = Math.max(0, Math.min(r.bottom, vh) - Math.max(r.top, 0))
      return (w * h) / (vw * vh) > 0.3
    })
    .map(describe)
  if (covering.length) add('fixed-cover', 'FAIL', `${covering.length} fixed element(s) cover over 30% of the screen on load`, covering)

  // Media.
  const wideMedia = [...document.querySelectorAll('img, video, iframe, canvas, svg, table, pre')]
    .filter(visible)
    .filter(el => el.getBoundingClientRect().width > vw + 1 && !clippedByAncestor(el))
    .map(el => `${describe(el)} ${Math.round(el.getBoundingClientRect().width)}px`)
  if (wideMedia.length) add('media-width', 'FAIL', `${wideMedia.length} element(s) wider than the viewport`, wideMedia)
  const heavy = [...document.images]
    .filter(img => img.naturalWidth > 1000 && !img.srcset && !img.closest('picture'))
    .map(img => `${img.currentSrc.split('/').pop()} ${img.naturalWidth}px`)
  if (heavy.length) add('img-srcset', 'WARN', `${heavy.length} image(s) over 1000 px wide with no srcset: phones download the full size`, heavy)

  return out
}

async function launch(type) {
  if (type === 'chromium') {
    const executablePath = process.env.CHROME_PATH ?? CHROME_CANDIDATES.find(p => existsSync(p))
    return chromium.launch(executablePath ? { executablePath } : {})
  }
  if (type === 'webkit') return webkit.launch()
  throw new Error(`unsupported browser type ${type}`)
}

async function auditPage(context, url, shotPath, ignore) {
  const page = await context.newPage()
  const errors = []
  const keep = msg => !ignore.some(re => re.test(msg))
  page.on('pageerror', e => {
    const msg = `pageerror: ${e.message}`
    if (keep(msg)) errors.push(msg)
  })
  page.on('console', m => {
    if (m.type() !== 'error') return
    const where = m.location().url || ''
    const msg = `console: ${m.text()}${where ? ` (${where})` : ''}`
    if (keep(msg)) errors.push(msg)
  })
  let findings
  try {
    const resp = await page.goto(url, { waitUntil: 'load', timeout: 30_000 })
    await page.waitForLoadState('networkidle', { timeout: 5_000 }).catch(() => {})
    await page.evaluate(() => document.fonts.ready)
    findings = await page.evaluate(inPageChecks)
    if (resp && resp.status() >= 400) findings.unshift({ check: 'http-status', level: 'FAIL', detail: `HTTP ${resp.status()}`, examples: [] })
    await page.screenshot({ path: shotPath, fullPage: true })
  } catch (e) {
    findings = [{ check: 'load', level: 'FAIL', detail: `page did not load: ${e.message.split('\n')[0]}`, examples: [] }]
  }
  if (errors.length) findings.push({ check: 'js-errors', level: 'FAIL', detail: `${errors.length} console/page error(s)`, examples: errors.slice(0, 5) })
  await page.close()
  return findings
}

// Slow phone: Pixel 7 in Chromium, 4x CPU slowdown, Slow 4G (Lighthouse mobile profile). LCP > 4 s is a WARN.
async function throttledLoad(browser, url) {
  const context = await browser.newContext(devices['Pixel 7'])
  const page = await context.newPage()
  try {
    const cdp = await context.newCDPSession(page)
    await cdp.send('Emulation.setCPUThrottlingRate', { rate: 4 })
    await cdp.send('Network.enable')
    await cdp.send('Network.emulateNetworkConditions', {
      offline: false,
      latency: 150,
      downloadThroughput: (1.6 * 1024 * 1024) / 8,
      uploadThroughput: (750 * 1024) / 8,
    })
    await page.goto(url, { waitUntil: 'load', timeout: 60_000 })
    const lcp = await page.evaluate(
      () =>
        new Promise(resolve => {
          let last = 0
          new PerformanceObserver(list => {
            for (const e of list.getEntries()) last = e.startTime
          }).observe({ type: 'largest-contentful-paint', buffered: true })
          setTimeout(() => resolve(last), 1500)
        }),
    )
    const ms = Math.round(lcp)
    return ms > 4000
      ? { check: 'slow-lcp', level: 'WARN', detail: `LCP ${ms} ms on a throttled phone (target under 2500, warn over 4000)`, examples: [] }
      : { check: 'slow-lcp', level: 'INFO', detail: `LCP ${ms} ms on a throttled phone`, examples: [] }
  } catch (e) {
    return { check: 'slow-lcp', level: 'WARN', detail: `throttled load failed: ${e.message.split('\n')[0]}`, examples: [] }
  } finally {
    await context.close()
  }
}

const slug = url => {
  const u = new URL(url)
  return (u.pathname.replace(/\/+$/, '') || '/root').replace(/[^a-z0-9]+/gi, '-').replace(/^-|-$/g, '') || 'root'
}

async function main() {
  const opts = parseArgs(process.argv.slice(2))
  const results = []
  const browsers = {}
  try {
    for (const key of opts.devices) {
      const desc = devices[DEVICES[key]]
      const type = desc.defaultBrowserType
      browsers[type] ??= await launch(type)
      const context = await browsers[type].newContext(desc)
      for (const url of opts.urls) {
        const shot = join('screenshots', `${key}--${slug(url)}.png`)
        const findings = await auditPage(context, url, join(opts.out, shot), opts.ignore)
        results.push({ device: key, url, screenshot: shot, findings })
      }
      await context.close()
    }
    if (opts.throttle) {
      browsers.chromium ??= await launch('chromium')
      for (const url of opts.urls) {
        results.push({ device: 'pixel-7-throttled', url, screenshot: null, findings: [await throttledLoad(browsers.chromium, url)] })
      }
    }
  } catch (e) {
    console.error(`mobile-audit: ${e.message.split('\n')[0]}`)
    console.error('If a browser is missing: cd to this script\'s folder and run  npx playwright install webkit')
    process.exit(2)
  } finally {
    for (const b of Object.values(browsers)) await b.close()
  }

  const count = lvl => results.reduce((n, r) => n + r.findings.filter(f => f.level === lvl).length, 0)
  const summary = { fail: count('FAIL'), warn: count('WARN') }
  const report = { generatedAt: new Date().toISOString(), urls: opts.urls, devices: opts.devices, summary, results }
  writeFileSync(join(opts.out, 'report.json'), JSON.stringify(report, null, 2))

  const lines = [
    `# Mobile audit · ${report.generatedAt.slice(0, 16).replace('T', ' ')} UTC`,
    '',
    `Pages: ${opts.urls.join(', ')}`,
    '',
    `**${summary.fail} FAIL · ${summary.warn} WARN** — ${summary.fail ? 'not mobile-ready' : 'no FAIL'}`,
    '',
    '| Device | Page | FAIL | WARN | Checks |',
    '|---|---|---|---|---|',
  ]
  for (const r of results) {
    const f = r.findings.filter(x => x.level === 'FAIL')
    const w = r.findings.filter(x => x.level === 'WARN')
    const ids = [...new Set([...f, ...w].map(x => x.check))].join(', ') || '—'
    lines.push(`| ${r.device} | ${new URL(r.url).pathname} | ${f.length} | ${w.length} | ${ids} |`)
  }
  lines.push('', '## Findings', '')
  for (const r of results) {
    const shown = r.findings.filter(x => x.level !== 'INFO' || x.check === 'slow-lcp')
    if (!shown.length) continue
    lines.push(`### ${r.device} · ${new URL(r.url).pathname}${r.screenshot ? ` · \`${r.screenshot}\`` : ''}`, '')
    for (const x of shown) {
      lines.push(`- **${x.level}** \`${x.check}\`: ${x.detail}`)
      for (const e of x.examples) lines.push(`  - ${e}`)
    }
    lines.push('')
  }
  const md = lines.join('\n')
  writeFileSync(join(opts.out, 'report.md'), md)
  console.log(md)
  console.log(`\nReport: ${join(opts.out, 'report.md')}  JSON: ${join(opts.out, 'report.json')}`)
  process.exit(summary.fail ? 1 : 0)
}

main()
