# Tools for authoring xwiki.org documentation

Four scripts for the mechanical half of writing or converting a documentation tree: draft the pages
as data, check them offline, publish them, prove what landed. The rules they enforce are the subset
of `okf/conventions/documentation.md` a regex can decide — they replace the tedium, not the review
checklist in `SKILL.md`.

They exist because each of these steps has a failure mode that **passes silently**. Every rule below
was added the first time it produced a defect on a live page.

| Script | Use |
|---|---|
| `xwikidoc.py` | REST client for the farm. Imported by the others; usable on its own. |
| `docpages.py` | `lint` \| `save` \| `pin` \| `verify` over a page set held as a Python module. |
| `docshot.sh` | Capture a screenshot at a `size` width with the mandatory red box. |
| `checkredbox.py` | Prove each screenshot's red box is a closed rectangle. |

Requirements: Python 3 (standard library only), `agent-browser` and macOS `sips` for the screenshot
pair, and `~/.xwiki-credentials` (see `okf/servers/index.md`). Source the credentials **inside** the
command so they are never printed:

```bash
set -a; . ~/.xwiki-credentials; set +a
```

## The page set

Write the pages as a `pages.py` in your working directory — a `<work>/<repo>/<date>-<slug>/`
directory under the work directory the org-wide conventions define (`$XWIKI_LLM_WORK`, else
`~/.xwiki-llm/work`), not inside the repo. Drafting them as data is what makes `lint` possible
before anything is saved, and makes a re-save idempotent afterwards:

```python
EXT = "xwiki:org.xwiki.contrib:application-antispam-ui"
ROOT = "documentation.extensions.admin.antispam"

ALL = [dict(
    space=["documentation", "extensions", "admin", "antispam"], page="WebHome",
    title="AntiSpam", type="explanation", target="administrator", ext=EXT,
    attachments=["home-page.png"],          # files under SHOTS
    content="""The [[Foo application>>doc:extensions:Extension.Foo.WebHome]] …""",
    faq="""== A reader's question? ==\n\nThe answer.""",
    related=f"* [[Some Page>>doc:{ROOT}.some-page.WebHome]]",
), ...]

SHOTS = "shots"                             # optional, default "shots"
PIN = {f"{ROOT}.WebHome": ["configure-keywords", "delete-spam-pages-users"]}   # optional
```

`highlights` defaults to `""` — it stays empty unless a page has enough children to need it.

## The four steps

```bash
python3 docpages.py lint          # offline. Iterate until it prints 0 problems.
python3 docpages.py save          # idempotent: only what differs is written
python3 docpages.py pin           # child order, verified through the tree service
python3 docpages.py verify        # independent read-back audit + both checker surfaces
```

`save` takes page references to limit it to those pages. Add `--pages <module>` before the command to
use a module other than `pages.py`.

Screenshots, per capture:

```bash
agent-browser --session doc set viewport 1440 900 1                # dPR 1, once per shape
./docshot.sh panel-entry 650 0,0,650,300 '.panel li.selected'      # x,y,w,h — 650 = size "large"
./docshot.sh account-list 960 239,60,960,360 'union:#list li a'    # one box around them all
python3 checkredbox.py                                             # all of them, in one pass
```

Give the region as `x,y,w,h` rather than `VIEWPORT`: a step's screenshot shows the element plus the
landmark that locates it, so a region is the normal case and a whole window the exception (a
procedure's entry step). A region already at the target width is saved unresampled.

**Never scroll to reach content below the fold — enlarge the viewport.** `agent-browser screenshot
<element>` ignores the scroll offset: it captures the *document* region matching the element's
**viewport** rect, so after scrolling it saves a plausible PNG of the wrong part of the page. Keep
`scrollY = 0` and make the window tall enough instead (`agent-browser --session doc set viewport 1440
3600 1`).

## What each step actually protects against

**`lint`** — the traps that produce a *plausible-looking* page rather than an error: a scheme-like
token followed by a colon (`image:` emits an empty image reference), an unmatched `--` striking
through the rest of the block, a URL inside `##…##`, an absolute URL to a farm subwiki (renders
external and is **never indexed as a backlink**), a `caption` carrying the capture version, a title
repeating the page type or the audience, an image without `size`/`alt`, an attachment declared but not
shown (or shown but not declared), a How-to with no result-step screenshot or with a screenshot on
only a minority of its steps, a topic page that is not an Explanation linking to its Extensions-wiki
page. Its last two checks are **cross-page** — several pages opening with the same step, one attachment
name declared by several pages — and are why the whole set is linted rather than one page.

**`save`** — writes attachments *before* content, so no revision is ever saved with a dangling image;
then reads every field back, because **a `202` does not mean the write landed** (a property write
issued right after a content write can be dropped) and a malformed property write also returns `202`
while blanking the property. It creates the two `DocApp` objects a documentation page needs — a page
missing `DocumentationExtensionClass` is incomplete though nothing visibly breaks — and never touches
`DocumentationClass`'s own unused `content` property, which would clobber the page.

**`pin`** — writes `XWiki.PinnedChildPagesClass` on the parent space's `WebPreferences` page, creating
it hidden if the space has none, then asks the **tree service** what it will display. Reading the
stored string back only proves it was stored.

**`verify`** — checks title, content, syntax, hidden flag, object counts and every structure field
against the source, then **both** checker surfaces: the `DocumentationViolationClass` objects, *and*
the rendered HTML — some findings, the mandatory-`size` rule among them, create no object and appear
only as an inline error box, so an object-only check calls a broken page clean.

**`docshot.sh` / `checkredbox.py`** — the red box is drawn as an overlay appended to `<body>`, never
as a CSS `outline`, which any ancestor with `overflow: hidden` clips into a three-sided box; the
script refuses to shoot when a box falls outside what is being captured, and `checkredbox.py` then
proves the saved PNG holds a closed rectangle. The region is captured by screenshotting a transparent
clip element because the two obvious routes silently do something else: the CLI has no `--clip`, and
macOS `sips -c` crops from the **centre** (`--cropOffset` is a no-op), which yields a plausible PNG of
the wrong part of the page. A region narrower than the target width is refused rather than upscaled
into blur.

## Notes

- The **form token is session-bound**. `xwikidoc.py` keeps a cookie jar for that reason; without one,
  object writes fail intermittently with `403 Invalid or missing form token.`
- xwiki.org REST is behind Cloudflare: it answers `403` both to a request with **no** `User-Agent`
  and to one carrying a **browser-like** UA. The tools send `curl/8.0`; see `okf/servers/index.md`.
- Only `/rest` honours Basic auth. A `/bin/` URL is fetched as **guest**, which is the right lens for
  the rendered-page checks in `verify` but means a Live Data table rendered there shows no rows.
- A conversion also has to finish the **original** page — strip its prose, wire its "Documentation"
  button, delete its attachments, triage its backlinks. That is `okf/conventions/documentation-migration.md`
  and the `xwiki-doc-convert` skill; these tools do not do it for you.
