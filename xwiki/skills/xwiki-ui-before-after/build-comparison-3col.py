#!/usr/bin/env python3
"""3-column (before | design prototype | after) variant of build-comparison.py.

Use this instead of build-comparison.py whenever the user has supplied a design/prototype/
mockup image to compare the implementation against - it slots that image into a middle column
between the real "before" and "after" screenshots. The design column is highlighted in yellow/
amber (not the same color as before/after) so it reads as reference material rather than a third
implementation state.

Usage: build-comparison-3col.py <output.html> <config.json>

config.json shape:
{
  "ticket": "XWIKI-23740",
  "title": "Improve the UI of Comments: Annotation look",
  "repro": "how these screenshots were produced, one paragraph",
  "scenarios": [
    {
      "title": "Annotation bubble opened on highlighted text",
      "before": {"image": "/path/before-bubble.png", "caption": "one-line caption"},
      "design": {"image": "/path/design-crop.png",   "caption": "one-line caption"},
      "after":  {"image": "/path/after-bubble.png",  "caption": "one-line caption"}
    },
    ...
  ]
}

Same layout rules as build-comparison.py (see that file's docstring) apply here: heading is
"TICKET: Title" only, the repro line is plain text right under the heading, no per-scenario
paragraph, and every image keeps a one-line caption underneath it. Each of the three cells also
takes the same optional "context" key - a wider shot rendered above the detail crop in that same
cell, rather than a second scenario re-comparing the element at another zoom level.

Escaping: `repro` is interpolated into the page as RAW HTML, so it may contain markup such as
`<code>` and must have any literal `&`, `<` or `>` escaped by hand. Every other field - `ticket`,
`title`, the scenario titles and the captions - is passed through html.escape(), so markup in
those renders as visible angle brackets. Keep captions plain prose.

Crop screenshots (and the design image) with imagemagick first if they have dead whitespace, e.g.:
  convert design.png -crop 1750x260+950+270 +repage design-crop.png

Export with export-to-png.js using a wider-than-default viewport so the three columns actually
lay out side by side instead of falling into the single-column responsive breakpoint (which
triggers below 1100px page width, and three columns need more room than that):
  node export-to-png.js comparison.html comparison.png 1560
"""
import base64
import html
import json
import pathlib
import sys


def b64(path):
    return base64.b64encode(pathlib.Path(path).read_bytes()).decode()


def shots(entry, label, caption):
    """Render an entry's screenshot(s) for one panel.

    An entry always has an "image" - the detail crop, tight on what changed. It may also have a
    "context" - the same thing shot wider, with enough surrounding UI to place it in the product.
    Both belong to the SAME scenario panel, context first then detail: a detail crop with no
    context leaves the reader unable to tell where they are looking, and splitting the two into
    separate scenarios pretends they are different comparisons when they are one.
    """
    parts = []
    if entry.get("context"):
        parts.append(
            f'<div class="shot-wrap context">'
            f'<img src="data:image/png;base64,{b64(entry["context"])}" '
            f'alt="{label}, in context: {caption}"></div>'
        )
    parts.append(
        f'<div class="shot-wrap">'
        f'<img src="data:image/png;base64,{b64(entry["image"])}" alt="{label}: {caption}"></div>'
    )
    return "".join(parts)


def main():
    if len(sys.argv) != 3:
        print(__doc__)
        sys.exit(1)

    out_path, config_path = sys.argv[1], sys.argv[2]
    config = json.loads(pathlib.Path(config_path).read_text())
    heading = f"{config['ticket']}: {config['title']}"

    sections = []
    for scenario in config["scenarios"]:
        cols = []
        for key, tag_class, tag_label in (
            ("before", "before", "Before (master)"),
            ("design", "design", "Design prototype"),
            ("after", "after", "After (branch)"),
        ):
            cell = scenario[key]
            cap = html.escape(cell["caption"])
            cell_shots = shots(cell, tag_label, cap)
            cols.append(f"""
      <div class="panel">
        <div class="panel-tag {tag_class}"><span class="dot"></span>{tag_label}</div>
        {cell_shots}
        <div class="caption {tag_class}-cell">{cap}</div>
      </div>""")
        scenario_title = html.escape(scenario["title"])
        sections.append(f"""
  <section class="scenario">
    <p class="scenario-title">{scenario_title}</p>
    <div class="columns">{''.join(cols)}
    </div>
  </section>""")

    out_html = f"""<title>{heading}</title>
<style>
  :root {{
    --paper: #f5f6f2; --ink: #1b211d; --ink-soft: #4a534c; --surface: #ffffff; --line: #dde1d9;
    --error: #b8442e; --error-bg: #fbebe7; --error-line: #e3b4a8;
    --fixed: #2e6e4e; --fixed-bg: #e9f2ec; --fixed-line: #b6d4c3;
    --design: #8a6d00; --design-bg: #fdf3d0; --design-line: #eddc9a;
    --mono: ui-monospace, "SF Mono", "Cascadia Code", Menlo, Consolas, monospace;
    --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--paper); color: var(--ink); font-family: var(--sans); padding: 2.5rem 1.5rem 4rem; }}
  .page {{ max-width: 1500px; margin: 0 auto; }}
  h1 {{ font-size: 1.5rem; font-weight: 650; margin: 0 0 0.9rem; text-wrap: balance; letter-spacing: -0.01em; }}
  .repro {{ margin: 0 0 2rem; font-size: 0.85rem; color: var(--ink-soft); }}
  .repro code {{ font-family: var(--mono); }}
  .scenario {{ margin-top: 2rem; }}
  .scenario-title {{ font-size: 0.95rem; font-weight: 650; margin: 0 0 0.7rem; }}
  .columns {{ display: grid; grid-template-columns: 1fr 1fr 1fr; gap: 1.25rem; }}
  @media (max-width: 1100px) {{ .columns {{ grid-template-columns: 1fr; }} }}
  .panel {{ background: var(--surface); border: 1px solid var(--line); border-radius: 10px; overflow: hidden; display: flex; flex-direction: column; }}
  .panel-tag {{ display: flex; align-items: center; gap: 0.5rem; padding: 0.6rem 0.9rem; font-size: 0.76rem; font-weight: 650; letter-spacing: 0.03em; text-transform: uppercase; }}
  .panel-tag.before {{ background: var(--error-bg); color: var(--error); border-bottom: 1px solid var(--error-line); }}
  .panel-tag.design {{ background: var(--design-bg); color: var(--design); border-bottom: 1px solid var(--design-line); }}
  .panel-tag.after {{ background: var(--fixed-bg); color: var(--fixed); border-bottom: 1px solid var(--fixed-line); }}
  .panel-tag .dot {{ width: 0.5rem; height: 0.5rem; border-radius: 50%; background: currentColor; flex: none; }}
  .shot-wrap {{ overflow-x: auto; background: #fafaf8; display: flex; align-items: center; }}
  .shot-wrap.context {{ border-bottom: 1px dashed var(--line); }}
  .shot-wrap img {{ display: block; width: 100%; height: auto; }}
  .caption {{ padding: 0.55rem 0.9rem; font-size: 0.78rem; color: var(--ink-soft); border-top: 1px solid var(--line); }}
  .caption.before-cell {{ color: #7a2c1c; }}
  .caption.design-cell {{ color: #6b5400; }}
  .caption.after-cell {{ color: #1f4f36; }}
</style>
<div class="page">
  <h1>{heading}</h1>
  <p class="repro">{config['repro']}</p>
  {''.join(sections)}
</div>
"""
    pathlib.Path(out_path).write_text(out_html)
    print(f"wrote {out_path} ({len(out_html)} bytes)")


if __name__ == '__main__':
    main()
