// Open the object editor for a space set up by setup-class-object.js, expand the object row,
// and take a screenshot. Reusable as a template: copy/extend the "interact" section for your
// specific scenario (typing a value, clicking save, etc.) rather than re-deriving selectors.
//
// Usage: node expand-and-shoot.js <space> <output.png>
const { chromium } = require('playwright');

const BASE = process.env.XWIKI_BASE_URL || 'http://localhost:8080/xwiki';
const ADMIN_USER = process.env.XWIKI_ADMIN_USER || 'Admin';
const ADMIN_PASS = process.env.XWIKI_ADMIN_PASS || 'admin';

const [space, outPath] = process.argv.slice(2);
if (!space || !outPath) {
  console.error('usage: node expand-and-shoot.js <space> <output.png>');
  process.exit(1);
}

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({ viewport: { width: 1000, height: 700 } });

  await page.goto(`${BASE}/bin/login/XWiki/XWikiLogin`);
  await page.fill('#j_username', ADMIN_USER);
  await page.fill('#j_password', ADMIN_PASS);
  await Promise.all([page.waitForNavigation(), page.click('input[type="submit"]')]);

  await page.goto(`${BASE}/bin/edit/${space}/WebHome?editor=object`);
  await page.waitForTimeout(1000);
  // Click the object row's own text (e.g. "WebHome 0:"), not a caret-icon by index - there
  // are two nested toggle-collapsable spans (class-group + object), and clicking the wrong
  // one collapses everything instead of expanding the property fields.
  await page.locator('text=WebHome 0').first().click();
  await page.waitForTimeout(2000); // AJAX populates the property fields; this needs real time.

  // --- customize below for your scenario ---
  // Example: type a value into a property named "number1" and screenshot.
  // const input = page.locator('input[id*="number1"]').first();
  // await input.click();
  // await input.fill('');
  // await input.type('aaa');
  // await page.waitForTimeout(200);

  await page.screenshot({ path: outPath });
  console.log('wrote', outPath);

  await browser.close();
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
