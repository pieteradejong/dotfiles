/**
 * Mobile checks that stay in a project's suite (mobile-vetting skill, dotfiles D75). Copy to
 * e2e/mobile.spec.ts, set ROUTES, and add the projects from mobile-devices.ts. These are the FAIL-level
 * checks of the skill's mobile-audit.mjs, kept small enough to read; the full audit, with WARNs,
 * screenshots and a throttled load, is that script.
 *
 * MOBILE_ROUTES (comma-separated) overrides ROUTES, e.g. MOBILE_ROUTES=/,/about npx playwright test.
 */
import { expect, test } from '@playwright/test'

const ROUTES = (process.env.MOBILE_ROUTES ?? '/').split(',')
// Not defects of the page: a missing favicon, and Vercel Analytics, which exists only on a Vercel deploy.
const IGNORE = [/favicon\.ico$/, /\/_vercel\/(insights|speed-insights)\//]

for (const route of ROUTES) {
  test.describe(`mobile ${route}`, () => {
    test('loads without JS errors', async ({ page }) => {
      const errors: string[] = []
      page.on('pageerror', e => errors.push(e.message))
      page.on('console', m => {
        const where = m.location().url || ''
        if (m.type() === 'error' && !IGNORE.some(re => re.test(where))) errors.push(`${m.text()} (${where})`)
      })
      const resp = await page.goto(route)
      expect(resp?.status() ?? 0, 'HTTP status').toBeLessThan(400)
      await page.waitForLoadState('networkidle').catch(() => {})
      expect(errors).toEqual([])
    })

    test('viewport meta allows device width and zoom', async ({ page }) => {
      await page.goto(route)
      const content = ((await page.locator('meta[name="viewport"]').getAttribute('content')) ?? '')
        .toLowerCase()
        .replace(/\s/g, '')
      expect(content).toContain('width=device-width')
      expect(content).not.toMatch(/user-scalable=(no|0)/)
      const max = content.match(/maximum-scale=([\d.]+)/)
      if (max) expect(Number(max[1])).toBeGreaterThanOrEqual(2)
    })

    test('no horizontal overflow', async ({ page }) => {
      await page.goto(route)
      await page.evaluate(() => document.fonts.ready)
      const overflow = await page.evaluate(
        () => document.documentElement.scrollWidth - document.documentElement.clientWidth,
      )
      expect(overflow).toBeLessThanOrEqual(1)
    })

    test('form fields are at least 16 px (no iOS focus zoom)', async ({ page }) => {
      await page.goto(route)
      const small = await page.evaluate(() =>
        [...document.querySelectorAll<HTMLInputElement>('input, select, textarea')]
          .filter(el => !/^(hidden|checkbox|radio|range|color|file|submit|button|reset|image)$/.test(el.type || ''))
          .filter(el => el.getBoundingClientRect().width > 0)
          .filter(el => parseFloat(getComputedStyle(el).fontSize) < 16)
          .map(el => el.outerHTML.slice(0, 80)),
      )
      expect(small).toEqual([])
    })

    test('tap targets are at least 24x24 px', async ({ page }) => {
      await page.goto(route)
      const tiny = await page.evaluate(() =>
        [...document.querySelectorAll<HTMLElement>('a[href], button, input:not([type="hidden"]), select, textarea, [role="button"]')]
          .filter(el => {
            const r = el.getBoundingClientRect()
            if (r.width <= 1 || r.height <= 1 || getComputedStyle(el).visibility === 'hidden') return false
            // Inline links in running text are exempt (WCAG 2.5.8).
            if (el.tagName === 'A' && getComputedStyle(el).display === 'inline') {
              if ((el.parentElement?.textContent ?? '').trim().length > (el.textContent ?? '').trim().length + 10) return false
            }
            if (el.matches('input[type="checkbox"], input[type="radio"]') && el.closest('label')) {
              const lr = el.closest('label')!.getBoundingClientRect()
              if (lr.width >= 24 && lr.height >= 24) return false
            }
            return r.width < 24 || r.height < 24
          })
          .map(el => el.outerHTML.slice(0, 80)),
      )
      expect(tiny).toEqual([])
    })
  })
}
