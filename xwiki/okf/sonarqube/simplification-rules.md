---
title: SonarQube simplification rules
stability: durable
summary: Correct fixes and XWiki-specific drop conditions for the behaviour-preserving simplification
  rules — S1066, S1125, S1126, S1155, S1264, S1488, S1602, S1612, S1858, S2130, S2864, S3012, S3024,
  S3706, S6397, S7158.
---

# SonarQube simplification rules

S1066 · S1125 · S1126 · S1155 · S1264 · S1488 · S1602 · S1612 · S1858 · S1871 · S2130 · S2589 ·
S2864 · S3012 · S3024 · S3358 · S3457 · S3706 · S6397 · S7158

Behaviour-preserving rewrites that need no dataflow analysis — the best mechanical-fix fodder after
the syntax family. Read [[index]] for the universal drop conditions first.

## S6397 — redundant single-character regex character class

Message: "Replace this character class by the character itself." `"[x]"` → `"x"` inside a regex
argument (`replaceAll`, `split`, `matches`, `Pattern.compile`). One token, no dataflow, and it cannot
change what the regex matches.

- **Keep the escaping the class was carrying.** `"[\\.]"` → `"\\."` (a bare `"."` would match any
  character) and likewise for `[\\(]`, `[\\$]`, `[\\^]`. A non-metacharacter needs no escape.
- **Match the source *text*, not the decoded character**, when scripting the edit: XWiki's
  transliteration tables are written as `"[\u0132]"` — six literal characters in the file — so a
  pattern built from the decoded `Ĳ` finds nothing.
- Only single-character classes are flagged; leave the multi-character ones (`"[\u0136\u01e8]"`)
  alone, and do not "improve" the flagged call into `replace()` — that is S5361 and a separate issue.
- The dense sites are the accent-stripping `replaceAll` tables duplicated in `XWiki.java` (platform)
  and `XWikiSerializer2.java` (rendering).

## S1125 — redundant boolean literal

`x == true` → `x`; `x == false` → `!x`. Ternary shapes: `cond ? x : true` → `!cond || x`;
`cond ? x : false` → `cond && x`; `cond ? true : y` → `cond || y`; `cond ? false : y` → `!cond && y`.
An operand that is a boxed `Boolean` auto-unboxes — still correct.

## S1488 — inline an immediately-returned local

Delete the local and return the expression directly.

## S1264 — a `for` with neither initializer nor update is a `while`

`for (; cond; ) {` → `while (cond) {`. The loop variable stays where it is (it is mutated in the
body, which is why the `for` had no update clause). Nothing else changes.

## S3012 — replace a manual array/collection copy loop with a library call

Message: "Use `Arrays.copyOf`, `Arrays.asList`, `Collections.addAll` or `System.arraycopy` instead."

- Copying a whole array into a collection → `Collections.addAll(target, array)`.
- Copying a *sub-range* of an array into a new list →
  `new ArrayList<>(Arrays.asList(array).subList(from, to))`. Keep the `new ArrayList<>(…)` wrapper
  whenever the result is later mutated or handed on as a mutable list — `subList` returns a view and
  `Arrays.asList` a fixed-size list, so dropping the wrapper is a behaviour change, not a cleanup.
- Check the import: `Arrays` / `Collections` are frequently *not* yet imported in the file.

## S3024 — do not concatenate inside a `StringBuilder.append`

`buf.append("a" + x + "b")` → `buf.append("a").append(x).append("b")`. Use a **char** literal for a
single-character fragment (`append('%')`, `append(';')`) — that selects the `append(char)` overload
and is what the rule is after.

## S1858 — pointless `toString()` on a `String`

Drop the call. Trust the rule; it only fires when the receiver is statically a `String`.

## S1155 / S7158 — use `isEmpty()`

- **S1155**: `size() > 0` → `!isEmpty()`, `size() == 0` → `isEmpty()` (collections).
- **S7158**: `length() == 0` → `isEmpty()`, `length() > 0` (or `!= 0`) → `!isEmpty()`.

**S7158 fires on `String` receivers too, not only `StringBuilder`/`StringBuffer`.** The rule *message*
always names `StringBuilder`, but issues land on plain `String` locals and fields. Do not reject a
site because the receiver turns out to be a `String`: `isEmpty()` exists on `String` (Java 6),
`CharSequence` (default method, Java 15), `StringBuilder` and `StringBuffer`, so the transform is
correct for every receiver on which `.length()` is a *method*.

**Only `.length()`, never `.length`.** The array-length *field* has no `isEmpty()`.

Both rules only shrink the line, so the 120-column check never fires — and `!x.isEmpty()` is a unary
expression, so it never needs parentheses inside `&&`, `||`, `if`, a ternary or a `return`.

Compound conditions are common and safe, because only the flagged comparison changes:
`if (buffer.length() > 0 && buffer.charAt(buffer.length() - 1) == ' ')` →
`if (!buffer.isEmpty() && buffer.charAt(buffer.length() - 1) == ' ')`. The `length() - 1` is not a
comparison against zero and must be left alone.

Two receiver shapes that a simple chained-receiver pattern misses, both safe: a cast-parenthesized
receiver `((StringBuffer) getStackParameter(K)).length() == 0`, and redundant parentheses around the
call `if ((number.length()) == 0)`.

## S2864 — iterate `entrySet()` rather than `keySet()` + `get(k)`

Prefer `values().forEach(…)` when the key is unused. Otherwise use the `entrySet()` enhanced-for —
which is *required* when the key is used, when the body throws a checked exception, or when the body
uses `continue`/`break` or mutates an enclosing local. `Map.Entry` needs no import.

## S1612 — replace a lambda with a method reference

`x -> obj.foo(x)` → `obj::foo`. Also: block bodies `() -> { obj.foo(); }`, constructors
`s -> new Foo(s)` → `Foo::new`, `x -> x instanceof Foo` → `Foo.class::isInstance`, enum
`v -> v.name()` → `Enum::name`, and qualified `super` references.

**Import trap (build-breaker):** a method reference names its target *type*, which the lambda form
never needed imported. If that type is a nested class, or the stream's element type, and it is not
already imported, the build fails with `cannot find symbol` — add the import.
(`Type.class::isInstance` and `Type.class::cast` need no new import.)

## S1602 — useless curly braces around a single-statement lambda body

`x -> { stmt; }` → `x -> stmt`. The "…and then remove useless return keyword" message variant is
`x -> { return expr; }` → `x -> expr`.

- **Drop** when the body statement is a `throw` — that is a statement, not an expression.
- A `//` comment inside the braces moves above the enclosing statement.
- If collapsing the body onto the call line breaches 120 characters, break *before* the lambda
  argument instead: `foo(a,\n    x -> expr)`.
- Combine with S1611 (see [[syntax-rules]]) when both flag the same lambda.

## S1126 — replace an if-then-else returning booleans with a single return

`if (c) { return true; } else { return false; }` → `return c;`. The inverted shape returns `!c`. The
equals-style tail `if (!c) { return false; } … return true;` also collapses to `return c;`.

When the flagged condition returns `false`, you must **negate** it — apply De Morgan to a multi-part
condition (`!(A || B || C)` → `!A && !B && !C`) and wrap onto a `+4` continuation line if the result
breaches 120. A `//` comment between the `if` and the final `return` survives above the merged return.

This is a structural (multi-line) edit — match the exact block, never a single-line pattern replace.

## S3706 — `.stream().forEach()` → `.forEach()`

Two shapes: the flagged line *ends* with `.stream()` (fluent style, `.forEach(` on the next line) —
strip the trailing `.stream()`; or it holds `.stream().forEach(` inline — replace with `.forEach(`.

Gotcha: stripping a trailing `.stream()` can leave a bare receiver alone on its line. It compiles, but
re-join it as `recv.forEach(` with a `+4` continuation for the lambda when the one-liner would breach
120.

## S2130 — parse instead of boxing then unboxing

`Boolean.valueOf(s)` / `new Boolean(s).booleanValue()` / `Integer.valueOf(s)` / `Long.valueOf(s)` in a
primitive context → `Boolean.parseBoolean(s)` / `Integer.parseInt(s)` / `Long.parseLong(s)`.

Semantics are identical (same `NumberFormatException`; `parseBoolean(null)` and `parseBoolean("null")`
are `false` exactly as `valueOf` was), and it retires deprecated `new Boolean(…)` calls. The only
check is line length — `parseBoolean` is six characters longer than `valueOf`.

Convert an unflagged identical construct on an adjacent line too, so the method does not end up
half-converted.

## S1066 — merge collapsible nested `if`

Sonar flags the **inner** `if`. Fix: `if (A) { if (B) { BODY } }` → `if (A && B) { BODY }` — merge with
`&&`, delete the inner `if` line, dedent the body by four, remove one trailing brace. Wrap an operand
that contains a top-level `||` in parentheses.

A triple nest collapses to `if (A && B && C)` and resolves **two** issues, so count resolved issues by
key rather than by edit.

**Drop conditions:**
- The merged condition breaches 120 and cannot be cleanly wrapped onto a `+4` continuation line.
- The inner `if` is not the sole statement of the outer body (it has siblings, or an `else`).
- The **outer** `if` / `else if` has its own trailing `else` or `else if` — merging changes when that
  `else` fires. (An `else if` outer with *no* trailing `else` **is** mergeable:
  `} else if (A) { if (B) {…} }` → `} else if (A && B) {…}`.)
- A **multi-line or block comment** sits between the two `if`s, or a comment there documents the
  *outer* condition. A single-line `//` describing the *inner* condition is recoverable — move it
  above the merged `if` at the same indent.

A residual `X != null && X instanceof Y` left after merging is harmless (`instanceof` already excludes
null), not a defect to chase.

**Brace-balance check before building:** a correct merge removes exactly one `{` and one `}` per
issue, so per file the change in open-brace count must equal the change in close-brace count must
equal that file's issue count. Any mismatch means a stray or missing brace — inspect before building.

## S6353 — use the concise character class

`[0-9]` → `\\d` (likewise `[a-zA-Z0-9_]` → `\\w`, `[ \\t\\n…]` → `\\s`) inside a regex literal.
The sibling of S6397 and just as safe: the two forms are identical in Java's regex engine **unless
`UNICODE_CHARACTER_CLASS` is set**, which XWiki never does — verify with a grep for
`UNICODE_CHARACTER_CLASS` / `(?U)` before a large batch and then stop worrying about it.

Remember the source text carries a doubled backslash: the file contains `"\\d"`. Several issues on
one line are normal (a pattern with two `[0-9]` groups gives two keys) — combine them into one edit.

## S1905 — remove an unnecessary cast

Usually a genuine no-op: a cast to the declared type of the expression, or `(String)` on an
`Iterator<String>.next()`.

**Drop when the cast is an argument of an OVERLOADED method.** Removing it can silently re-dispatch
to a different overload and still compile, so the build will not catch the mistake. Read the callee's
overload set first; a cast such as `write(x, filter, (Map<String, Object>) properties)` where `write`
has several 3-argument forms is not a mechanical fix.

## S4201 — remove a null check made redundant by `instanceof`

`x != null && x instanceof T` → `x instanceof T`; `x == null || !(x instanceof T)` →
`!(x instanceof T)`. `instanceof` is `false` for `null` by definition, so this is exact. Nearly every
site is the head of an `equals()` or a `remove(Object)`, and the observed drop rate is zero.

## S1596 — `Collections.EMPTY_LIST` → `Collections.emptyList()`

Also `EMPTY_MAP`/`EMPTY_SET`. The typed factory infers its type argument from the target, so a call
site that passed the raw constant keeps compiling; it just stops being a raw type.

## Related

- [[index]] — rule map, denylist, universal drop conditions.
- [[syntax-rules]] — S1611, which pairs with S1602.
- [[verification]] — the build gates that confirm a fix.

## S1871 — two branches with an identical body

Message: "This branch's code block is the same as the block for the branch on line N." Merge the two
conditions with `||`; `||` short-circuits in the same order the `if`/`else if` chain evaluated in, so
the number and order of predicate calls is unchanged — including the case where the *second* condition
would throw had the first not been taken (`result.isEmpty() || … || result.get().x()` is still safe).

- **The discriminator is `BooleanExpressionComplexity` (max 3), and it is decidable before you edit.**
  Count the `&&`/`||` in the merged condition. Two-branch merges pass (`!a || b`,
  `x.equals(y) || x.length() > y.length()`, `(A && B) || (C && D)` is exactly 3). A four-branch
  `return false` chain came out at 10 and the build rejected it — leave those alone.
- Merging branches whose bodies are `return X;` is the same edit; do not "improve" it into a bare
  `return <condition>;` if that removes covered instructions from a module near its coverage floor.
- When the branches carry one comment each, merge the comments above the single `if` rather than
  dropping either.

## S2589 — a sub-expression that is always true (or false)

Message: "Remove this expression which always evaluates to …". This one is **mostly drops**, and the
split is about *why* the expression is redundant.

**Fix** when the redundancy is created by the surrounding code and is therefore pure noise:

- A conjunct made redundant by the preceding branch of the same chain — after `if (count && composite)`,
  the next `else if (count && !composite)` is just `else if (count)`, and the one after that
  (`!count && composite`) is `else if (composite)`.
- A null check after an `instanceof` **pattern binding** (`… instanceof ExtensionId id && id != null`).
- A null check on a variable inside a block already guarded by `instanceof` on it.
- A conjunct the enclosing disjunction already implies: `!ws || (ws && !inWs)` → `!ws || !inWs`.

**Drop** when the expression is *deliberate*:

- A dead **defensive** null check — it costs nothing, reads as intentional, and in concurrent code
  (queue polls, cache lookups) removing it is a behaviour argument.
- A numbered/exhaustive case analysis whose comments document the cases (`// 1.` … `// 4.`): the
  "redundant" conjunct is what makes the table readable.
- One of several identical guards repeated for symmetry (a `if (!save) { doc = doc.clone(); }` pattern
  repeated per field) — clearing only the first breaks the pattern.

## S3358 — nested ternary

Message: "Extract this nested ternary operation into an independent statement." Turn the OUTER condition
into a guard clause and leave the inner ternary as the only one:

    return type == T ? (ref instanceof R r ? r : new R(ref)) : null;
    // becomes
    if (type != T) {
        return null;
    }
    return ref instanceof R r ? r : new R(ref);

That form evaluates nothing the original did not, so it is behaviour-preserving. For an assignment,
declare the local with the else-value and assign under the `if`; for a chained ternary, expand to
`if`/`else if`/`else` assigning the local.

- **Drop when the ternary is an argument of a `this(…)`/`super(…)` delegating constructor call** — no
  statement may precede it, so clearing the issue needs a static helper method.
- **Check `ExecutableStatementCount` (30)**: the extraction adds a statement, so a long method already
  at the cap fails the build. See [[index]].

## S3457 — read the message, the rule has two shapes

- **"No need to call `toString()` …"** — clean: delete the call and let the formatter (or SLF4J) do the
  conversion. Same shape as the only fixable form of `S2629`.
- **"`%n` should be used in place of `\n`"** — a **behaviour change**, because `%n` emits the platform
  separator. Always drop it when the produced string is asserted, compared, or is a wire/diff format
  (`UnifiedDiffBlock`'s unified-diff header is rebuilt literally by its test), and drop it when a
  sibling `format` call in the same message keeps `\n` — "fixing" one half yields inconsistent output.

## S3824 — `Map.get()`/`containsKey()` + condition → `computeIfAbsent`

Clean **only** when the guarded block is exactly one `put` of a freshly built value:

    List<URL> l = map.get(k); if (l == null) { l = new ArrayList<>(); map.put(k, l); } l.add(v);
    // becomes
    map.computeIfAbsent(k, key -> new ArrayList<>()).add(v);

- **Drop when the guarded block does anything else** — an `else if` branch, another key, logging, an
  early return. `computeIfPresent` in the message is a hint that the shape is not a plain absent-put.
- **Drop when the map is a `ConcurrentHashMap` and the mapping function calls out to another
  component.** `computeIfAbsent` runs the function while holding the bin lock, so a call that can reach
  back into the same map deadlocks; the pre-existing get/put version does not.
- The `containsKey` form differs from `computeIfAbsent` only for a key mapped to `null`, which is fine
  for the config/registry maps this fires on — but say so if the map can legitimately hold nulls.
