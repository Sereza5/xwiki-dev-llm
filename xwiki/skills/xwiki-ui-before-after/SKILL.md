---
name: xwiki-ui-before-after
description: Generate a real (not mocked) before/after screenshot comparison of a UI change in an XWiki repo, by building the pre-fix and post-fix code and running both against a local XWiki instance, then exporting one side-by-side PNG. Use when asked to compare, show or screenshot how a UI, widget, panel, template, stylesheet or error message looks before vs. after a fix - for a pull request, a JIRA issue or release notes. For deploying an extension to a running instance without a comparison use xwiki-deploy-extension; for the Maven commands use xwiki-build; for hand-editing the wiki pages of a XAR module use xwiki-xar-pages.
---

# XWiki UI before/after comparison

Produces a real before/after screenshot pair by actually running both versions of the code
locally - not a hand-drawn mockup. It condenses a process that is otherwise many rounds of trial
and error (wrong CSRF param names, drag-and-drop flakiness in the class editor, swapping the
wrong runtime jar) into a few deterministic script runs.

The shape of every run is the same: pick a fixture (step 1), then deploy-and-capture one state
(steps 2 and 3), do that twice - once per state - and restore (step 4), then assemble (steps 5
and 6). Read the worked example at the end first if you want the whole flow in one piece.

## Prerequisites

- **A prebuilt XWiki jetty+hsqldb distribution.** Building one from source takes 30-60+ minutes,
  so reuse or copy an existing one - see step 0.
- **Playwright with Chromium.** If `npx playwright install chromium` has never run in this
  environment, do it once in a scratchpad directory (`npm init -y && npm install
  playwright@latest && npx playwright install chromium`) - check `~/.cache/ms-playwright` first,
  it is often already there.
- **ImageMagick** (`convert`) for the final trim, and `python3` for the comparison builders.

Check all of it before starting, rather than discovering a gap three steps in:
```bash
NODE_PATH=/path/to/scratchpad/tmp/pw/node_modules node -e "require('playwright'); console.log('playwright ok')"
command -v convert python3
ls "$XWIKI_TEST_INSTANCES_DIR"                # see step 0 for this variable
```

## Never write to git in the repo under comparison

This skill only ever *reads* git state (a ref, the working tree). It must never run
`git commit`, `git commit --amend`, `git add`, `git push`, `git checkout <branch>`, or any other
history- or branch-mutating command against the repo the user is working in. `setup-instance.sh`
and `setup-xar-instance.sh` already handle both cases you need without ever committing anything:
pass `HEAD` to build the working tree exactly as it sits (uncommitted changes and all), or pass
a commit-ish to build it via their own throwaway worktree (`.git/xwiki-ui-before-after-worktree`,
auto-cleaned). If the fix being compared is not committed yet, that is **not** a reason to commit
it first - just use `HEAD` for the "after" build. An agent following an earlier draft of this
procedure amended the user's own commit trying to "make the before/after refs work". If you find
yourself reaching for `git commit`/`git add`/`--amend`, stop - you have misunderstood the ref you
were given, not found a case where committing is the fix.

## Check the module's packaging before picking a deploy script

`setup-instance.sh` only works for **jar**-packaged modules - it builds and copies a jar into
`WEB-INF/lib`. Check first:
```bash
grep -m1 '<packaging>' path/to/module/pom.xml
```
- `<packaging>jar</packaging>`, `<packaging>webjar</packaging>`, or no `<packaging>` tag at all
  since jar is Maven's default → use `setup-instance.sh`, as in step 2. A webjar packages its
  `src/main/webjar/*.js|css` into an ordinary jar under `WEB-INF/lib`, so the same swap applies -
  and note that its assets are **minified at build time**, so despite being "just JS and CSS" this
  path does need Maven and cannot be short-cut with `sync-static-resource.sh`. It automates what `xwiki-deploy-extension` describes for
  a core extension - replace the jar in `WEB-INF/lib`, restart - and adds the parts that are
  specific to a comparison: building the module at an arbitrary git ref via a throwaway worktree,
  and `--verify`.
- `<packaging>xar</packaging>` (wiki pages, e.g. `xwiki-platform-annotation-ui`) → there is no
  jar to copy. Build the module at the ref you want, then **follow the `xwiki-deploy-extension`
  skill** to install the resulting XAR into the already-running instance over the REST job API,
  including its uninstall-then-reinstall step, which you will hit on the second state because the
  first one is already installed. Do not re-derive that flow here.

  Fallback: that route is the Extension Manager, which refuses the install outright once the
  branch's `${project.version}` has drifted from the cached instance's (`InstallException:
  Dependency [...] is not compatible with core extension feature [...]`; see
  `references/gotchas.md`). When that happens, use `setup-xar-instance.sh`, which builds at a git
  ref and pushes the XAR through the classic Administration > Import page, with no dependency
  graph involved:
  ```bash
  "$XWIKI_UI_SKILL"/setup-xar-instance.sh \
    --verify 'AnnotationCode.Style:your-distinctive-css-class' \
    xwiki-platform-core/xwiki-platform-annotation/xwiki-platform-annotation-ui \
    HEAD
  ```
  Both routes need the instance **already running** - start it yourself first
  (`cd <instance-dir> && ./start_xwiki.sh &`) the way the jar-swap flow does internally.
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

**How strictly the instance version has to match the branch** depends on which path you are on.
For jar and xar deploys it matters: a jar built against a different `${project.version}` can
break at runtime, and the Extension Manager refuses outright, as above. For the two file-copy
paths it does not - a `.vm` template or a stylesheet is served as-is, so an 18.7.0-SNAPSHOT
instance happily renders a template taken from an 18.8.0-SNAPSHOT branch. Do not spend 30-60
minutes copying a version-matched distribution for a comparison that only copies files.

A single feature change often spans more than one of these - an annotation redesign touching a
xar module *and* a war module's static CSS/JS, for instance. Run the matching script per piece,
all against the same running instance.

## Authenticated write actions: use a real browser session, not curl

For **read-only** calls (checking that a page rendered correctly, exporting a XAR to verify
content), `curl --user Admin:admin` is fine. For anything that **writes** through a form the
browser would normally submit (creating a test annotation or comment, submitting any
CSRF-protected POST), `curl` fails CSRF checks even with a scraped `form_token` and a real
form-login session - see `references/gotchas.md`. Use a real Playwright session instead:
```js
const { login } = require(process.env.XWIKI_UI_SKILL + '/xwiki-login');
await login(page);   // reads XWIKI_BASE_URL, XWIKI_ADMIN_USER, XWIKI_ADMIN_PASS
// ...navigate, select text / fill a form / click the real button as a user would...
```
This reads the CSRF token live off the actually-rendered page, so it is always valid. `login()`
accepts a base URL with or without the `/xwiki` suffix and throws if no login form appears, rather
than continuing unauthenticated.

## Procedure

### 0. Set up the environment and find a reusable instance

Export these once per session. The last three are read directly by `expand-and-shoot.js` and
`setup-class-object.js`, and are worth setting even when the defaults are right, so every script
and snippet agrees on one instance:
```bash
# This skill's own directory. Kimi Code: ${KIMI_SKILL_DIR} is already it. opencode:
# $XWIKI_LLM_HOME/xwiki/skills/xwiki-ui-before-after.
export XWIKI_UI_SKILL="${CLAUDE_PLUGIN_ROOT}/skills/xwiki-ui-before-after"

# Where test distributions are kept - outside any git checkout, so instance logs and swapped
# jars never show up as untracked files. Override by exporting it beforehand.
export XWIKI_TEST_INSTANCES_DIR="${XWIKI_TEST_INSTANCES_DIR:-${XDG_DATA_HOME:-$HOME/.local/share}/xwiki-test-instances}"

# The instance every script and snippet talks to. Note the trailing /xwiki: the JS helpers'
# default is http://localhost:8080/xwiki, while setup-xar-instance.sh's --base-url takes the
# host root without it.
export XWIKI_BASE_URL="${XWIKI_BASE_URL:-http://localhost:8080/xwiki}"
export XWIKI_ADMIN_USER="${XWIKI_ADMIN_USER:-Admin}"
export XWIKI_ADMIN_PASS="${XWIKI_ADMIN_PASS:-admin}"
```

Then look for something to reuse before building anything:
```bash
pgrep -af 'STOP.KEY=xwiki'                    # already running?
lsof -nP -iTCP:8080 -sTCP:LISTEN              # and is it on the port we want?
ls "$XWIKI_TEST_INSTANCES_DIR"                # existing per-ticket distributions
```
`setup-instance.sh` stops and restarts the instance it deploys into, so check *whose* instance is
on 8080 first. The rule `xwiki-build` states for Docker ITs applies here unchanged: never stop an
XWiki instance this session did not start. If the port belongs to something the user is running,
ask before touching it rather than restarting it underneath them.

**Every path in this skill needs a running instance**, including the two file-copy ones - "no
Maven build and no restart" does not mean nothing to manage. If nothing is listening, start one
yourself and wait for it to answer, because a capture run against a half-started Jetty fails in
confusing ways (expect roughly 40s):
```bash
(cd "$INSTANCE_DIR" && ./start_xwiki.sh > "$INSTANCE_DIR/xwiki-start.log" 2>&1 &)
until curl -sf -o /dev/null "$XWIKI_BASE_URL/bin/view/Main/WebHome"; do sleep 2; done; echo up
```
An instance you started is yours to stop when you are done; one you found is not.

If a distribution of a suitable version already exists under
`$XWIKI_TEST_INSTANCES_DIR/<other-ticket>-test/`, copy it - typically instant on a
copy-on-write filesystem, versus 30-60+ minutes to build one from scratch:
```bash
mkdir -p "$XWIKI_TEST_INSTANCES_DIR/<this-ticket>-test"
cp -r "$XWIKI_TEST_INSTANCES_DIR"/<other-ticket>-test/xwiki-platform-distribution-*-<version> \
      "$XWIKI_TEST_INSTANCES_DIR/<this-ticket>-test/"
```
The branch's version is `grep -m1 '<version>' xwiki-platform-core/xwiki-platform-oldcore/pom.xml`
- see "How strictly the instance version has to match" above for when a mismatch actually
matters.

If the app or feature you need (e.g. AppWithinMinutes) is not installed on that instance - a 404
on its main page - install it by following the `xwiki-deploy-extension` skill; it is usually
already resolved in `data/extension/repository/` from the flavor's dependencies, so no download
is needed. Doing it through the Administration > Extensions UI instead works too, but take care
not to click through an uninstall-looking flow by accident: if a "Continue" button appears
offering to delete wiki pages, stop and re-check state with a `repo=installed` search before
clicking anything further.

### 1. Pick the fixture: a real page that already shows the change

The cheapest fixture is a page in the product where the changed code is *already* wired up. Find
it by grepping the templates for the CSS class, macro or plugin name the change touches, rather
than inventing a scenario:
```bash
grep -rl "'finder': true" --include=*.vm      # who switches this plugin on?
grep -rln "btn-group-last" --include=*.vm --include=*.less
```
That is how most comparisons are set up: a skin template reached through Preview mode, an
annotation bubble on a page with a highlight, a hint line in the CKEditor toolbar, the location
picker reached via "Edit location" on the create-page wizard (`locationPicker_macros.vm`).

Do **not** drive a feature's whole wizard/UI - AppWithinMinutes' drag-and-drop class editor, say
- unless the *workflow itself* is what is being compared, rather than the rendering it produces.
Automating that is where the flakiness lives.

**Sub-case: a PropertyClass field.** When the change is one PropertyClass's `displayEdit()` /
`displayView()` output - a single field, a validation message, an error banner - there is no
existing page to find, and creating the class and object directly via action URLs is far more
reliable than the class editor:
```bash
node "$XWIKI_UI_SKILL"/setup-class-object.js \
  TicketNameAfter number1 com.xpn.xwiki.objects.classes.NumberClass
```
`expand-and-shoot.js` is the matching capture script for that fixture. Use a **fresh space name
per state** (`...After`, `...Before`) so a stale page can never be mistaken for the other state.

**Dump the fixture's container once before writing the capture script.** Reaching for a selector
you assumed exists is the most common way to burn a 30-second Playwright timeout: XWiki's header
search input, for instance, is rendered `disabled` and stays hidden until the magnifier
(`#globalsearch button[aria-controls="headerglobalsearchinput"]`) is clicked. One `outerHTML` dump
answers what is actually there, and in what state:
```js
console.log(await page.evaluate(() => document.querySelector('#globalsearch').outerHTML));
```

Whatever the fixture, name it in the `repro` line of the comparison (step 5) - a reader's first
question is how to see this themselves.

### 2. Deploy one state

Everything here applies to each state in turn: run it once with the "after" ref, once with the
"before" ref. Which script to use comes from the packaging check above.

For a jar module, `setup-instance.sh` builds and swaps in one go. Nothing can overlap it, since
every later step needs it finished - but do not simply run it in the foreground either: a
first-time module build can exceed the 10-minute ceiling most tool harnesses put on a single
command, and the script's `tee` pipeline can hold the call open past its own logical end, so a run
that actually succeeded comes back as a timeout kill. Launch it detached and wait on its log,
which it writes to `<instance-dir>/setup-instance.log`:
```bash
nohup "$XWIKI_UI_SKILL"/setup-instance.sh ... > /dev/null 2>&1 &
until grep -qE "instance is up|FAILED|FAILURE" "$INSTANCE_DIR/setup-instance.log"; do sleep 5; done
tail -5 "$INSTANCE_DIR/setup-instance.log"
```
Wait on the log rather than piping the script's stdout through a summarizer: a non-`-f`
`tail -80` buffers *all* output until the process exits, which defeats watching it live.

```bash
"$XWIKI_UI_SKILL"/setup-instance.sh \
  --verify 'tree-webjar:META-INF/resources/webjars/xwiki-platform-tree-webjar/*/finder.js:xwiki-icon' \
  "$XWIKI_TEST_INSTANCES_DIR"/<ticket>-test/xwiki-platform-distribution-*-<version> \
  xwiki-platform-core/xwiki-platform-index/xwiki-platform-index-tree/xwiki-platform-index-tree-webjar \
  HEAD
```

**Always pass `--verify jarHint:pathInJar:pattern`** (repeatable) so a failed or wrong swap fails
loudly instead of silently leaving a stale jar deployed. In the example: `tree-webjar` matches the
swapped module's *artifactId*, `META-INF/.../*/finder.js` is a file inside the jar (`*` covers
version-numbered segments), and `xwiki-icon` must appear in its content. The spec splits on its
first two colons only, so a pattern may contain colons and spaces. Run `setup-instance.sh` with no
arguments, or `--help`, for the full flag docs.

**Then assert the state from the capture script too.** `--verify` proves the right *bytes* were
deployed; it cannot prove the page renders differently, and the file-copy paths
(`sync-static-resource.sh`) have no `--verify` at all. So log the exact property under comparison,
in both states, just before screenshotting:
```js
const info = await page.evaluate(() => {
  const el = document.querySelector('#backtoedit input[name="action_saveandcontinue"]');
  return { cls: el.className, radius: getComputedStyle(el).borderTopRightRadius };
});
console.log(state, JSON.stringify(info));
// before {"cls":"btn btn-default","radius":"0px"}
// after  {"cls":"btn btn-default btn-group-last","radius":"7px"}
```
Two log lines like that are proof the two states really differ, and they cost no vision tokens. A
screenshot pair that *looks* different is weaker evidence than the measured property, and one that
looks identical is otherwise indistinguishable from a swap that silently did nothing.

**Address the element by name, never by position.** A positional selector is the classic way to
assert on the wrong node and read a value that never changes, which looks exactly like a failed
deploy - `#backtoedit .btn-group :last-child` is a hidden input, not the button
(`references/gotchas.md`). Dump the candidates before trusting a selector:
```js
console.log(await page.evaluate(() => [...document.querySelectorAll('#backtoedit .btn-group > *')]
  .map(e => `${e.tagName}[type=${e.type}][name=${e.name}]`)));
```

**Also check the deploy itself on the file-copy paths**, where there is no `--verify`: the DOM
assertion proves what rendered, not what was written, and `sync-static-resource.sh` prints
`synced ...` unconditionally. One grep inside the instance, per state:
```bash
grep -c btn-group-last "$INSTANCE"/webapps/xwiki/skins/flamingo/previewactions.vm   # 0 before, 1 after
```

**The ref for the "before" state** is normally `<fix-commit>~1`, built via a throwaway worktree
that is cleaned up afterwards. If the fix is not committed yet that ref does not resolve: use
`HEAD` for both states, as the git-safety section above explains, or ask the user to commit first.

**Gotcha - the jar you changed may not be the jar that ships.** Where a `-legacy` module weaves
the changed module with AspectJ, the woven jar is what sits in `WEB-INF/lib` and the original is
not deployed at all, so swapping only the module you edited changes nothing on screen. Pass the
legacy module as an extra module so *its* jar is swapped; `xwiki-build` owns the rule and how to
find one. For `xwiki-platform-oldcore`, always pass
`xwiki-platform-core/xwiki-platform-legacy/xwiki-platform-legacy-oldcore` alongside it. If a
screenshot still does not reflect the change, confirm which jar ships the class:
```bash
unzip -l webapps/xwiki/WEB-INF/lib/*.jar 2>/dev/null | grep -B20 YourChangedClass.class | grep Archive
```

### 3. Capture one state

The scripts in this skill directory have no `node_modules` of their own, so point Node at the
scratchpad Playwright install rather than copying the scripts around - once per session, for
every `node ...` invocation including the export in step 6:
```bash
export NODE_PATH=/path/to/scratchpad/tmp/pw/node_modules
```

Write one small capture script and run it once per state, taking the state name as an argument so
the two runs cannot diverge. It logs the assertion from step 2, then saves two crops.

**Crop to the element, not to a hard-coded selector.** If the fix changes the DOM structure -
adds a wrapper `<div>` around an element that used to be bare, say - one selector will exist in
one state and not the other, and screenshotting a shared parent (the whole tree, not just one
row) easily bleeds in unrelated sibling content whose size differs between states:
```js
const { screenshotElement } = require(process.env.XWIKI_UI_SKILL + '/element-screenshot');
await screenshotElement(page, ['.new-wrapper', '.old-bare-element'], outPath);
```
It tries each selector in order and clips to whichever one is present via its own
`getBoundingClientRect()` plus a small pad (default 4px, overridable per side with
`{topPad, rightPad, bottomPad, leftPad}`). A sliver of an adjacent element in the output is crop
overshoot, not a bug in the fix - tighten the relevant side's pad a few px at a time.

**Capture the surrounding UI too, not just the bare element.** A crop tight enough to show only
the exact pixels that changed proves *what* changed but not *where in the product* it is, and a
reader unfamiliar with the selector or feature cannot place an isolated element on their own. So
take a second, wider shot of the same state, with enough recognizable chrome to answer "where am
I looking?": a page title, a toolbar, a panel header, page navigation.

A context shot is a **band of the page around the element**, not the element's own box one level
up. Padding cannot express that - it only grows the box outwards - so pass `maxHeight`, which caps
the clip while keeping the element's bottom edge in frame, and read the band upwards from what
changed:
```js
// ~260px of page ending just below the action bar: title, content, then the buttons.
await screenshotElement(page, ['#backtoedit'], ctxPath, {pad: 0, topPad: 260, maxHeight: 260});
```
**Anchor towards the chrome, which is not always upwards.** `maxHeight` holds the element's bottom
edge, which is right when the landmarks sit above it and wrong when they sit above *and beside* it
- there, asymmetric padding such as `{leftPad: 260, rightPad: 8, topPad: 120, bottomPad: 190}` is
the better tool. Both failure directions are worked through in `references/gotchas.md`. Look at
where the landmarks are before choosing, and note that the element's immediate parent is usually
not a context shot at all: `#backtoedit` alone is 807x63, four buttons and no chrome.

**Both shots belong to the same scenario.** Pass the wider one as the optional `context` key
alongside `image` in step 5's config, and the builder stacks it above the detail crop inside the
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

For a fixture that needs a logged-in session (creating a comment or annotation, submitting any
form), use the `xwiki-login` helper rather than re-typing the fill-and-submit boilerplate; see
"Authenticated write actions" above for why that matters more than it looks.

Keep these captures cheap in vision tokens: crop before you Read, and do not re-Read a file no
step has changed.

### 4. Run both states, then restore

Steps 2 and 3 run three times in total:

1. **after** - deploy `HEAD`, capture as `after-*`.
2. **before** - deploy `<fix-commit>~1` (or per the note in step 2), capture as `before-*`.
3. **restore** - deploy `HEAD` again, so the instance you leave running reflects the real current
   code rather than the pre-fix build. Do not skip this; the next session, or the user, will
   assume the instance matches the branch.

Before going further, check that the two states actually differ. **The assertion log lines are the
authority**: if they are identical, stop - the comparison has nothing to show, and the cause is a
deploy that did not land or a selector pointing at the wrong node, not a screenshot problem.

For the pixels, measure the difference, do not checksum it. A screenshot of a live instance is not
byte-reproducible - two captures of the *same* state routinely differ - so `md5sum` reports
spurious differences, and proves nothing when it matches either:
```bash
compare -metric AE before-detail.png after-detail.png null: 2>&1   # count of differing pixels
```
There is no useful absolute threshold - the count scales with crop size and with how much changed
(`references/gotchas.md` has measured examples). To tell a small real change from noise, capture
the *same* state twice and measure that pair first: that is your noise floor.

**A zero count is not automatically a bug.** Plenty of worthwhile fixes are semantic rather than
visual - a `<button>` becoming an `<a href>` so it can be middle-clicked and reads correctly to a
screen reader, an `aria-label` appearing, a heading level changing. If the assertions differ and
the pixels do not, the fix is real and the *fixture* is the problem: find an interaction state
where the two element types diverge, and compare that instead. Keyboard focus is the reliable one
- a focused link takes the skin's underline and a text-hugging focus ring where a button takes a
full-width box - and hover, `:active` or a rendered attribute dump work the same way. Say so in the
caption rather than implying a visual regression that was never there.

### 5. Build the comparison HTML

Crop dead whitespace if needed, then write a small JSON config and run the builder:
```bash
python3 "$XWIKI_UI_SKILL"/build-comparison.py \
  /path/to/scratchpad/comparison.html /path/to/scratchpad/config.json
```
See the script's docstring at the top of the file for the config shape: `ticket`, `title`,
`repro`, and a `scenarios` array where each entry has a `title` and `before`/`after` objects
(`image` path, an optional wider `context` path, plus a one-line `caption`).

**`repro` is interpolated as raw HTML; everything else is escaped.** So the repro line may contain
`<code>` and `<em>` - and must have its own `&`, `<` and `>` escaped by hand - while a caption or
title containing `<code>` renders as literal angle brackets. Keep captions plain prose.

The builder's docstring also lists the layout rules the template exists to enforce - heading
format, the repro line's placement, no per-scenario paragraph, a one-line caption under every
screenshot. They came from direct user feedback; do not drift from them. The one worth repeating
here because it decides how you *capture*: one scenario per state or interaction, never one per
zoom level - a detail crop and the wider shot that places it share a panel via `context`, per
step 3.

**If the user supplies a design, prototype or mockup** to compare the implementation against, use
the 3-column layout instead - see `references/design-comparison.md`.

### 6. Export the comparison to a single PNG (this is the deliverable, not an Artifact)

The deliverable is one shareable, lossless image, not a hosted Artifact page. Render the HTML
from step 5 headlessly and screenshot it at 2x scale so both the embedded screenshots and the
surrounding text stay crisp:
```bash
node "$XWIKI_UI_SKILL"/export-to-png.js \
  /path/to/scratchpad/comparison.html /path/to/scratchpad/comparison.png
```
This uses the same cached Playwright/Chromium install as the capture steps. Output is a PNG, not
a JPEG - no lossy compression - and its dimensions are the full rendered page at 2x device scale,
so a ~1100px-wide page comes out ~2200px wide.

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

## Worked example: a skin template (XWIKI-23590)

The fix added a `btn-group-last` CSS class to one button in `flamingo/previewactions.vm`, so the
last button of the Preview-mode Save group gets rounded right corners. A `pom`-packaged skin
module: file-copy deploy, no build, no restart.

Mind which button that is: `#editActionButton`'s first argument is the *label* key and its second
is the *action*, so the button labelled "Save" is `input[name="action_saveandcontinue"]` - the one
that changed - while `action_save` is the unchanged primary button labelled "Save & View". Taking
the label at face value asserts on the wrong element.

```bash
# 0. environment, and reuse the instance that is already running
export XWIKI_UI_SKILL="${CLAUDE_PLUGIN_ROOT}/skills/xwiki-ui-before-after"
export XWIKI_BASE_URL=http://localhost:8080/xwiki
export NODE_PATH=/path/to/scratchpad/tmp/pw/node_modules
INSTANCE=$XWIKI_TEST_INSTANCES_DIR/23590-test/xwiki-platform-distribution-*-18.7.0-SNAPSHOT
VM=xwiki-platform-core/xwiki-platform-flamingo/xwiki-platform-flamingo-skin/xwiki-platform-flamingo-skin-resources/src/main/resources/flamingo/previewactions.vm

# 1. fixture: any page's wiki editor, then Preview - found by grepping .vm for btn-group-last
# 2+3. after: the branch tip is already what the instance serves
node shoot-preview.js after
# after {"cls":"btn btn-default btn-group-last","radius":"7px"}

# 2+3. before: read the pre-fix file out of git without touching the working tree
git show <fix-commit>~1:"$VM" > /path/to/scratchpad/previewactions.before.vm
"$XWIKI_UI_SKILL"/sync-static-resource.sh --target-root skins "$INSTANCE" \
  /path/to/scratchpad/previewactions.before.vm flamingo/previewactions.vm
node shoot-preview.js before
# before {"cls":"btn btn-default","radius":"0px"}
grep -c btn-group-last "$INSTANCE"/webapps/xwiki/skins/flamingo/previewactions.vm   # 0 = before is deployed

# 4. restore
"$XWIKI_UI_SKILL"/sync-static-resource.sh --target-root skins "$INSTANCE" "$VM" \
  flamingo/previewactions.vm

# 5+6. one scenario, context band above the detail crop
python3 "$XWIKI_UI_SKILL"/build-comparison.py comparison.html config.json
node "$XWIKI_UI_SKILL"/export-to-png.js comparison.html comparison.png
convert comparison.png -gravity South -background "#f5f6f2" -splice 0x1 \
  -fuzz 2% -trim +repage -bordercolor "#f5f6f2" -border 40 comparison-trimmed.png
```

`shoot-preview.js` is the per-ticket capture script from step 3: `await login(page)`, open the
wiki editor, click `input[name="action_preview"]`, log the assertion, then save two crops -
```js
await screenshotElement(page, ['#backtoedit .btn-group'], detailPath, {pad: 2});
await screenshotElement(page, ['#backtoedit'], ctxPath, {pad: 0, topPad: 260, maxHeight: 260});
```
The whole run took minutes, nearly all of it writing that script - no Maven build at any point.

## Further reading

- `references/gotchas.md` - failure modes that each cost real time to discover once, grouped by
  fixtures, selectors/crops/diffs, and builds/deployment. Read it before debugging a fixture that
  "should work", a selector that reads the same in both states, or a swap that seems to do
  nothing.
- `references/release-notes-comparison.md` - how to produce the separate, simplified comparison
  for end users, which is a different artifact from the dev-facing one built in steps 5 and 6.
- `references/design-comparison.md` - the 3-column before / design prototype / after layout, for
  when a mockup has to be compared against the implementation.
