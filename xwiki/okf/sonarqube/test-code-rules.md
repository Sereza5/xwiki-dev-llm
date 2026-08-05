---
title: SonarQube test-code rules
stability: durable
summary: Correct fixes and XWiki-specific drop conditions for S5786, S5785, S3415, S6068, S8924 and
  S9016 — including why S5785 must not be applied inside equals()/hashCode() contract tests, why
  S3415's operand swap is usually unsafe, how far an S6068 eq() unwrap may reach, and how to name and
  type the local an S9016 extraction introduces.
---

# SonarQube test-code rules

S3415 · S5785 · S5786 · S6068 · S8924 · S9016

These touch only test code, so production behaviour is untouched and review risk is low. But the
module's tests actually run during verification, so a wrong edit fails the build rather than shipping
silently — which makes this family safe in a different way from the others. Read [[index]] for the
universal drop conditions first.

## S5786 — a JUnit 5 test class or method should be package-private

Two message variants: method-level *"Remove this 'public' modifier"* and class-level *"Remove
redundant visibility modifiers…"*.

**Do not infer the scope from the message or the line** — the method-level message frequently points
at the class declaration. Key the fix **by file** instead: strip the leading `public ` from

- the class declaration (including nested and `@Nested` classes), and
- every method whose immediately preceding contiguous annotation block contains a **real JUnit
  annotation**: `@Test`, `@BeforeEach`, `@AfterEach`, `@BeforeAll`, `@AfterAll`, `@ParameterizedTest`,
  `@RepeatedTest`, `@TestFactory`, `@TestTemplate`, `@Nested`.

Keep the other modifiers (`@BeforeAll public static void` → `static void`).

**Do not touch** fields, unannotated helper methods, or methods carrying an XWiki-specific (non-JUnit)
lifecycle annotation — `@BeforeComponent` and `@AfterComponent` methods stay public.

A class-level flag means the whole file's test methods get stripped, so a dense file yields far more
removals than its issue count. That is expected.

**Cross-module compile check.** `xwiki-platform-oldcore` publishes a widely used test-jar, so making a
class package-private can break another module that extends it. For each class you make
package-private, grep for `extends <Class>` across the source tree outside its own module. The risk is
only with `abstract` or base test classes — and note that a class *named* `Abstract*Test` is often not
actually abstract, so read the declaration rather than the name.

## S5785 — use `assertEquals` instead of `assertTrue(a.equals(b))`

### Do not apply this inside `equals()` / `hashCode()` contract tests

This is a **reviewer-rejected** transformation in that context, and the objection is right. In a test
whose *purpose* is to pin the equals contract, `assertTrue(a.equals(b))` shows at the call site which
object's `equals` runs, while `assertEquals(a, b)` hides that in JUnit internals — and Sonar's own
S3415 would later tell someone to swap the arguments, which **would** break it.

So the **site** decides, not the shape. Skip any assertion inside a `testEquals` / `equality` /
`nonEquality` / `hashCode` test method — especially `equals(null)`, `equals("other class")` and
self-equality assertions.

**The resolution is not to accept the issue in SonarCloud.** Put `@SuppressWarnings("java:S5785")`
plus a `//` rationale on the contract-test method, per the convention in [[code-style]].

Remaining fair game: assertions in ordinary tests that merely happen to use `assertTrue(x.equals(y))`
to compare two values.

Useful fact if you need to make that argument (verified against `junit-jupiter-api` bytecode): both
`assertEquals` and `assertNotEquals` route through `AssertionUtils.objectsAreEqual(a, b)`, which is
`a == null ? b == null : a.equals(b)`. So with the receiver kept first, the original `equals` call —
including `a.equals(null)` — really is still made. The transformation is mechanically safe; the point
is that the guarantee is invisible to a reader of the test.

### Mechanics, when a site does qualify

**Default to receiver-first — this is universally safe.** JUnit's `assertEquals(expected, actual)`
calls `expected.equals(actual)`, so keeping the original receiver in the first slot reproduces the
exact call, which stays correct even for a custom or asymmetric `equals` or a differently-typed
argument. **Never flip the operands** — doing so has caused real test failures.

```java
assertTrue(a.equals(b))                    → assertEquals(a, b)
assertFalse(a.equals(b))                   → assertNotEquals(a, b)
assertTrue(LIT == x)                       → assertEquals(LIT, x)
assertTrue(x != LIT)                       → assertNotEquals(LIT, x)     // covers hashCode() != 0
assertTrue(null == x)                      → assertNull(x)
assertTrue(a.hashCode() == b.hashCode())   → assertEquals(a.hashCode(), b.hashCode())
```

The degenerate `assertFalse(x.equals(null))` and `assertTrue(x.equals(x))` convert too — JUnit uses
`Objects.equals`. A `==` or `!=` between **references** is a distinct message and maps to
`assertSame` / `assertNotSame`, where operand order is cosmetic; trust the message. Only convert
flagged lines — an `assertTrue(x instanceof Y)` sibling on the next line stays. A message argument
moves to the end of the new call.

**Imports:** add the new static imports in alphabetical order, and remove `assertTrue`/`assertFalse`
only once the file no longer uses them.

**Two site-level gotchas:** identical assert lines can recur in one file, so a uniqueness assertion
will trip — diagnose rather than force it. And an already-half-fixed site (a flagged line sitting
directly above an existing equivalent assertion) should have the redundant flagged line **deleted**.

Handle this rule with a small parser rather than a pattern match: find the `assert(True|False)(` at the
flagged line, gather continuation lines to the statement's trailing `;`, paren-match to the outer
close, then split the inner text at the depth-zero `.equals(`, `==` or `!=`. That handles the
multi-line shape for free. Cross-check the function you derived against the one Sonar's message names
and abort on any mismatch — that check is what makes the batch trustworthy. Negation is
`assertFalse XOR (op == "!=")`.

## S3415 — swap the expected and actual arguments

**Usually unsafe — default to dropping it.** The rule assumes operand order is cosmetic, but many
flagged assertions depend on it (the same root cause as "never flip operands" above):

- **Asymmetric `equals`.** `RegexEntityReference.equals` does regex matching, so
  `regexRef.equals(plain)` is not `plain.equals(regexRef)`. Swapping flips the result and breaks the
  test.
- **`assertNotEquals(obj, null)` deliberately exercises `obj.equals(null)`.** Swapping to
  `(null, obj)` short-circuits inside `Objects.equals` and no longer tests that contract.

Only swap when both operands are plain values with symmetric `equals` and neither is `null` — for
example a bare literal genuinely sitting in the actual slot. Read the asserted type's `equals`
implementation before trusting Sonar.

Where a whole test method is nothing but such assertions, suppress the method per [[code-style]]
rather than accepting the issues in SonarCloud. `RegexEntityReferenceTest` in
`xwiki-platform-model-api` is the reference example: a class-level
`@SuppressWarnings("java:S3415")` with a multi-line rationale.

## S8924 — use a static import for a Mockito method

Message: `Use a static import for "mock"` (also `when`, `verify`, `doReturn`, …). Test code only, so
there is **zero coverage risk** — the safest batch after the comment-only rules.

Fully mechanical, with no per-site reading needed:

1. Take the flagged method names from the issue **message**, not from the line numbers — the message is
   drift-proof.
2. Replace `Mockito.<name>(` → `<name>(`. **The trailing `(` matters**: without it, `Mockito.mock(`
   also eats `Mockito.mockStatic(`.
3. Add `import static org.mockito.Mockito.<name>;` if absent. **XWiki convention: static imports form
   one alphabetically sorted block at the end of the import list, after a blank line.** Merge the new
   ones into the existing block and re-sort it; create the block after the last plain import if the
   file has none.
4. Drop `import org.mockito.Mockito;` **only if** `Mockito` no longer appears outside import lines
   (strip the import lines first, then word-search) — a surviving `Mockito.verify` or a Javadoc
   `{@link Mockito}` must keep it.

Lines only get shorter, so the 120-column check never fires.

Not yet established: whether S8924 also fires for non-Mockito statics such as
`Assertions.assertEquals`. Read the messages before assuming.

## S6068 — remove a useless Mockito `eq()` matcher

Message: "Remove this useless `eq(...)` invocation; pass the values directly" (or "Remove this and
every subsequent useless `eq(...)` invocation"). Fix: unwrap `eq(x)` back to `x`.

**The safety argument is the whole rule.** Mockito forbids mixing raw values and matchers in one
invocation, so `eq()` is only *required* when some other argument is a matcher. Sonar raises S6068
only when **every** argument of the stubbed/verified call is an `eq()`, and in that case Mockito
treats the raw values exactly as `eq()` did — the rewrite is behaviour-preserving. It follows that:

- **Unwrap the whole statement, not just the flagged argument.** One issue key can cover several
  `eq()` calls (the "and every subsequent" message variant), and a partially-unwrapped call is an
  `InvalidUseOfMatchersException` at runtime, not a compile error. Locate the enclosing statement
  (scan up until the previous line ends in `;`/`{`/`}`, down until the line ends in `;`) and unwrap
  everything in it.
- **Never touch a call Sonar did not flag.** A call mixing `eq()` with `any()`/`argThat()`/`isNull()`
  genuinely needs its `eq()`s; those are not reported and removing one breaks the test.
- `never()`, `times(n)` and `atLeastOnce()` inside `verify(mock, …)` are not arguments of the
  verified call — they neither block nor need unwrapping.

**Scripting it:** match `eq(` only when the preceding character is not `[\w.$]` (so `Matchers.eq(`
and an identifier ending in `eq` are left alone), then find the matching `)` with a scanner that
skips string and char literals. Drop `import static org.mockito.ArgumentMatchers.eq;` only when no
`eq(` survives **outside the import lines** — files usually keep some mixed-matcher calls.

Test sources only, so there is no coverage or API risk, and the module's own test suite is the
complete verification. Lines only get shorter; where the shortened statement now fits, re-join its
continuation line rather than leaving a one-token orphan.

## S9016 — extract a nested mock creation to a local variable

Message: *"Extract this mock creation to a local variable."* It fires on a `mock(...)` used directly as
an argument of another call — in XWiki almost always
`when(x.getY()).thenReturn(mock(Y.class))`. The fix declares the mock just above the statement and
passes the variable. Test code only, and creating the mock one statement earlier has no observable
effect, so there is **no coverage, API or behaviour risk**.

**Drive it off the issue's `textRange`**, exactly as for S6068: `line[startOffset:endOffset]` is the
`mock(...)` expression itself, which survives line drift far better than a pattern over the flagged
line. Insert the declaration at the **statement start** (scan up until the previous non-blank line ends
in `;`/`{`/`}`), using that line's indentation, so the `when(…)`-split-over-two-lines shape works
unchanged.

**Naming.** `<lowerCamelType>Mock` (`resourceMock`, `xWikiContextMock`) is consistent and collision-free
in practice. Reserve names **per enclosing method**, not per file: a file-wide `taken` set produces
`translationMock2` in a second test method that has no `translationMock`, which reads like a mistake.
Only suffix `2`/`3` when the same type is mocked twice in the *same* method. Where a method mocks two
different values of one type, a meaning-carrying name (`summaryMessageMock`, `detailedMessageMock`)
beats `blockMock`/`blockMock2`.

**A generic mocked type must not become a raw declaration.** `MultivaluedMap x =
mock(MultivaluedMap.class)` compiles, but a cleanup should not leave a raw type and an
unchecked-conversion warning behind. Write the type arguments and let Mockito's no-arg `mock()` infer
them:
`MultivaluedMap<String, String> queryParametersMock = mock();`. Pick the arguments the stubbed method
actually declares; for a mock only ever handed back through a `<T> T` lookup
(`componentManager.getInstance(Role.class, hint)`) any accurate parameterization works, since the
declared type has no effect there.

**The converse is not required: keep the class literal for a non-generic type.** The rule's own
compliant example is `Foo foo = mock(Foo.class);`, and the XWiki Java profile enables neither `S3740`
(raw types) nor `S6212` (local-variable type inference) — so rewriting `mock(Foo.class)` to the
reified `mock()` clears nothing and is a style choice only. `Type x = mock(Type.class)` is also the
dominant form in the test sources (~2500 occurrences in `xwiki-platform-core` alone), so keeping it
makes the extraction a pure move of the original expression.

**The type-inferred form is the only drop, and only sometimes.** When the site is `thenReturn(mock())`
there is no class literal to name, so a scripted batch must skip it — but it is usually recoverable by
hand: read the stubbed getter's return type and write `Type nameMock = mock();`. Convert it when that
type is **already imported** in the test (frequently `DocumentReference`, `Block`, `Job`); drop it when
naming the type means adding an import from a foreign library (a Hibernate `Configuration`, say) — that
is more than a mechanical cleanup should carry.

**One shape that would be wrong**: a `mock(...)` inside a lambda body that is invoked more than once
(`thenAnswer(i -> mock(X.class))`) must keep creating a fresh mock per call — check that the statement
you are hoisting out of contains no `->` above the flagged expression.

## Related

- [[index]] — rule map, denylist, universal drop conditions.
- [[code-style]] — the `@SuppressWarnings("java:SXXXX")` + rationale convention.
- [[strategy]] — XWiki's testing conventions and where each framework lives.
- [[verification]] — the build gates.
