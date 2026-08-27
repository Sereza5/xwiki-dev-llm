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
it first - just use `HEAD` for the "after" build. This is a real failure mode, not a hypothetical
one: an agent following this procedure amended the user's own commit mid-run trying to "make the
before/after refs work", rewriting history nobody asked it to touch. If you ever find yourself
reaching for `git commit`/`git add`/`--amend` while following these steps, stop - it means you
have misunderstood the ref you were given, not that committing is the fix.

## Check the module's packaging before picking a deploy script

`setup-instance.sh` only works for **jar**-packaged modules - it builds and copies a jar into
`WEB-INF/lib`. Check first:
```bash
grep -m1 '<packaging>' path/to/module/pom.xml
```
- `<packaging>jar</packaging>`, or no `<packaging>` tag at all since jar is Maven's default →
  use `setup-instance.sh`, as in step 2. It automates what `xwiki-deploy-extension` describes for
  a core extension - replace the jar in `WEB-INF/lib`, restart - and adds the parts that are
  specific to a comparison: building the module at an arbitrary git ref via a throwaway worktree,
  and `--verify`.
- `<packaging>xar</packaging>` (wiki pages, e.g. `xwiki-platform-annotation-ui`) → there is no
  jar to copy. Build the module at the ref you want, then **follow the `xwiki-deploy-extension`
  skill** to install the resulting XAR into the already-running instance over the REST job API,
  including its uninstall-then-reinstall step, which you will hit on the second state because the
  first one is already installed. Do not re-derive that flow here.

  Fallback: that route is the Extension Manager, so it cross-checks the XAR's declared dependency
  versions against the instance's bundled core jars and fails outright with
  `InstallException: Dependency [...] is not compatible with core extension feature [...]` as soon
  as the branch's `${project.version}` has drifted from the cached instance's version - a rebase
  bumping 18.6.0-SNAPSHOT to 18.7.0-SNAPSHOT is enough. When that happens, use
  `setup-xar-instance.sh`, which builds at a git ref and pushes the XAR through the classic
  Administration > Import page instead, overwriting the named documents with no dependency graph
  involved:
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
CSRF-protected POST), do not reach for `curl` even with a scraped `form_token` and a real
form-login session - some endpoints, e.g. the annotation-rest module's POST, reject it with
"Invalid or missing form token" for reasons not fully root-caused (suspected response caching
serving a stale token to `curl`, since the exact same token string was observed to survive
across a fresh login). Use a real Playwright session instead:
```js
const { login } = require(process.env.XWIKI_UI_SKILL + '/xwiki-login');
await login(page);   // reads XWIKI_BASE_URL, XWIKI_ADMIN_USER, XWIKI_ADMIN_PASS
// ...navigate, select text / fill a form / click the real button as a user would...
```
This reads the CSRF token live off the actually-rendered page, so it is always valid. `login()`
accepts a base URL with or without the `/xwiki` suffix and throws if no login form appears, rather
than continuing unauthenticated. Note that XWiki serves the login page with HTTP **401** by
design, form included - do not treat that status as a failure in your own scripts.

## Procedure

### 0. Set up the environment and find a reusable instance

Export these once per session. The last three are read directly by `expand-and-shoot.js` and
`setup-class-object.js`, and are worth setting even when the defaults are right, so every script
and snippet agrees on one instance:
```bash
# This skill's own directory. In Claude Code the plugin root is ${CLAUDE_PLUGIN_ROOT}; in Kimi
# Code the equivalent is ${KIMI_SKILL_DIR} (already this directory); in opencode, $XWIKI_LLM_HOME
# points at the checkout, so it is $XWIKI_LLM_HOME/xwiki/skills/xwiki-ui-before-after.
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

Whatever the fixture, name it in the `repro` line of the comparison (step 5) - a reader's first
question is how to see this themselves.

### 2. Deploy one state

Everything here applies to each state in turn: run it once with the "after" ref, once with the
"before" ref. Which script to use comes from the packaging check above.

For a jar module, run `setup-instance.sh` **in the foreground**, not backgrounded. Every later
step depends on it finishing first, so there is nothing to overlap it with - backgrounding just
trades live output for having to poll a task file. It prints its own progress
(`--- building ... ---`, `--- stopping instance ---`) and tees its full output to
`<instance-dir>/setup-instance.log`.

```bash
"$XWIKI_UI_SKILL"/setup-instance.sh \
  --verify 'tree-webjar:META-INF/resources/webjars/xwiki-platform-tree-webjar/*/finder.js:xwiki-icon' \
  "$XWIKI_TEST_INSTANCES_DIR"/<ticket>-test/xwiki-platform-distribution-*-<version> \
  xwiki-platform-core/xwiki-platform-index/xwiki-platform-index-tree/xwiki-platform-index-tree-webjar \
  HEAD
```

**Always pass `--verify jarHint:pathInJar:pattern`** (repeatable) so a failed or wrong swap fails
loudly instead of silently leaving a stale jar deployed. Reading the example above: `tree-webjar`
is a substring of the swapped module's *artifactId*, `META-INF/.../*/finder.js` is the file inside
the jar (a `*` glob covers version-numbered path segments such as `18.6.0-SNAPSHOT`), and
`xwiki-icon` is a string that must appear in that file's content. Because the script matches the
hint against each swapped module's artifactId rather than re-searching `WEB-INF/lib`, it cannot
accidentally match an unrelated jar with a similar name - `tree-webjar` will not silently match
`xwiki-platform-index-tree-webjar`'s neighbours. Run `setup-instance.sh` with no args for the full
flag docs.

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
assert on the wrong node and get a value that is identical in both states - which step 4 tells you
to read as a failed deploy, sending you to debug the deploy instead of the selector. In this very
template, `#backtoedit .btn-group :last-child` looks reasonable and is wrong: `#editActionButton`
emits a hidden `<input name="xaction">` after each submit button, so the group's four children are
`action_save`, `xaction`, `action_saveandcontinue`, `xaction`, and `:last-child` is a hidden input
whose class and radius never change. Dump the candidates before trusting a selector:
```js
console.log(await page.evaluate(() => [...document.querySelectorAll('#backtoedit .btn-group > *')]
  .map(e => `${e.tagName}[type=${e.type}][name=${e.name}]`)));
```

**Also check the deploy itself on the file-copy paths.** The DOM assertion proves what *rendered*;
it cannot tell a sync that wrote to the wrong path from a fix that does nothing, and
`sync-static-resource.sh` prints `synced ...` unconditionally. One grep on the file inside the
instance closes that gap, per state:
```bash
grep -c btn-group-last "$INSTANCE"/webapps/xwiki/skins/flamingo/previewactions.vm   # 0 before, 1 after
```

**The ref for the "before" state** is normally `<fix-commit>~1`, which builds via a throwaway git
worktree and cleans it up. If the fix is **not committed yet**, `<fix-commit>~1` has nothing to
resolve. Never solve that by committing the fix yourself - use `HEAD` (the actual current commit)
as the "before" ref and build "after" straight from the dirty working tree, also `HEAD`, since
these scripts read the working tree as-is when given `HEAD` rather than diffing against it. Or ask
the user whether they would rather commit it themselves first.

**Gotcha - the jar you changed may not be the jar that ships.** When a `-legacy` module weaves
the changed module with AspectJ, the woven jar is what sits in `webapps/xwiki/WEB-INF/lib/` and
the original is not deployed standalone, so swapping only the module you edited changes nothing
on screen. `xwiki-build` owns this rule and the way to find such a module
(`grep -rl '<weaveDependency>' --include=pom.xml`); the consequence here is that the legacy module
must be passed as an extra module so *its* jar is the one swapped. `xwiki-platform-oldcore` is
the case you will hit most - always pass
`xwiki-platform-core/xwiki-platform-legacy/xwiki-platform-legacy-oldcore` alongside it. If a
screenshot still does not reflect the change, confirm which jar actually ships the class:
```bash
unzip -l webapps/xwiki/WEB-INF/lib/*.jar 2>/dev/null | grep -B20 YourChangedClass.class | grep Archive
```

If you do need to background a deploy - because you have genuinely independent work to do at the
same time, like preparing the other state's build - follow `<instance-dir>/setup-instance.log`
with `tail -f` (via the Monitor tool) rather than piping the script's own stdout through
anything. Piping through a non-`-f` `tail -80` or similar summarizer buffers *all* output until
the whole script exits, defeating the point of watching it live.

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
Beware the direction: in Preview mode the action bar sits *below* the previewed content, so a band
anchored at the top of the content column excludes the buttons entirely and produces
**byte-identical** before/after context shots. Anchoring on the element avoids that by
construction. A shot of the immediate parent is not a context shot either - `#backtoedit` alone is
807x63, four buttons and no chrome, which is the "one scenario per zoom level" mistake step 5
forbids, just inside one panel.

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

Keep these captures cheap in vision tokens - crop before you Read, and do not re-Read an
unchanged file. `references/gotchas.md` has the full cost-discipline checklist.

### 4. Run both states, then restore

Steps 2 and 3 run three times in total:

1. **after** - deploy `HEAD`, capture as `after-*`.
2. **before** - deploy `<fix-commit>~1` (or per the note in step 2), capture as `before-*`.
3. **restore** - deploy `HEAD` again, so the instance you leave running reflects the real current
   code rather than the pre-fix build. Do not skip this; the next session, or the user, will
   assume the instance matches the branch.

Before going further, check that the two states actually differ - both in the measurement and in
the pixels:
```bash
md5sum before-*.png after-*.png     # a matching pair means that crop captured nothing that changed
```
If the assertion log lines are identical, stop: the comparison has nothing to show, and the cause
is a deploy that did not land or a selector pointing at the wrong node, not a screenshot problem.
If the logs differ but a *crop* pair has matching checksums, the deploy was fine and that crop
region is wrong - it excludes the element that changed.

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

**If the user mentions a design, prototype or mockup** - a Figma or JIRA-attached image to
compare the implementation against - do not wedge it into the 2-column before/after. Use
`build-comparison-3col.py`, which adds a middle "Design prototype" column:
```bash
python3 "$XWIKI_UI_SKILL"/build-comparison-3col.py \
  /path/to/scratchpad/comparison.html /path/to/scratchpad/config.json
```
Its config shape matches the 2-column builder's, except each scenario also has a `design` object
(`image` plus `caption`, and optionally `context`). Crop the design image down to just the
relevant element first (ImageMagick `-crop`), the same way you would a full-page screenshot - a
design mockup usually includes surrounding chrome (nav, sidebar, unrelated sections) that is not
the point of the comparison.

**Always highlight the design/prototype column in yellow/amber**, never the same color as before
(red) or after (green): it is reference material, not a third implementation state, and a
distinct hue keeps that legible at a glance. `build-comparison-3col.py` already defaults its
`--design`/`--design-bg`/`--design-line` CSS variables to an amber palette - keep that
convention across tickets.

Three columns need more horizontal room than the 2-column layout to avoid the responsive
single-column breakpoint, so pass a wider viewport to `export-to-png.js` in step 6.

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
  shot that places it are one comparison, so they share a panel via `context` - see step 3.

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
- the second being the `context` band, which comes out as the page title, the previewed content and
the action bar beneath it. Total run time was a few minutes, nearly all of it writing that script -
no Maven build was involved at any point.

## Further reading

- `references/gotchas.md` - the failure modes that each cost real time to discover once: silent
  `propadd` param names, the object editor's collapsible rows, jar-swap verification, stale
  minified siblings, version drift between a branch and a cached instance, and the checklist for
  keeping screenshot and debug reads cheap in tokens. Read it before debugging a fixture that
  "should work".
- `references/release-notes-comparison.md` - how to produce the separate, simplified comparison
  for end users, which is a different artifact from the dev-facing one built in steps 5 and 6.
