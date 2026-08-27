---
name: xwiki-ui-before-after
description: Generate a real (not mocked) before/after screenshot comparison of a UI change in an XWiki repo, by building the pre-fix and post-fix code and running both against a local XWiki instance, then exporting one side-by-side PNG. Use when asked to compare, show or screenshot how a UI, widget, panel or error message looks before vs. after a fix - for a pull request, a JIRA issue or release notes. For deploying an extension to a running instance without a comparison use xwiki-deploy-extension; for the Maven commands use xwiki-build; for hand-editing the wiki pages of a XAR module use xwiki-xar-pages.
---

# XWiki UI before/after comparison

Produces a real before/after screenshot pair by actually running both versions of the code
locally - not a hand-drawn mockup. It condenses a process that is otherwise many rounds of trial
and error (wrong CSRF param names, drag-and-drop flakiness in the class editor, swapping the
wrong runtime jar) into a few deterministic script runs.

## Prerequisites

- **A prebuilt XWiki jetty+hsqldb distribution** of the same version as the branch under
  comparison. Building one from source takes 30-60+ minutes, so reuse or copy an existing one
  where possible - see step 0.
- **Playwright with Chromium.** If `npx playwright install chromium` has never run in this
  environment, do it once in a scratchpad directory (`npm init -y && npm install
  playwright@latest && npx playwright install chromium`) - check `~/.cache/ms-playwright` first,
  it is often already there.
- **ImageMagick** (`convert`) for the final trim in step 5, and `python3` for the comparison
  builders.

## Never write to git in the repo under comparison

This skill only ever *reads* git state (a ref, the working tree). It must never run
`git commit`, `git commit --amend`, `git add`, `git push`, `git checkout <branch>`, or any other
history- or branch-mutating command against the repo the user is working in. `setup-instance.sh`
and `setup-xar-instance.sh` already handle both cases you need without ever committing anything:
pass `HEAD` to build the working tree exactly as it sits (uncommitted changes and all), or pass
a commit-ish to build it via their own throwaway worktree (`.git/xwiki-ui-before-after-worktree`,
auto-cleaned). If the fix being compared is not committed yet, that is **not** a reason to commit
it first - just use `HEAD` for the "after" build. This is a real failure mode, not a hypothetical
one: an agent following this procedure amended the user's own commit mid-run trying to "make the
before/after refs work", rewriting history nobody asked it to touch. If you ever find yourself
reaching for `git commit`/`git add`/`--amend` while following these steps, stop - it means you
have misunderstood the ref you were given, not that committing is the fix.

## When NOT to reach for full UI automation

If you just need to render one PropertyClass's `displayEdit()`/`displayView()` output (a single
field, a validation message, an error banner) - which covers most before/after requests - you do
**not** need to drive the full feature's wizard/UI, e.g. AppWithinMinutes' drag-and-drop class
editor. Creating the class and object directly via action URLs (`setup-class-object.js`) is
faster and far more reliable. Only automate the full feature UI if the *workflow itself*, not
just the resulting field rendering, is what is being compared.

For a UI change that is not a PropertyClass field at all (a widget, a panel, a finder/tree
plugin), do not invent a fixture from scratch - `grep` the `.vm` templates for the CSS class or
plugin name the change touches (e.g. `grep -rl "'finder': true" --include=*.vm`) to find where it
is already wired into a real, easily-reachable page. For a jsTree "finder" plugin specifically,
the location picker (`locationPicker_macros.vm`, reached via "Edit location" on the create-page
wizard) is one such trigger.

## Check the module's packaging before picking a deploy script

`setup-instance.sh` (step 1 below) only works for **jar**-packaged modules - it builds and copies
a jar into `WEB-INF/lib`. Check first:
```bash
grep -m1 '<packaging>' path/to/module/pom.xml
```
- `<packaging>jar</packaging>`, or no `<packaging>` tag at all since jar is Maven's default →
  use `setup-instance.sh` as documented in step 1.
- `<packaging>xar</packaging>` (wiki pages, e.g. `xwiki-platform-annotation-ui`) → there is no
  jar to copy. Use `setup-xar-instance.sh` instead (same `HEAD`-or-commit-ref interface, same
  `--verify` flag), which builds the XAR and deploys it via the wiki's own Import feature - see
  its header comment for the full usage and for *why not the Extension Manager*: version-mismatch
  dependency checks make that route unreliable on a branch that has drifted from the cached test
  instance's version.
  ```bash
  "$XWIKI_UI_SKILL"/setup-xar-instance.sh \
    --verify 'AnnotationCode.Style:your-distinctive-css-class' \
    xwiki-platform-core/xwiki-platform-annotation/xwiki-platform-annotation-ui \
    HEAD
  ```
  Note this script talks to an **already-running** instance over HTTP (`--base-url`, default
  `http://localhost:8080`) rather than starting and stopping it - start the instance yourself
  first (`cd <instance-dir> && ./start_xwiki.sh &`) the way step 1's jar-swap flow does
  internally.
- A plain **static** CSS/JS resource served straight from `webapps/xwiki/resources/...` (e.g.
  flamingo's `comments.css`/`comments.js`, packaged in a `war` module) is neither a jar nor a
  xar, just files on disk. Use
  `sync-static-resource.sh <instance-dir> <source-file> <relative-path-under-resources>`, which
  also refreshes any pre-built `.min.css`/`.min.js` sibling in lockstep. Copying only the raw
  file is a common silent no-op; see `references/gotchas.md`.
- `<packaging>pom</packaging>` usually means a **resources-only** module whose files are copied
  into the webapp as-is - most notably `xwiki-platform-flamingo-skin-resources`, whose `.vm`
  templates and `.less` files land in `webapps/xwiki/skins/flamingo/`, *not* under `resources/`.
  Same script, with the root spelled out:
  ```bash
  "$XWIKI_UI_SKILL"/sync-static-resource.sh --target-root skins \
    "$INSTANCE_DIR" path/to/src/main/resources/flamingo/previewactions.vm \
    flamingo/previewactions.vm
  ```
  When in doubt about the root, locate the file in the instance first:
  `find "$INSTANCE_DIR"/webapps/xwiki -name previewactions.vm`.

**These last two paths need neither a Maven build nor a restart** - the copied file is read off
disk on the next page load. A before/after swap of a template or a stylesheet therefore costs
seconds, so do not reach for `setup-instance.sh` and a module build when the change is only in
files like these; check the packaging first, as above.

A single feature change often spans more than one of these - an annotation redesign touching a
xar module *and* a war module's static CSS/JS, for instance. Run the matching script per piece,
all against the same running instance.

## Authenticated write actions: use a real browser session, not curl

For **read-only** calls (checking that a page rendered correctly, exporting a XAR to verify
content), `curl --user Admin:admin` is fine. For anything that **writes** through a form the
browser would normally submit (creating a test annotation or comment, submitting any
CSRF-protected POST), do not reach for `curl` even with a scraped `form_token` and a real
form-login session - some endpoints, e.g. the annotation-rest module's POST, reject it with
"Invalid or missing form token" for reasons not fully root-caused (suspected response caching
serving a stale token to `curl`, since the exact same token string was observed to survive
across a fresh login). Use a real Playwright session instead:
```js
const { login } = require(process.env.XWIKI_UI_SKILL + '/xwiki-login');
await login(page, 'http://localhost:8080');
// ...navigate, select text / fill a form / click the real button as a user would...
```
This reads the CSRF token live off the actually-rendered page, so it is always valid.

## Procedure

### 0. Set up the environment and find a reusable instance

Export the two variables every command below uses, once per session:
```bash
# This skill's own directory. In Claude Code the plugin root is ${CLAUDE_PLUGIN_ROOT}; in Kimi
# Code the equivalent is ${KIMI_SKILL_DIR} (already this directory); in opencode, $XWIKI_LLM_HOME
# points at the checkout, so it is $XWIKI_LLM_HOME/xwiki/skills/xwiki-ui-before-after.
export XWIKI_UI_SKILL="${CLAUDE_PLUGIN_ROOT}/skills/xwiki-ui-before-after"

# Where test distributions are kept - outside any git checkout, so instance logs and swapped
# jars never show up as untracked files. Override by exporting it beforehand.
export XWIKI_TEST_INSTANCES_DIR="${XWIKI_TEST_INSTANCES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/xwiki-test-instances}"
```

Then look for something to reuse before building anything:
```bash
pgrep -af 'STOP.KEY=xwiki'            # already running?
ls "$XWIKI_TEST_INSTANCES_DIR"        # existing per-ticket distributions
```
If a distribution of the **same xwiki version** as the branch already exists under
`$XWIKI_TEST_INSTANCES_DIR/<other-ticket>-test/`, copy it - typically instant on a
copy-on-write filesystem, versus 30-60+ minutes to build one from scratch:
```bash
mkdir -p "$XWIKI_TEST_INSTANCES_DIR/<this-ticket>-test"
cp -r "$XWIKI_TEST_INSTANCES_DIR"/<other-ticket>-test/xwiki-platform-distribution-*-<version> \
      "$XWIKI_TEST_INSTANCES_DIR/<this-ticket>-test/"
```
Confirm the version matches:
`grep -m1 '<version>' xwiki-platform-core/xwiki-platform-oldcore/pom.xml`.

If the app or feature you need (e.g. AppWithinMinutes) is not installed on that instance - a 404
on its main page - install it via the Extension Manager UI: Administration > Extensions > search
with repo=`local` (it is usually already resolved in `data/extension/repository/` from the
flavor's dependencies) > Install > Continue. Do NOT click through an uninstall-looking flow by
accident: if a "Continue" button appears offering to delete wiki pages, stop and re-check state
with a `repo=installed` search before clicking anything further.

### 1. Capture the "after" (current branch) screenshots

Run `setup-instance.sh` **in the foreground**, not backgrounded. Every later step (screenshots,
comparison, restore) depends on it finishing first, so there is nothing to overlap it with -
backgrounding just trades live output for having to poll a task file. It prints its own progress
(`--- building ... ---`, `--- stopping instance ---`) and tees its full output to
`<instance-dir>/setup-instance.log`, so running it directly shows that as it happens.

Pass `--verify jarHint:pathInJar:pattern` (repeatable) so a failed or wrong swap fails loudly
instead of silently leaving a stale jar deployed. This is cheap insurance and worth using every
time, not just when something looks off:
```bash
"$XWIKI_UI_SKILL"/setup-instance.sh \
  --verify 'xwiki-platform-oldcore:...path/to/YourChangedClass.class:someDistinctiveByteString' \
  "$XWIKI_TEST_INSTANCES_DIR"/<ticket>-test/xwiki-platform-distribution-*-<version> \
  xwiki-platform-core/xwiki-platform-oldcore \
  HEAD \
  xwiki-platform-core/xwiki-platform-legacy/xwiki-platform-legacy-oldcore   # see note below
```
`jarHint` just needs to be a substring of the *artifactId* of one of the modules being built and
swapped - the script checks each swapped module's artifactId rather than re-searching
`WEB-INF/lib`, so it cannot accidentally match an unrelated jar with a similar name (e.g.
`tree-webjar` also matching `xwiki-platform-index-tree-webjar`). `pathInJar` can use a `*` glob
for version-numbered path segments (`.../18.6.0-SNAPSHOT/finder.js` → `.../*/finder.js`). Run
`setup-instance.sh` with no args to see the full flag docs in the script header.

**`--verify` has no equivalent on the file-copy paths.** `sync-static-resource.sh` only copies,
so nothing there proves the swap changed what the page actually renders. Assert it from the
capture script instead: have it `console.log` the exact property under comparison, just before
taking the screenshot, in both states.
```js
const info = await page.evaluate(() => {
  const el = document.querySelector('#backtoedit .btn-group :last-child');
  return { cls: el.className, radius: getComputedStyle(el).borderTopRightRadius };
});
console.log(state, JSON.stringify(info));
// before {"cls":"btn btn-default","radius":"0px"}
// after  {"cls":"btn btn-default btn-group-last","radius":"7px"}
```
Two log lines like that are proof the two states really differ, and they cost no vision tokens.
Do this on every path, jar included - a screenshot pair that *looks* different is weaker evidence
than the measured property, and one that looks identical is otherwise indistinguishable from a
swap that silently did nothing.

Progress log: every run tees its output to `<instance-dir>/setup-instance.log`, truncated each
run. If you do need to background the script - because you have genuinely independent work to do
at the same time, like preparing the "before" worktree build - follow that fixed log path with
`tail -f` (via the Monitor tool) rather than piping the script's own stdout through anything.
Piping through a non-`-f` `tail -80` or similar summarizer buffers *all* output until the whole
script exits, defeating the point of watching it live.

**Gotcha (oldcore specifically):** `xwiki-platform-oldcore` classes are woven via AspectJ into
`xwiki-platform-legacy-oldcore-<version>.jar` for backward compatibility - THAT jar, not
oldcore's own undeployed jar, is what is actually in `webapps/xwiki/WEB-INF/lib/`. Always pass
the legacy-oldcore module as an extra module when the fix touches oldcore. For other modules, if
the screenshot does not reflect the change, find the right jar with:
```bash
unzip -l webapps/xwiki/WEB-INF/lib/*.jar 2>/dev/null | grep -B20 YourChangedClass.class | grep Archive
```

The scripts in this skill directory have no `node_modules` of their own, so point Node at the
scratchpad Playwright install rather than copying the scripts around:
```bash
export NODE_PATH=/path/to/scratchpad/tmp/pw/node_modules
```
This applies to every `node ...` invocation below and in steps 4 and 5 - set it once per session.

Then create the test fixture and screenshot it:
```bash
node "$XWIKI_UI_SKILL"/setup-class-object.js \
  TicketNameAfter number1 com.xpn.xwiki.objects.classes.NumberClass
node "$XWIKI_UI_SKILL"/expand-and-shoot.js \
  TicketNameAfter /path/to/scratchpad/after-1.png
```
Copy `expand-and-shoot.js` into your scratchpad and extend the "customize below" section for the
actual scenario: type a value, click Save & View at `[name=xaction_save]` if it is an AWM-style
form or the standard `input[name="action_save"]` otherwise, wait, screenshot again.

**Cropping when before/after markup differs:** if the fix changes the DOM structure - adds a
wrapper `<div>` around an element that used to be bare, say - do not hard-code one selector for
the screenshot crop. It will exist in one state and not the other, and screenshotting a shared
parent (the whole tree, not just one row) easily bleeds in unrelated sibling content whose size
differs between states. Use the `screenshotElement` helper instead of hand-rolling this:
```js
const { screenshotElement } = require(process.env.XWIKI_UI_SKILL + '/element-screenshot');
await screenshotElement(page, ['.new-wrapper', '.old-bare-element'], outPath);
```
It tries each selector in order and clips to whichever one is present via its own
`getBoundingClientRect()` plus a small pad (default 4px, overridable per side with
`{topPad, rightPad, bottomPad, leftPad}`). A sliver of an adjacent element in the output is crop
overshoot, not a bug in the fix - tighten the relevant side's pad a few px at a time.

**Always capture the surrounding UI, not just the bare element.** A crop tight enough to show
only the exact pixels that changed - `screenshotElement`'s default 4px pad - proves *what*
changed but not *where in the product* it is, and a reader unfamiliar with the selector or
feature cannot place an isolated element on their own. So take a second, wider shot of the same
state per side, with enough recognizable chrome to answer "where am I looking?": a toolbar, a
panel header, page navigation, the neighbouring buttons. Seeing the CKEditor toolbar above a hint
line, or a settings panel's header above a toggle, answers that for free.

**Both shots belong to the same scenario.** Pass the wider one as the optional `context` key
alongside `image` in step 4's config, and the builder stacks it above the detail crop inside the
same before/after panel:
```json
"before": {
  "context": "before-bar.png",
  "image":   "before-group-crop.png",
  "caption": "The Save button's right corners are square, unlike every other button group."
}
```
A scenario is a state or interaction worth comparing - never a zoom level. Splitting the context
shot into its own scenario row is wrong twice over: it reads as two separate findings, and it
leaves the wide row showing a change too small to see while the tight row shows a change nobody
can locate. If one crop genuinely has to carry both jobs, widen the detail crop until the nearest
recognizable landmark is inside it rather than dropping either duty.

This matters even more for anything meant for an audience beyond the PR reviewer - see
`references/release-notes-comparison.md` for the extra step of stripping dev-only identifiers
that a wider crop is more likely to sweep in.

**Logging in for authenticated fixtures:** `expand-and-shoot.js` and `setup-class-object.js`
cover the PropertyClass case. For anything else that needs a logged-in session (creating a
comment or annotation, submitting any form), use the `xwiki-login` helper rather than re-typing
the username/password fill-and-submit boilerplate:
```js
const { login } = require(process.env.XWIKI_UI_SKILL + '/xwiki-login');
await login(page, 'http://localhost:8080'); // defaults to Admin/admin
```
See "Authenticated write actions" above for why this matters more than it looks.

Keep these captures cheap in vision tokens - crop before you Read, and do not re-Read an
unchanged file. `references/gotchas.md` has the full cost-discipline checklist.

### 2. Capture the "before" (pre-fix) screenshots

Same as step 1, but pass the commit before the fix instead of `HEAD`:
```bash
"$XWIKI_UI_SKILL"/setup-instance.sh \
  "$XWIKI_TEST_INSTANCES_DIR"/<ticket>-test/xwiki-platform-distribution-*-<version> \
  xwiki-platform-core/xwiki-platform-oldcore \
  <fix-commit>~1 \
  xwiki-platform-core/xwiki-platform-legacy/xwiki-platform-legacy-oldcore
```
This builds via a throwaway git worktree, so the actual working tree is never touched, then
cleans the worktree up automatically. Use a **fresh space name** for the before fixture,
different from the "after" one, to avoid stale-page confusion.

**If the fix is not committed yet:** `<fix-commit>~1` needs a real commit to exist for the
"before" build. Never solve this by committing the fix yourself so a ref exists - that mutates
the user's branch without being asked. Instead use `HEAD` (the actual current commit) as the
"before" ref and build "after" straight from the dirty working tree, also `HEAD`, since these
scripts read the working tree as-is when given `HEAD` rather than diffing against it. Or simply
ask the user whether they would rather commit it themselves first.

### 3. Restore the instance to the current branch's state

Re-run step 1's `setup-instance.sh` call with `HEAD`, so the instance left running reflects the
real current code rather than the pre-fix build.

### 4. Build the comparison HTML

Crop dead whitespace if needed, then write a small JSON config and run the builder:
```bash
python3 "$XWIKI_UI_SKILL"/build-comparison.py \
  /path/to/scratchpad/comparison.html /path/to/scratchpad/config.json
```
See the script's docstring at the top of the file for the config shape: `ticket`, `title`,
`repro`, and a `scenarios` array where each entry has a `title` and `before`/`after` objects
(`image` path, an optional wider `context` path, plus a one-line `caption`).

**If the user mentions a design, prototype or mockup** - a Figma or JIRA-attached image to
compare the implementation against - do not wedge it into the 2-column before/after. Use
`build-comparison-3col.py`, which adds a middle "Design prototype" column:
```bash
python3 "$XWIKI_UI_SKILL"/build-comparison-3col.py \
  /path/to/scratchpad/comparison.html /path/to/scratchpad/config.json
```
Its config shape matches the 2-column builder's, except each scenario also has a `design` object
(`image` plus `caption`). Crop the design image down to just the relevant element first
(ImageMagick `-crop`), the same way you would a full-page screenshot - a design mockup usually
includes surrounding chrome (nav, sidebar, unrelated sections) that is not the point of the
comparison.

**Always highlight the design/prototype column in yellow/amber**, never the same color as before
(red) or after (green): it is reference material, not a third implementation state, and a
distinct hue keeps that legible at a glance. `build-comparison-3col.py` already defaults its
`--design`/`--design-bg`/`--design-line` CSS variables to an amber palette - keep that
convention across tickets.

Three columns need more horizontal room than the 2-column layout to avoid the responsive
single-column breakpoint, so pass a wider viewport to `export-to-png.js` in step 5.

**Layout constraints - these came from direct user feedback, do not drift from them:**
- The heading is the classic `TICKET-ID: Title` format only, with no separate description
  paragraph under it.
- The repro line (how to reproduce these screenshots) goes front and center, directly under the
  heading, as plain text - no box, background or border around it. It is the first thing a reader
  needs, so it does not get buried in a footer.
- Each scenario section is just a short title followed by the before/after column pair, with no
  explanatory paragraph per scenario. If more context is truly needed it belongs in the repro
  line or the ticket description, not repeated per scenario.
- Each before/after card keeps a short one-line caption under its screenshot, not just alt text.
  This is deliberate, for assistive tech and quick scanning. Do not drop it even when trying to
  keep things terse; terseness applies to the surrounding prose, not the captions.
- One scenario per state or interaction, never one per zoom level. A detail crop and the wider
  shot that places it are one comparison, so they share a panel via `context` - see step 1.

### 5. Export the comparison to a single PNG (this is the deliverable, not an Artifact)

The deliverable is one shareable, lossless image, not a hosted Artifact page. Render the HTML
from step 4 headlessly and screenshot it at 2x scale so both the embedded screenshots and the
surrounding text stay crisp:
```bash
node "$XWIKI_UI_SKILL"/export-to-png.js \
  /path/to/scratchpad/comparison.html /path/to/scratchpad/comparison.png
```
This uses the same cached Playwright/Chromium install as the capture steps. Output is a PNG, not
a JPEG - no lossy compression - and its dimensions are the full rendered page at 2x device scale,
so a ~1100px-wide page comes out ~2200px wide.

For a 3-column (before/design/after) comparison, pass a wider viewport as the third argument. The
default 1100px viewport is exactly the 2-column layout's responsive breakpoint, so a 3-column
page rendered at that width collapses to one column per row instead of laying out side by side:
```bash
node "$XWIKI_UI_SKILL"/export-to-png.js \
  /path/to/scratchpad/comparison.html /path/to/scratchpad/comparison.png 1560
```

Trim the trailing whitespace a `fullPage` capture tends to leave at the bottom - it is
paper-colored background, safe to autodetect with a small fuzz factor:
```bash
convert /path/to/scratchpad/comparison.png -gravity South -background "#f5f6f2" -splice 0x1 \
  -fuzz 2% -trim +repage -bordercolor "#f5f6f2" -border 40 /path/to/scratchpad/comparison-trimmed.png
```
`#f5f6f2` is the template's `--paper` background variable - reuse it here so the trim detects the
right border color and the added-back border matches. Hand the trimmed PNG to the user directly,
via Read to display it or by pointing at the file path. Do not also publish an Artifact unless
they ask for one.

## Further reading

- `references/gotchas.md` - the failure modes that each cost real time to discover once: silent
  `propadd` param names, the object editor's collapsible rows, jar-swap verification, stale
  minified siblings, version drift between a branch and a cached instance, and the checklist for
  keeping screenshot and debug reads cheap in tokens. Read it before debugging a fixture that
  "should work".
- `references/release-notes-comparison.md` - how to produce the separate, simplified comparison
  for end users, which is a different artifact from the dev-facing one built in steps 4 and 5.
