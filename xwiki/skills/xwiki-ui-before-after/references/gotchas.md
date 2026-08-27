# Gotchas and cost discipline

Companion to `../SKILL.md`. Everything here cost real time to discover once - do not rediscover
it.

## Keep screenshot and debug reads cheap

Every screenshot read back into the conversation costs vision tokens proportional to its
resolution. A `fullPage: true` capture of a whole page is far more expensive than a tight crop of
just the element needed, and reading back a file that has not changed since it was last looked at
is pure waste. This is easy to rack up across a multi-step capture - before, design, after, plus
debug shots at each step - without noticing until token usage is already high.

- **Crop before you Read, do not Read then crop.** Use `screenshotElement` to clip to the actual
  element *before* saving the file, rather than saving a `fullPage` shot and reading it just to
  see whether the right thing rendered. Reserve `fullPage: true` for genuine debugging ("did the
  form even appear, and where") - and even then, prefer a targeted
  `page.evaluate(() => el.getBoundingClientRect())` or an `el.outerHTML` dump printed to stdout
  to confirm structure, when text would answer the question just as well.
- **Do not re-Read a file already in context.** If a step regenerates the exact same PNG
  unchanged - re-running an export at a different viewport width that produced the expected
  layout, say - skip the Read. Only Read after a step that could plausibly have changed the
  pixels: a new crop region, a new build, a retry after a fix.
- **Text dumps get the same treatment.** A REST page-content GET, or an `.xml`/`.js` file more
  than a couple hundred lines long, should be filtered (`grep -o`, `grep -c`, `sed -n`) or read
  with Read's `offset`/`limit` for the section needed, not pulled in whole. Checking whether a
  template still contains an old CSS class name is a `grep -c oldClass file` away, not a full
  Read.
- **Debug scripts should assert, not just screenshot.** Have the Playwright script `console.log`
  the specific thing being checked - a class name, a matched selector, an HTTP status, a page
  version - so a one-line log answers the question instead of a screenshot. Save the screenshot
  to disk regardless so it is there if needed, but only Read it when the log alone cannot answer.
  SKILL.md step 2 makes this mandatory for the before/after states themselves, where the logged
  property is also what proves the swap landed.

## Fixtures and the object editor

- The `propadd` action's query param for the property type is **`proptype`**, not `type`. The
  wrong name fails silently: 200 response, redirects normally, adds nothing.
- The object editor's "WebHome 0:" row needs its **text** clicked to expand, not a caret icon by
  index - there are two nested `.toggle-collapsable` elements (class-group and object), and
  clicking the outer one collapses everything instead.
- AppWithinMinutes' class-edit form overrides the save button: the selector is
  `[name=xaction_save]` / `[data-submit-value=xaction_save]`, the same element as `action_save`.
  If a save seems to do nothing or lands somewhere unexpected, it is very likely something else,
  not the button selector.
- Space and document reference construction matters: `ApplicationClassEditPage.goToEditor(ref)`
  targets `<ref>.WebHome` directly. Do not insert an extra `/Code/` path segment; that is a
  different, unrelated space.
- Chromium's native `<input type="number">` refuses non-numeric keystrokes at the DOM level, so
  typing "aaa" leaves the field empty rather than filled-then-rejected. That is the correct, real
  "after" screenshot for a reject-invalid-input fix - do not mistake the empty field for a script
  bug.
- A UI toggle can be genuinely wired up but off by default and gated behind a keyboard shortcut
  rather than a visible control: XWiki's annotation highlights only appear after `Alt+A`, because
  `AnnotationConfig`'s `displayed` property defaults to `0`. If a selector that should exist
  (`.annotation-highlight`, a `.collapse.in`) simply is not there, check the component's config
  defaults and its registered `shortcut.add(...)` keys
  (`grep -n "shortcut.add\|Shortcuts :" ...Script.xml`) before assuming the fixture is broken.
- A `data-toggle="collapse" data-target="#some-id"` button can point at an element that genuinely
  exists in the DOM, so `document.querySelector` finds it, but is not actually rendered - for
  instance inside a lazy-loaded "docextra" tab pane (Comments, Attachments, History) that has not
  been activated yet. Its `getBoundingClientRect()` comes back all-zero in that state.
  `document.querySelector(sel) !== null` is not proof a target is visible or live; check its
  bounding rect, or `offsetParent !== null`, before concluding that a click "doing nothing" is a
  real bug rather than a not-yet-loaded container.

## Selectors, crops and diffs

- **Why positional selectors bite in the skin templates.** `#editActionButton` emits a hidden
  `<input name="xaction">` after each submit button, so `#backtoedit .btn-group`'s four children
  are `action_save`, `xaction`, `action_saveandcontinue`, `xaction`. `:last-child` is therefore a
  hidden input whose class and computed style never change between states - an assertion on it
  reads as a failed deploy when the deploy was fine. Its first argument is the *label* key and its
  second the *action*, so the button labelled "Save" is `action_saveandcontinue` and the one
  labelled "Save & View" is `action_save`.
- **`--verify` matches the artifactId, not the deployed filename.** The hint is checked against
  each swapped module's artifactId rather than re-searched in `WEB-INF/lib`, so a short hint cannot
  accidentally match a neighbouring jar with a similar name.
- **Context-band anchoring, both failure directions.** `maxHeight` holds the element's bottom edge.
  In Preview mode the action bar sits *below* the previewed content, so a band anchored at the top
  of the content column drops the buttons and yields two identical context shots. A suggestion row
  at the top of a panel is the mirror case - the header bar and search field are above it, so
  bottom-anchoring cuts the wrong end off and asymmetric padding is the better tool.
- **Pixel-diff magnitudes, measured.** `compare -metric AE` on a corner-radius fix in a small
  button crop: 155. On a restyled suggestion row: 3097. A file against itself: 0. The number scales
  with crop size and with how much of it changed, so treat those as illustrations, not thresholds,
  and establish a noise floor by measuring two captures of the same state.
- **Why a real browser session, not curl, for CSRF-protected writes.** Some endpoints - the
  annotation-rest module's POST among them - reject `curl` with "Invalid or missing form token"
  even with a scraped `form_token` and a real form-login session. Not fully root-caused; response
  caching serving a stale token is the suspect, since the same token string was observed to survive
  a fresh login. A Playwright session reads the token off the rendered page, so the question does
  not arise.
- **XWiki serves its login page with HTTP 401 by design**, form included. Do not treat that status
  as a failure in your own scripts; wait for the form instead. `xwiki-login` already does.

## Builds, jars and deployment

- `mvn install` on `xwiki-platform-legacy-oldcore` can fail with "Component registered several
  times" in `target/classes/META-INF/components.txt` after switching between worktree builds that
  reuse the same `target/`. Use `mvn clean install` for that module specifically.
- After `setup-instance.sh` restarts the instance, `start_xwiki.sh` shows up in `pstree` as a
  *child* of the running `java` process, with its own `sleep` grandchild. This looks alarming,
  like an unexpected auto-restart in progress, but is entirely benign: `start_xwiki.sh` forks a
  small watcher (`while kill -0 $XWIKI_PID; do sleep 1; done`) to clean up the lock file once the
  server stops, then `exec`s into `java` itself, replacing its own PID - which is why `java`'s PID
  appears to be the watcher's parent. Do not waste time chasing this in `pstree`.
- Do not take `setup-instance.sh`'s echoed progress at face value alone, especially if its output
  was piped or buffered - use `--verify` so a bad swap fails the script instead of silently
  deploying stale code. This also catches cases where the artifactId or in-jar path assumptions
  were subtly wrong, such as a webjar path missing the `groupId:` prefix. It is not only a
  script-output problem either: the deployed code reflects whatever is on disk when the build
  runs, so if the repo's checked-out branch or commit changes underneath you mid-session - the
  user switching branches in their IDE while `setup-instance.sh` is mid-build - `--verify` is what
  catches a swap that "succeeded" but landed the wrong code. `git log -1` alone will not tell you
  what was on disk *at build time*.
- A branch open for a while, rebased since, can end up on a newer `${project.version}` than a
  cached test instance. This breaks the Extension Manager's install job for xar modules
  (`InstallException: Dependency [...] is not compatible with core extension feature [...]`), and
  therefore the `xwiki-deploy-extension` route that SKILL.md sends you to first. That specific
  failure is the one case where `setup-xar-instance.sh` earns its keep: it pushes the XAR through
  the raw wiki Import flow, which has no dependency graph to be incompatible with.
- A stale pre-built `.min.css`/`.min.js` sibling is served in preference to the raw file whenever
  a template loads it via `$xwiki.get('ssfx').use('path/to/foo.css', true)`, so overwriting only
  the raw file and restarting Jetty has zero visible effect. `sync-static-resource.sh` refreshes
  both from the same source in one step.
