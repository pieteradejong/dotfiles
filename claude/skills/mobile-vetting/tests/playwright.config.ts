/**
 * Runs templates/mobile.spec.ts with templates/devices.ts against the fixture server, so dotfiles'
 * scripts/test-mobile-vetting.sh proves the drop-in template works (D75). Not for projects: they copy
 * the two template files instead.
 *
 *   BASE_URL=http://127.0.0.1:PORT MOBILE_ROUTES=/good.html PW_OUT=/tmp/x npx playwright test -c tests
 */
import { defineConfig } from '@playwright/test'

import { mobileProjects } from '../templates/devices'

export default defineConfig({
  testDir: '../templates',
  outputDir: process.env.PW_OUT ?? 'test-results',
  reporter: 'line',
  workers: 4,
  use: { baseURL: process.env.BASE_URL },
  projects: mobileProjects,
})
