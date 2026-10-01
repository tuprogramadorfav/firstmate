// Answer the real bearings board on a live Lavish session in headless Chrome.
// usage: node bearings.cjs <session-url> <spec.json> <shot-prefix>
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

  for (const c of spec.calls || []) {
    const form = frame().locator(`form[data-lavish-question="${c.question}"]`);
    await form.waitFor({ state: 'visible' });
    await form.locator(`input[name=answer][value="${c.answer}"]`).check();
    await form.locator('input[name=note]').fill(c.note || '');
    await form.locator('button[type=submit]').click();
    await page.waitForTimeout(900);
  }
  for (const id of spec.dispatch || []) await frame().locator(`.bb-pick[value="${id}"]`).check();
  if ((spec.dispatch || []).length) {
    await frame().click('#bb-dispatch-btn');
    await page.waitForTimeout(400);
  }
  await page.waitForTimeout(500);
  await page.screenshot({ path: `${shot}-queued.png`, fullPage: false });
  await page.click('#send');
  await page.waitForTimeout(2500);
  await page.screenshot({ path: `${shot}-sent.png`, fullPage: false });
  const until = Date.now() + 60000;
  while (Date.now() < until && !fs.existsSync(spec.waitFor)) await page.waitForTimeout(500);
  console.log(fs.existsSync(spec.waitFor) ? 'captured' : 'timed out waiting for capture');
  await browser.close();
})();
