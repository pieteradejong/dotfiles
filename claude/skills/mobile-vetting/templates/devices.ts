/**
 * Mobile device projects for a project's playwright.config.ts (mobile-vetting skill, dotfiles D75).
 *
 *   import { mobileProjects } from './e2e/mobile-devices'
 *   export default defineConfig({ projects: [ ...yourProjects, ...mobileProjects ] })
 *
 * The iPhones and iPad run in Playwright's WebKit (`npx playwright install webkit`; CI installs it too).
 * Pixel 7 runs in a Chromium-family browser already on the machine when one is found (CHROME_PATH
 * overrides), else Playwright's own Chromium. Each project runs only e2e/mobile.spec.ts unless you
 * widen testMatch.
 */
import { existsSync } from 'node:fs'

import { devices, type PlaywrightTestProject } from '@playwright/test'

const CHROME = [
  '/Applications/Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
  '/Applications/Brave Browser.app/Contents/MacOS/Brave Browser',
  '/usr/bin/google-chrome',
  '/usr/bin/chromium',
]
const executablePath = process.env.CHROME_PATH ?? CHROME.find(p => existsSync(p))

const MOBILE_SPEC = /mobile\.spec\.ts$/

export const mobileProjects: PlaywrightTestProject[] = [
  { name: 'iphone-se', testMatch: MOBILE_SPEC, use: { ...devices['iPhone SE (3rd gen)'] } },
  { name: 'iphone-se-landscape', testMatch: MOBILE_SPEC, use: { ...devices['iPhone SE (3rd gen) landscape'] } },
  { name: 'iphone-17-pro', testMatch: MOBILE_SPEC, use: { ...devices['iPhone 17 Pro'] } },
  {
    name: 'pixel-7',
    testMatch: MOBILE_SPEC,
    use: { ...devices['Pixel 7'], ...(executablePath ? { launchOptions: { executablePath } } : {}) },
  },
  { name: 'ipad-mini', testMatch: MOBILE_SPEC, use: { ...devices['iPad Mini'] } },
]
