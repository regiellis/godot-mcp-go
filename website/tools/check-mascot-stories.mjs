// Run from website/: node tools/check-mascot-stories.mjs [homepage URL]
import assert from 'node:assert/strict';
import { chromium } from 'playwright-core';
const browser = await chromium.launch({ channel: 'msedge', headless: true });
const url = process.argv[2] ?? 'http://127.0.0.1:4321/godot-mcp-go/';
const topics = ['anime', 'nature', 'culture'];
try {
  const page = await browser.newPage();
  const errors = [];
  page.on('pageerror', error => errors.push(error.message));
  await page.goto(url);
  const bubble = page.locator('#mascot-bubble');
  for (const width of [1440, 768, 390, 320]) {
    await page.setViewportSize({ width, height: 900 });
    for (const theme of ['light', 'dark']) {
      await page.evaluate(theme => document.documentElement.dataset.theme = theme, theme);
      for (const topic of topics) {
        const trigger = page.locator(`[data-mascot-topic="${topic}"]`);
        await trigger.scrollIntoViewIfNeeded();
        await trigger.click();
        assert.equal(await bubble.isVisible(), true);
        const rect = await bubble.boundingBox();
        assert(rect.x >= 0 && rect.x + rect.width <= width && rect.y >= 60 && rect.y + rect.height <= 900);
        const before = await page.locator('#mascot-story-title').textContent();
        await page.locator('.mascot-next').click();
        assert.notEqual(await page.locator('#mascot-story-title').textContent(), before);
        assert.match(await page.locator('.mascot-story-source').getAttribute('href'), /^https:\/\//);
        await page.keyboard.press('Escape');
        assert.equal(await bubble.isVisible(), false);
        assert.equal(await trigger.getAttribute('aria-expanded'), 'false');
        assert(await trigger.evaluate(element => document.activeElement === element));
      }
      assert(await page.evaluate(() => document.documentElement.scrollWidth <= innerWidth));
    }
  }
  await page.setViewportSize({ width: 1440, height: 900 });
  for (const topic of topics) {
    const trigger = page.locator(`[data-mascot-topic="${topic}"]`);
    await trigger.scrollIntoViewIfNeeded();
    await trigger.focus();
    await page.keyboard.press('Enter');
    const titles = new Set();
    for (let i = 0; i < 10; i++) {
      const title = await page.locator('#mascot-story-title').textContent();
      assert(!titles.has(title), 'No repeat before the full deck is read');
      titles.add(title);
      await page.locator('.mascot-next').click();
    }
    assert(titles.has(await page.locator('#mascot-story-title').textContent()));
    await page.locator('.mascot-close').click();
    await trigger.click();
    const before = await page.locator('#mascot-story-title').textContent();
    await trigger.click();
    assert.notEqual(await page.locator('#mascot-story-title').textContent(), before);
    await page.mouse.click(10, 70);
    assert.equal(await bubble.isVisible(), false);
  }
  for (const topic of topics) {
    const trigger = page.locator(`[data-mascot-topic="${topic}"]`);
    await trigger.scrollIntoViewIfNeeded();
    await page.emulateMedia({ reducedMotion: 'no-preference' });
    await trigger.hover();
    await page.waitForTimeout(220);
    // The figure holds still; the speech indicator's text is the hover cue.
    assert.equal(await trigger.locator('img').evaluate(e => getComputedStyle(e).transform), 'none');
    assert.notEqual(await trigger.locator('.mascot-invitation-copy').evaluate(e => getComputedStyle(e).display), 'none');
    await page.mouse.move(0, 0);
    await page.waitForTimeout(50);
    assert.equal(await trigger.locator('.mascot-invitation-copy').evaluate(e => getComputedStyle(e).display), 'none');
  }
  const touch = await browser.newContext({ viewport: { width: 320, height: 568 }, isMobile: true, hasTouch: true });
  const phone = await touch.newPage();
  await phone.addInitScript(() => { Object.defineProperty(window, 'sessionStorage', { get() { throw new Error('Storage disabled'); } }); });
  await phone.goto(url);
  const trigger = phone.locator('[data-mascot-topic="nature"]');
  await trigger.scrollIntoViewIfNeeded();
  await trigger.tap();
  await phone.locator('.mascot-next').tap();
  await phone.locator('.mascot-close').tap();
  assert.equal(await phone.locator('#mascot-bubble').isVisible(), false);
  await touch.close();
  assert.deepEqual(errors, []);
  console.log('PASS: 30 stories, cycling, repeat clicks, keyboard, dismissal, responsive themes, pose feedback, reduced motion, touch, and disabled storage.');
} finally {
  await browser.close();
}
