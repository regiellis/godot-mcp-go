// Rasterize the master brand mark (public/brand/mark.svg) to PNG.
//
// One mark serves the favicon, the topbar logo, the README header, the social
// card, and the Godot addon icon, so every raster copy has to come from the same
// SVG. Run this after touching mark.svg:
//
//   node tools/render-mark.mjs
//
// Lives here rather than in ../scripts because it needs playwright-core, which
// is a website dependency. Uses the msedge channel, matching how rendered
// results get verified elsewhere in this project.
import { chromium } from 'playwright-core'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { dirname, resolve } from 'node:path'

const here = dirname(fileURLToPath(import.meta.url))
const svg = readFileSync(resolve(here, '../public/brand/mark.svg'), 'utf8')

// size: rendered pixel square. out: path relative to THIS file (website/tools),
// so a repo-root target needs two levels up.
const TARGETS = [
  { size: 256, out: '../../project/addons/godot_mcp/icon.png' },
]

const browser = await chromium.launch({ channel: 'msedge' })
try {
  for (const { size, out } of TARGETS) {
    const page = await browser.newPage({
      viewport: { width: size, height: size },
      deviceScaleFactor: 1,
    })
    // The mark carries its own dark ground; omitBackground keeps the rounded
    // corners transparent instead of filling them white.
    await page.setContent(
      `<!doctype html><meta charset="utf-8">
       <style>
         html,body{margin:0;padding:0;background:transparent}
         svg{display:block;width:${size}px;height:${size}px}
       </style>
       ${svg}`,
      { waitUntil: 'load' },
    )
    const target = resolve(here, out)
    await page.screenshot({ path: target, omitBackground: true })
    await page.close()
    // The script's only output: what it wrote, so a caller can verify it.
    process.stdout.write(`${size}x${size} -> ${target}\n`)
  }
} finally {
  await browser.close()
}
