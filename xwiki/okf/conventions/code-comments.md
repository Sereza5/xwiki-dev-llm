---
title: Code comment policy
stability: durable
summary: Comment about the code as it is now and state the real reason inline; never justify code by
  its history or point to transient external resources (JIRA/forum/PR URLs).
sources:
  - https://dev.xwiki.org/xwiki/bin/view/Community/CodeStyle
---

# Code comment policy

Write comments about the code **as it is now**, explaining the real reason for it — the use case,
requirement, constraint, or edge case being handled — stated inline so the comment is
self-contained. Do **not**:

- **Justify code by referring to a previous, old, or removed implementation, or to the change
  itself** ("like the previous X did", "as it was before", "to keep the old behavior", "changed
  because…"). A future reader has no knowledge of that history, and the reference becomes misleading
  once the old code is gone.
- **Point to transient external resources** — JIRA issue keys, forum/mailing-list links, PR or
  commit URLs, etc. They rot over time and disappear entirely if the project ever switches tools,
  leaving a dangling reference.

Put the actual reasoning in the comment itself. Change history and issue references belong in the
**commit message** (which keeps its JIRA prefix — see [[commit-messages]]), not in the code.

## An empty `catch` needs a `// TODO:`, not just a rationale

A `catch` block that neither rethrows nor logs is treated in XWiki as **a bug to be fixed later**,
not as a decision to be documented. So a comment that merely explains why the exception is swallowed
is not the wanted outcome — it reads as blessing the swallow. Write a `// TODO:` asking for the real
fix, then the sentence describing what happens today:

```java
} catch (Exception e) {
    // TODO: log a warning instead of ignoring this exception.
    // A plugin failing must not prevent the other plugins from being called.
}
```

Two forms, picked per site:

- **`// TODO: log a warning instead of ignoring this exception.`** — the default, for a fallback or a
  cleanup in a `finally`. Logging a warning is the stated minimum whenever there is a fallback and
  the exception is not rethrown.
- **`// TODO: change the logic so this case is not signalled by an exception.`** — when the exception
  *is* the expected outcome (a "not found" domain exception used as a signal, a missing constructor
  detected by catching `Throwable`, a null check written as a `catch`). Expecting an exception as a
  normal case is an anti-pattern; the TODO records that the logic itself should change.

The trigger is the swallowed **exception**, not the empty block: this is what a `java:S108` fix must
write, since that rule is otherwise satisfied by any comment. An empty block that is not exception
handling takes a plain explanatory comment instead — a filter branch, an empty `switch` default, and
the deliberate no-op implementations that `java:S1186` flags.

