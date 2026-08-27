// Reusable Playwright login helper. Use this instead of HTTP Basic auth whenever a script needs
// to perform an authenticated WRITE action through the browser (submitting a form, clicking a
// button that POSTs) - some endpoints (e.g. the annotation-rest module's POST) reject Basic auth
// with "Invalid or missing form token" even with a scraped token, for reasons not fully root-
// caused (suspected response caching serving a stale token). A real form-based login session
// sidesteps the question entirely, since the token is read live off the actually-rendered page.
//
// Basic auth via curl is still fine for read-only calls and for the wiki Import flow used by
// setup-xar-instance.sh - this helper is specifically for browser-driven write actions.
//
// Usage:
//   const { login } = require(process.env.XWIKI_UI_SKILL + '/xwiki-login');
// where XWIKI_UI_SKILL points at this skill's directory (SKILL.md, step 0, exports it).
//   await login(page, 'http://localhost:8080', 'Admin', 'admin');
async function login(page, baseUrl, user = 'Admin', password = 'admin') {
  await page.goto(`${baseUrl}/xwiki/bin/login/XWiki/XWikiLogin`);
  await page.fill('#j_username', user);
  await page.fill('#j_password', password);
  await page.click('input[type=submit]');
  await page.waitForLoadState('networkidle');
}

module.exports = { login };
