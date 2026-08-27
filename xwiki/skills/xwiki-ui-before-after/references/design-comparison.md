# Comparing against a design prototype

Companion to `../SKILL.md`. Use this when the user supplies a design, prototype or mockup image to
compare the implementation against - a Figma export, a JIRA attachment. Do not wedge it into the
2-column before/after.

`build-comparison-3col.py` adds a middle "Design prototype" column:
```bash
python3 "$XWIKI_UI_SKILL"/build-comparison-3col.py \
  /path/to/scratchpad/comparison.html /path/to/scratchpad/config.json
```

Its config shape matches the 2-column builder's, except each scenario also has a `design` object
(`image` plus `caption`, and optionally `context`). Crop the design image down to the relevant
element first (ImageMagick `-crop`), the same way you would a full-page screenshot - a mockup
usually includes surrounding chrome (nav, sidebar, unrelated sections) that is not the point of the
comparison.

**Always highlight the design column in yellow/amber**, never the same color as before (red) or
after (green): it is reference material, not a third implementation state, and a distinct hue keeps
that legible at a glance. `build-comparison-3col.py` already defaults its
`--design`/`--design-bg`/`--design-line` CSS variables to an amber palette - keep that convention
across tickets.

**Export wider.** Three columns need more horizontal room than the 2-column layout, and the default
1100px viewport is exactly the 2-column responsive breakpoint, so a 3-column page rendered at that
width collapses to one column per row:
```bash
node "$XWIKI_UI_SKILL"/export-to-png.js comparison.html comparison.png 1560
```
Everything else - the layout rules, the `context` key, the trim - is unchanged from SKILL.md
steps 5 and 6.
