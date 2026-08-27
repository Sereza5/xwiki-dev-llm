# A separate, simplified comparison for release notes

Companion to `../SKILL.md`.

The dev-facing comparison from steps 1-5 - ticket-ID heading, technical repro line, CSS-level
captions - is the wrong artifact to hand to end users in release notes. They do not care about
`var(--text-muted)` or a JIRA key; they want "here is what changed for you". Do not try to make
`build-comparison.py`'s config serve both audiences, for instance by making the ticket field
optional. Write a second, much smaller standalone HTML by hand instead of going through that
script.

- **No ticket or issue number anywhere** - not in the heading, not in a caption, not in an `alt`
  attribute. The release note itself is the reference; the ticket only makes sense to a developer
  reading the pull request.
- **Plain-language heading and captions** - "Easier to read hint in the editor", "The hint was
  hard to read" / "The hint is now easier to read". No CSS property names, hex codes or WCAG
  citations.
- **Reuse the same underlying screenshots, but re-crop for this audience.** Per the "default to
  some surrounding UI" note in SKILL.md step 1, include enough chrome (toolbar, nav bar) to place
  the feature, while actively cropping out anything that leaks a dev-only identifier a technical
  crop would not have bothered hiding. A breadcrumb or page title showing a scratch test-page name
  is exactly the kind of thing that sneaks into a wider shot and needs to be cut. Check each
  screenshot for this before using it - do not assume "more context" is free of leaks just because
  it looked fine tightly cropped.
- Otherwise reuse the same mechanics: a small inline `<style>` block, light/dark aware, with the
  same `--paper` background convention; a `before`/`after` two-column layout; then
  `export-to-png.js` and the same trim command as SKILL.md step 5.
