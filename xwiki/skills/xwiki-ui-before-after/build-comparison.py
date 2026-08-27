#!/usr/bin/env python3
"""Assemble a self-contained before/after HTML comparison from screenshot PNGs.

Usage: build-comparison.py <output.html> <config.json>

config.json shape:
{
  "ticket": "XWIKI-23771",
  "title": "AWM: Numeric field accepts invalid characters, causing server error on edit",
  "repro": "Reproduced by swapping the woven <code>xwiki-platform-legacy-oldcore</code> jar
            between the pre-fix commit and the current branch tip on a local XWiki
            18.6.0-SNAPSHOT instance.",
  "scenarios": [
    {
      "title": "Typing \"aaa\" into the Number field",
      "before": {"image": "/path/before-1.png", "caption": "Plain text input accepts \"aaa\" without complaint."},
      "after":  {"image": "/path/after-1.png",  "caption": "Number input rejects the keystrokes; the field stays empty."}
      // each side also takes an optional "context": a wider shot of the same thing, rendered
      // above the detail crop in the same panel - see the layout rules below

    },
    ...
  ]
}

Layout rules (don't drift from these without being asked to):
- Heading is the classic "ID: TITLE" format only - no separate description paragraph.
- The repro line goes front and center, directly under the heading, as plain text (no
  box/background/border) - readers need to know how to reproduce before anything else.
- Each scenario is just a short title, then a before/after column pair - no explanatory
  paragraph per scenario.
- Each before/after card keeps a one-line caption under its screenshot (not just alt text) -
  this is for assistive tech and quick scanning, don't drop it for terseness.
- A scenario is a state or interaction worth comparing, never a zoom level. When a tight detail
  crop needs a wider shot to place it in the product, both go in the SAME scenario via the
  optional "context" key - never as a second scenario comparing the same element again, which
  reads as two findings and leaves each half without what the other one carries.

Escaping: `repro` is interpolated into the page as RAW HTML, so it may contain markup such as
`<code>` and must have any literal `&`, `<` or `>` escaped by hand. Every other field - `ticket`,
`title`, the scenario titles and the captions - is passed through html.escape(), so markup in
those renders as visible angle brackets. Keep captions plain prose.

Crop screenshots with imagemagick first if they have dead whitespace, e.g.:
  convert shot.png -crop 1000x420+0+0 +repage shot-crop.png
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
        before_caption = html.escape(scenario["before"]["caption"])
        after_caption = html.escape(scenario["after"]["caption"])
        before_shots = shots(scenario["before"], "Before", before_caption)
        after_shots = shots(scenario["after"], "After", after_caption)
        scenario_title = html.escape(scenario["title"])
        sections.append(f"""
  <section class="scenario">
    <p class="scenario-title">{scenario_title}</p>
    <div class="columns">
      <div class="panel">
        <div class="panel-tag before"><span class="dot"></span>Before</div>
        {before_shots}
        <div class="caption before-cell">{before_caption}</div>
      </div>
      <div class="panel">
        <div class="panel-tag after"><span class="dot"></span>After</div>
        {after_shots}
        <div class="caption after-cell">{after_caption}</div>
      </div>
    </div>
  </section>""")

    out_html = f"""<title>{heading}</title>
<style>
  :root {{
    --paper: #f5f6f2; --ink: #1b211d; --ink-soft: #4a534c; --surface: #ffffff; --line: #dde1d9;
    --error: #b8442e; --error-bg: #fbebe7; --error-line: #e3b4a8;
    --fixed: #2e6e4e; --fixed-bg: #e9f2ec; --fixed-line: #b6d4c3;
    --mono: ui-monospace, "SF Mono", "Cascadia Code", Menlo, Consolas, monospace;
    --sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }}
  * {{ box-sizing: border-box; }}
  body {{ margin: 0; background: var(--paper); color: var(--ink); font-family: var(--sans); padding: 2.5rem 1.5rem 4rem; }}
  .page {{ max-width: 1020px; margin: 0 auto; }}
  h1 {{ font-size: 1.5rem; font-weight: 650; margin: 0 0 0.9rem; text-wrap: balance; letter-spacing: -0.01em; }}
  .repro {{ margin: 0 0 2rem; font-size: 0.85rem; color: var(--ink-soft); }}
  .repro code {{ font-family: var(--mono); }}
  .scenario {{ margin-top: 2rem; }}
  .scenario-title {{ font-size: 0.95rem; font-weight: 650; margin: 0 0 0.7rem; }}
  .columns {{ display: grid; grid-template-columns: 1fr 1fr; gap: 1.25rem; }}
  @media (max-width: 760px) {{ .columns {{ grid-template-columns: 1fr; }} }}
  .panel {{ background: var(--surface); border: 1px solid var(--line); border-radius: 10px; overflow: hidden; display: flex; flex-direction: column; }}
  .panel-tag {{ display: flex; align-items: center; gap: 0.5rem; padding: 0.6rem 0.9rem; font-size: 0.76rem; font-weight: 650; letter-spacing: 0.03em; text-transform: uppercase; }}
  .panel-tag.before {{ background: var(--error-bg); color: var(--error); border-bottom: 1px solid var(--error-line); }}
  .panel-tag.after {{ background: var(--fixed-bg); color: var(--fixed); border-bottom: 1px solid var(--fixed-line); }}
  .panel-tag .dot {{ width: 0.5rem; height: 0.5rem; border-radius: 50%; background: currentColor; flex: none; }}
  .shot-wrap {{ overflow-x: auto; background: #fafaf8; }}
  .shot-wrap.context {{ border-bottom: 1px dashed var(--line); }}
  .shot-wrap img {{ display: block; width: 100%; height: auto; }}
  .caption {{ padding: 0.55rem 0.9rem; font-size: 0.78rem; color: var(--ink-soft); border-top: 1px solid var(--line); }}
  .caption.before-cell {{ color: #7a2c1c; }}
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
