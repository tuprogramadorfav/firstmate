// Play one captain round on a live Lavish board in headless Chrome.
// usage: node round.cjs <session-url> <spec.json> <shot-prefix>
const fs = require('fs');
const { chromium } = require(process.env.W + '/lavish/node_modules/playwright-core');

(async () => {
  const [url, specPath, shot] = process.argv.slice(2);
  const spec = JSON.parse(fs.readFileSync(specPath, 'utf8'));
  const browser = await chromium.launch({
    executablePath: '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    headless: true,
  });
  const page = await browser.newPage({ viewport: { width: 1400, height: 1000 } });
  await page.goto(url, { waitUntil: 'networkidle' });
  await page.waitForTimeout(1500);
  const frame = () => page.frames().find((f) => f.url().includes('/artifact/'));

  for (const a of spec.annotations || []) {
    await frame().click(a.selector);
    const box = frame().locator('textarea[placeholder^="Tell the agent"]');
    await box.waitFor({ state: 'visible' });
    await box.fill(a.comment);
    await frame().click('button.lavish-send');
    await page.waitForTimeout(400);
  }
  for (const c of spec.choices || []) {
    const form = frame().locator(`form[data-lavish-question="${c.question}"]`);
    await form.locator(`input[value="${c.answer}"]`).check();
    await form.locator('textarea[name=note]').fill(c.note || '');
    await form.locator('button[type=submit]').click();
    await page.waitForTimeout(400);
  }
  if (spec.message) await page.fill('#chatInput', spec.message);
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${shot}-queued.png`, fullPage: false });
  await page.click(spec.end ? '#sendAndEnd' : '#send');
  await page.waitForTimeout(2500);
  await page.screenshot({ path: `${shot}-sent.png`, fullPage: false });
  // Keep the review window connected until the listener has captured the round.
  const until = Date.now() + 60000;
  while (Date.now() < until && !fs.existsSync(spec.waitFor)) await page.waitForTimeout(500);
  console.log(fs.existsSync(spec.waitFor) ? 'captured' : 'timed out waiting for capture');
  await browser.close();
})();
