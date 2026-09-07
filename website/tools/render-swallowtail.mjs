// Render the website social card from the approved provisional mascot.
// Run from website: node tools/render-swallowtail.mjs
import { chromium } from 'playwright-core'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'

const asset = new URL('../public/brand/swallowtail-butler.png', import.meta.url)
const output = new URL('../public/brand/swallowtail-og.png', import.meta.url)
const mascot = readFileSync(asset).toString('base64')
const browser = await chromium.launch({ channel: 'msedge', headless: true })
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 })
  await page.setContent(`<!doctype html><html lang="en"><meta charset="utf-8">
    <title>Swallowtail social card</title>
    <style>
      * { box-sizing: border-box }
      body { margin: 0; background: #faf6ef; color: #211c25; font-family: 'Segoe UI', sans-serif }
      main { width: 1200px; height: 630px; display: flex; align-items: center; padding: 72px; gap: 12px }
      section { flex: 1 }
      .eyebrow { color: #81485f; font-size: 18px; letter-spacing: 3px; font-weight: 700 }
      h1 { font-size: 78px; letter-spacing: -5px; margin: 18px 0 12px; line-height: 1.1 }
      .lede { font-size: 34px; color: #665b63; margin: 0 0 36px }
      .audience { font-size: 22px; font-weight: 600 }
      img { width: 410px; height: 410px; object-fit: contain }
    </style>
    <main><section><p class="eyebrow">AT YOUR SERVICE.</p><h1>Swallowtail</h1>
    <p class="lede">Godot automation.</p><p class="audience">Your game. Your workflow.</p></section>
    <img src="data:image/png;base64,${mascot}" alt="Swallowtail butler"></main></html>`)
  await page.locator('img').evaluate(img => img.decode())
  await page.screenshot({ path: fileURLToPath(output) })
  console.log(fileURLToPath(output))
} finally {
  await browser.close()
}
