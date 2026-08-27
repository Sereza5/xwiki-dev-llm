// Render a self-contained comparison HTML (built by build-comparison.py) to a single
// lossless PNG, at 2x device scale so embedded screenshots and text stay crisp.
//
// Usage: node export-to-png.js <input.html> <output.png> [viewportWidth]
const { chromium } = require('playwright');
const path = require('path');

const [inputHtml, outputPng, viewportWidthArg] = process.argv.slice(2);
if (!inputHtml || !outputPng) {
  console.error('usage: node export-to-png.js <input.html> <output.png> [viewportWidth]');
  process.exit(1);
}
const viewportWidth = viewportWidthArg ? parseInt(viewportWidthArg, 10) : 1100;

(async () => {
  const browser = await chromium.launch();
  const page = await browser.newPage({
    viewport: { width: viewportWidth, height: 1000 },
    deviceScaleFactor: 2,
  });
  await page.goto('file://' + path.resolve(inputHtml));
  await page.waitForTimeout(500); // let embedded data-URI images paint before capture
  await page.screenshot({ path: outputPng, fullPage: true });
  await browser.close();
  console.log('wrote', outputPng);
})().catch((e) => {
  console.error(e);
  process.exit(1);
});
