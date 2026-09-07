// Run from website/ with the dev server up: node tools/check-workflow-showcase.mjs [homepage URL]
// Covers the homepage workflow showcase: typing completion, auto-advance, hover
// pause, manual takeover, keyboard selection, reduced motion, and 320px overflow.
import assert from 'node:assert/strict';
import { mkdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import { chromium } from 'playwright-core';

const url = process.argv[2] ?? 'http://127.0.0.1:4321/godot-mcp-go/';
const shots = fileURLToPath(new URL('../.playwright/', import.meta.url));
await mkdir(shots, { recursive: true });

const browser = await chromium.launch({ channel: 'msedge', headless: true });
const errors = [];

const selected = page => page.evaluate(() =>
  [...document.querySelectorAll('[data-workflow-showcase] [role="tab"]')].findIndex(t => t.getAttribute('aria-selected') === 'true'));
const complete = (page, index) => page.waitForFunction(i => {
  const panel = document.querySelectorAll('[data-workflow-showcase] [role="tabpanel"]')[i];
  const lines = [...panel.querySelectorAll('.tl')];
  // A blank line in the captured output carries no text of its own, so only a
  // line that should hold text has to hold it.
  const blank = line => line.classList.contains('out') && line.textContent === '\n';
  return !panel.querySelector('.sc-caret')
    && lines.every(line => getComputedStyle(line).visibility === 'visible')
    && lines.every(line => blank(line) || line.textContent.trim().length > 0);
}, index, { timeout: 25000 });

function watch(page) {
  page.on('pageerror', error => errors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') errors.push(message.text()); });
}

try {
  for (const width of [1440, 390]) {
    for (const theme of ['light', 'dark']) {
      const page = await browser.newPage({ viewport: { width, height: 1000 } });
      watch(page);
      await page.goto(url);
      await page.evaluate(t => document.documentElement.dataset.theme = t, theme);
      const showcase = page.locator('[data-workflow-showcase]');
      const tabs = page.locator('[data-workflow-showcase] [role="tab"]');
      await showcase.scrollIntoViewIfNeeded();
      await page.mouse.move(5, 5);

      // The first session finishes typing on its own, then hands over.
      await complete(page, 0);
      assert.equal(await selected(page), 0, `${width}/${theme}: first tab selected`);
      await page.waitForFunction(
        () => document.querySelectorAll('[data-workflow-showcase] [role="tab"]')[1].getAttribute('aria-selected') === 'true',
        null, { timeout: 20000 });
      await complete(page, 1);

      // Pointer over the component freezes the dwell.
      await showcase.hover();
      const held = await selected(page);
      await page.waitForTimeout(9000);
      assert.equal(await selected(page), held, `${width}/${theme}: hover pauses advance`);
      assert.equal(await showcase.getAttribute('data-paused'), '', `${width}/${theme}: paused flag`);
      await page.mouse.move(5, 5);

      // A click is the visitor taking over: selection sticks and rotation ends.
      await tabs.nth(2).click();
      assert.equal(await selected(page), 2, `${width}/${theme}: click selects tab 3`);
      assert.equal(await showcase.getAttribute('data-auto'), null, `${width}/${theme}: auto-rotation stopped`);
      await complete(page, 2);
      await page.mouse.move(5, 5);
      await page.waitForTimeout(9000);
      assert.equal(await selected(page), 2, `${width}/${theme}: no advance after takeover`);

      // Arrow keys move selection and focus together.
      await tabs.nth(2).focus();
      await page.keyboard.press('ArrowDown');
      assert.equal(await selected(page), 3, `${width}/${theme}: ArrowDown moves selection`);
      assert.equal(await page.evaluate(() => document.activeElement.id), 'sc-tab-3', `${width}/${theme}: focus follows`);
      await page.keyboard.press('Home');
      assert.equal(await selected(page), 0, `${width}/${theme}: Home jumps to the first tab`);

      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth), `${width}/${theme}: no horizontal overflow`);

      await page.close();
    }
  }

  // Reduced motion: complete on arrival, no typing, no auto-advance.
  for (const width of [1440, 390]) {
    const page = await browser.newPage({ viewport: { width, height: 1000 }, reducedMotion: 'reduce' });
    watch(page);
    await page.goto(url);
    await page.locator('[data-workflow-showcase]').scrollIntoViewIfNeeded();
    await complete(page, 0);
    assert.equal(await page.locator('[data-workflow-showcase] .sc-progress').first().isVisible(), false, `${width}: no progress bar`);
    assert.equal(await page.locator('[data-workflow-showcase]').getAttribute('data-auto'), null, `${width}: no auto-rotation`);
    await page.waitForTimeout(9000);
    assert.equal(await selected(page), 0, `${width}: reduced motion holds the first session`);
    await page.locator('[data-workflow-showcase] [role="tab"]').nth(1).click();
    assert.equal(await selected(page), 1, `${width}: tabs still switch`);
    await complete(page, 1);
    await page.close();
  }

  // Narrow phone: the tabs stack above the terminal and nothing overflows.
  const narrow = await browser.newPage({ viewport: { width: 320, height: 800 } });
  watch(narrow);
  await narrow.goto(url);
  await narrow.locator('[data-workflow-showcase]').scrollIntoViewIfNeeded();
  await complete(narrow, 0);
  assert(await narrow.evaluate(() => document.documentElement.scrollWidth <= innerWidth), '320px: no horizontal overflow');
  const order = await narrow.evaluate(() => {
    const box = s => document.querySelector(`[data-workflow-showcase] ${s}`).getBoundingClientRect();
    return { tabs: box('.sc-tabs').bottom, stage: box('.sc-stage').top };
  });
  assert(order.tabs <= order.stage + 1, '320px: tabs sit above the terminal');
  await narrow.close();

  // Reference frames of the pristine auto-rotating state.
  for (const [width, theme] of [[1440, 'light'], [1440, 'dark'], [390, 'light']]) {
    const page = await browser.newPage({ viewport: { width, height: 1200 } });
    watch(page);
    await page.goto(url);
    await page.evaluate(t => document.documentElement.dataset.theme = t, theme);
    const showcase = page.locator('[data-workflow-showcase]');
    await showcase.scrollIntoViewIfNeeded();
    await complete(page, 0);
    await page.evaluate(() => document.activeElement?.blur());
    await showcase.screenshot({ path: `${shots}workflow-showcase-${width}-${theme}.png` });
    await page.close();
  }

  assert.deepEqual(errors, []);
  console.log(`PASS: typing, auto-advance, hover pause, manual takeover, arrow and Home keys, reduced motion, and 320px stacking at 1440/390 in both themes.`);
  console.log(`Screenshots: ${shots}`);
} finally {
  await browser.close();
}
