---
name: xwiki-daily-close
description: "EXPLICIT INVOCATION ONLY. A developer's daily push to close work they already have open: their GitHub pull requests (authored, review-requested, assigned) in the xwiki and xwiki-contrib orgs, their open JIRA issues, and the forum topics they started — find what is ready to close or needs one last push, rank it in two buckets, your work and others' work waiting on you (someone waiting first, then ready, then oldest), show stats with the trend since the last run, and offer each action (merge, close the issue with its Fix Versions, mark a forum post solved, post a drafted conclusion) one at a time for a yes. Use ONLY when named — `/xwiki-daily-close`, \"run my daily close\", optionally narrowed to gh, jira or forum. Do NOT use it for \"what PRs do I have open?\", \"is XWIKI-123 fixed?\" or any single-item question: answer those directly, or with xwiki-jira for an issue. For JIRA writes it defers to xwiki-jira, for a missing backport to xwiki-backport, for PR conventions to xwiki-pull-request."
---

# Daily close

Each day, move the developer's **already open** work towards done: a few merges, a few issues
closed, a few forum topics concluded. Not new work, not triage of other people's backlog.

**It reports, then offers each write on its own and waits for a yes.** Never batch writes under
one approval, never act on a classification alone: "ready" is the rules' opinion, and a merge, a
close or a forum post is public and hard to take back. The one exception the developer can ask
for is the routine-PRs bulk item (§4), and even then each merge is listed before it happens.

## 0. The script

`daily-close.mjs` gathers the data and applies every rule that code can decide; you answer only
the questions it leaves, then it ranks. Never re-implement its rules by hand, and never re-query
what it already gathered — if its output looks wrong, fix the script.

The script is at `${CLAUDE_PLUGIN_ROOT}/scripts/daily-close.mjs` (Kimi Code
`${KIMI_SKILL_DIR}/../../scripts/`, opencode `$XWIKI_LLM_HOME/xwiki/scripts/`). Below, `dc` means
`node <that path>`.

It keeps its state in the work root's `daily-close/` directory (it prints the paths): the config,
`history.jsonl` for the trend, `actions.jsonl` for what was closed through this skill, and
`runs/<date>.json` with your `runs/<date>.answers.json` next to it.

Credentials: GitHub through the `gh` login; JIRA through `JIRA_API_TOKEN` (without it, through a
`jira` username in the config, anonymously); the forum through `DISCOURSE_API_KEY` +
`DISCOURSE_API_USERNAME` to write — without them it reads anonymously and the forum actions become
drafts to paste. A category that cannot run is reported as skipped, never as empty.

## 1. Collect

```
dc collect                 # all three; or --only gh|jira|forum: lifts the budget, writes no history,
                           # and every later command of that run takes the same --only
```

It takes a few minutes: GitHub's search API allows 30 requests a minute and the script spaces them.
If it prints `skipped forum: no forum username`, ask the developer once and run
`dc config forum=<username>` (likewise `github=`, `jira=`). An `ERROR` line means that category is
**missing** from today's report — say so; do not present its zero counts as a clean slate.

## 2. Judge what code cannot

```
dc pending                 # items waiting for a judgement, one per line
dc show <itemId>           # one item: facts, questions, evidence
```

Answer every pending item into the answers file (`dc pending` prints its path), a JSON object keyed
by item id. Read each item with `show`, one at a time — a run is hundreds of KB, do not load it
whole. Fields:

- `cls` — `ready`, `close` or `not-close`. Set it only to change the script's verdict — and set
  `close` whenever there is a concrete step for the developer, since only `ready` and `close`
  items are offered (being waited on orders them, it does not make them eligible).
- `action` — the concrete next step, in a few words ("close the PR: surli says it is obsolete",
  "post the conclusion", "answer tmortagne on the @since").
- `note` — anything the developer must know before saying yes.
- `solutionPost` — forum only, the post number to mark as the solution.
- `waiting: false` — the script saw someone else's comment after the developer's last word, but
  nobody is actually waiting (it only acknowledges, or the author parked the PR).

What to judge, by kind:

- **Pull request** with a comment from someone else after the developer's last word: does it ask
  something, ask to close the PR instead of merging it, or only acknowledge? Open review threads:
  addressed by a later commit or reply, or what exactly is left?
- **Issue** marked ready: map each branch's `pomVersion` to the matching unreleased JIRA version
  for the Fix Versions. If the issue is a bug and a maintained branch it affects is missing, it is
  a backport to do: `cls: close`, action "backport to <branch>".
- **Forum topic** — the question in the item states the buckets. Map READY to `ready` with
  `solutionPost`; CLOSE-a, CLOSE-b, CLOSE-c to `close` with the action; NOT-CLOSE to `not-close`.
  Count a vote said in words ("yes", "lgtm") — the script's `votes` only sees `+1`/`-1`. For
  CLOSE-a, write the draft conclusion to `runs/<date>-drafts/<topicId>.md`: a one-line conclusion
  (the outcome and who voted), the decided points as bullets, next steps only if the thread names
  them — never invent a JIRA key. One line per paragraph or bullet, no hard wraps. It ends with
  `PS: This post was co-written with Claude Code.` (okf/servers/index.md).

When unsure, say so in `note` rather than guessing a `ready`.

## 3. Rank and show

```
dc rank                    # --budget N / --others-budget N for one run (defaults 10 and 5)
```

It merges your answers, groups linked items into one unit (a PR and its issue, a stack of PRs in
merge order, a forum topic and the PRs it unblocks) and splits the units into two buckets, each
with its own budget: **your work** (your PRs, issues and forum topics) and **others' work waiting
on you** (their PRs to review, merge or answer), so neither crowds out the other. Within a bucket:
**someone waiting on you**, then **ready**, then the rest oldest first. It prints the stats table,
the delta since the last run, the 30-day trend and both lists with a link on every step. Show that report as it is; it is also
saved as `runs/<date>.md`.

Stale items (no human activity for a year) are counted and never offered. Bot PRs assigned to the
developer are one "routine PRs" item outside the budget.

## 4. Offer, one at a time

Walk both lists in order, your work first. For each unit, state the steps and ask before **each** write. Then:

| Step | How |
|---|---|
| Merge your PR, or another's after review | `gh pr merge <url> --squash` (one squashed commit per issue, see xwiki-pull-request). In a stack, merge in the listed order and re-check the next one is still mergeable. |
| Close a JIRA issue | Through xwiki-jira: resolution Fixed, the Fix Versions from §2, after listing the transitions. |
| Missing backport | Hand over to xwiki-backport. |
| Mark a forum post solved | `dc accept <topicId> <postNumber>` |
| Post a forum conclusion | Show the draft, apply the developer's edits, post it with the discourse MCP, then `dc accept` it. Read-only forum: give the draft and the topic link to paste. |
| Reply to someone / request a review | Draft it, show it, post it after the yes (with the attribution line when you wrote it). |
| Routine PRs | List the green ones; merge them only after the developer approves the list. |

After each write that went through, record it: `dc done <itemId> <action>` — that is the
"closed through this skill" count of the next report. If the developer says no or "later", move
on; do not re-offer it in the same run.

## Rules the script applies

So you can explain a verdict — the code is the reference:

- **Your PR is ready** when it is not a draft, mergeable, green, has no open review thread, nobody
  is waiting for your answer and, if its issue is a New Feature or Improvement, it is approved —
  unless you wrote ≥90% of the repo's commits this year ("no reviewer available").
- **An issue is ready** when every commit carrying its key is merged, no PR carrying it is open,
  and it was not reopened after the last commit (a reopen after the code means work is left).
- **A forum topic** is yours if you started it; News is excluded.
