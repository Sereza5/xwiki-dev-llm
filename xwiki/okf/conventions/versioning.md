---
title: Versions in code and issues (@since / @Deprecated, affected version)
stability: durable
summary: Use the next release of the current dev version, written <X.Y.0>RC1, for @since and
  @Deprecated(since=…). The current version itself is volatile — read it from pom.xml. A deprecation
  done on several branches lists ALL its versions, comma-separated, in the annotation. An issue's
  affected version is the oldest released version that has the problem.
sources:
  - https://dev.xwiki.org/xwiki/bin/view/Community/VersioningAndReleasePractices/
  - https://dev.xwiki.org/xwiki/bin/view/Community/CodeStyle/JavaCodeStyle/#HDeprecation
---

# API versioning (`@since` / `@Deprecated`)

**The format rule is durable:** for `@since` and `@Deprecated(since = "…")` tags, use the **next
release of the actual current dev version**, written as `<X.Y.0>RC1` (e.g. `18.5.0RC1`).

**Always three numeric segments** (since XWiki 16.0.0). Write `18.3.0RC1`, never `18.3RC1`;
`17.10.10`, `18.4.3`. A two-segment version like `18.3RC1` is invalid.

## `@Deprecated` — the annotation carries the version, the Javadoc tag carries the reason

A division of labour between the annotation and the Javadoc tag:

- **Always both**: the `@Deprecated` annotation *and* the `@deprecated` Javadoc tag.
- **The annotation carries WHEN**: always `since`. **Never `forRemoval`** — XWiki does not break APIs
  and `false` is the default.
- **The Javadoc tag carries WHY and WHAT INSTEAD**, and **must not repeat the version** — that would
  duplicate the annotation, and the javadoc tool already renders the annotation's `since`. So
  `@deprecated use {@link #getRoleType()} instead`, not `@deprecated since 4.4M1, use …`.
- **A deprecation done on several branches lists ALL of its versions in `since`, comma-separated** —
  `@Deprecated(since = "15.5RC1,14.10.12")`. Do **not** pick one of them (neither the newest nor the
  oldest): each version-line in which the deprecation shipped belongs in the list. No ordering is
  prescribed, so keep the order the source used.

**Backporting adds `@since` lines, it does not replace them.** When an API is backported to stable
branches, list one `@since` line per version-line where it becomes available, keeping the original
(e.g. `@since 17.10.10` / `@since 18.4.3` / `@since 18.5.0RC1`). Make the block **identical on every
branch** the code lives on (master included).

**The order of the `@since` lines doesn't matter, but write them ascending.** XWiki's best practices
define one `@since` per version ([devs list, Sep 2016](https://www.mail-archive.com/devs@xwiki.org/msg32814.html))
but no order, and the code has both orders. So never flag a block's order in a review and never
reorder an existing block just for its order; but when you write a block or add lines to one, list
them **ascending by version number**.

**`@since` goes on reusable code, not only on public API.** Anything something else calls carries
`@since` — including `internal` classes and methods, and the *tools* tests are written with: page
objects (`*-test-pageobjects`), test frameworks and test helpers (`*-test-*` modules — for example
the `@UITest` annotation and its `TestConfiguration`, or `TestUtils`). A caller needs to know when
the thing it calls appeared, whatever the module and whatever the visibility. Annotate a new
**class** *and* any new **member** added to an existing one.

**Tests themselves carry no `@since`.** A test class or test method (`src/test/**`, `*IT.java`,
`*Test.java`) is not reusable — nothing calls it — so there is nothing to version. And when
backporting, **never invent an `@since`** where the source code didn't already have one.

**The version number itself is volatile — do not cache it here or trust any `CLAUDE.md` string.**
To get the current dev version:

- Read the root `pom.xml` `<version>` of the repo you are in, or
- Look at the SNAPSHOT jar names under `~/.m2` / nexus.

XWiki Commons, XWiki Rendering and XWiki Platform are **released together with the same version**,
so the same version string applies across those repos.

See also [[backward-compatibility]] for the `@Unstable` lifecycle that pairs with `@since`.

## Affected version of an issue

Whatever the tracker — JIRA's **Affects Version/s**, OpenProject's **Observed in versions** — set the
**oldest released version that has the problem**, never just the latest release: that understates the
range and defeats backport triage. For a bug, it is the first release containing the faulty code
(`git tag --contains <commit>`); for a missing feature, the first release containing what it builds on.
If that predates the versions the tracker defines, use its oldest one; if pinning it is impractical,
fall back to the last LTS that has the problem (the LTS: [[jira]]).
