# PLANE - Development Process with Plane.so

Development loop using Plane.so as the task board. **The task you must work on is injected into this prompt** (see the `## Your task` section appended below) — you do not fetch it. The automation owns task selection and all Plane state transitions: it moves the task to **In Progress** before this iteration and to **Review** (or, if blocked, **Todo**) after it. Implement the task in a dedicated branch, open a PR, then signal completion.

## Communication rules (read first)

- **All communication goes through task comments — never address the operator in your stdout/response.** Questions, answers, status, and blockers must be posted with `ralph/plane.sh add-comment <id> "<html>"`. Your textual response is not seen by anyone.
- **Everything sent to Plane must be HTML, not Markdown.** Comments and description fragments use `<p>`, `<code>`, `<a href>`, `<ul><li>`, `<strong>`, etc. Never send `**bold**`, `` `code` ``, `[text](url)`, or `- bullet` Markdown — it will not render.
  - ❌ WRONG: `add-comment <id> "[PR #57](https://github.com/x/pull/57)"` → renders as the literal text `[PR #57](...)`.
  - ✅ RIGHT: `add-comment <id> "<p><a href=\"https://github.com/x/pull/57\">PR #57</a></p>"`.
  - Before every `add-comment`, re-read the body: if it contains `[`…`](`, `**`, `` ` ``, or a leading `- `, rewrite it as HTML first.
- **If a comment or the description asks a question, answer it in a comment** (`add-comment`). Do not answer only in your response.
- **If you hit an infrastructure problem** — cannot run code, tests fail to start, missing Python dependencies, pip install failures, aiogram version incompatibilities — **post a comment describing the problem** (what you ran, the error) so the operator sees it, then signal completion.
- **When mentioning code in comments/descriptions, link to it on GitHub** using HTML anchors and full permalinks: `<a href="https://github.com/sgavka/aiogram-test-framework/blob/<branch>/<path>#L<line>">UserService.handle()</a>`

## Task states (managed by the loop)

You never call state-transition commands yourself — signal the outcome via the promise markers in step 9 (`TASK_DONE` → Review, `TASK_BLOCKED` → Todo) and the loop performs the actual transition. Do **not** call `set-in-progress`, `set-review`, `set-todo`, `set-done`, or `set-cancelled`.

- **Re-queue on test failure:** before each iteration the loop moves any **Review** task whose PR's `test` check(s) **failed** back to **Todo** (only checks configured via `PR_CI_CHECK_PATTERNS` count — other checks are ignored). A re-picked task continues on its existing branch/PR — see _Iteration detection_. This repo has no PR-time CI (the only workflow, publish.yml, runs its test matrix on push to master, on releases, and on manual dispatch — never on pull requests), so this never fires here — treat step 4 (Run tests and quality gates) as authoritative. A task with no PR (see step 1 — a task requiring no repository changes skips branch/PR entirely) is never affected by this rule; that is expected, not a sign the loop missed it.
- **New sub-tasks** you create default to **Backlog** (staging); pass `todo` as `create-task`'s 4th arg instead if the task is ready to be picked up immediately rather than needing manual triage. A new task also defaults to **this project's own label** — if this Plane project's board is shared with a sibling project split by label (e.g. the task is explicitly for that sibling, not this one), pass that sibling's label as `create-task`'s 5th arg instead of leaving it on this project's label, or the sibling's loop will never see it. Naming conventions for which labels route to an agent loop vary by Plane board — never assume a format from another project (e.g. do not assume a `ralph-<name>`-style prefix). A label nobody's loop is configured to watch will never be picked up by anyone. **Always run `ralph/plane.sh list-labels` first and copy the sibling's exact name from there — never guess it, even if a name seems obvious.** **Always pass this task's own `<id>` as `create-task`'s 6th arg** so a link to the new task is automatically added to this task's description — do this for every sub-task you create, not just blocking ones (step 3.2.2).
- **Blocking one task on another:** if a task cannot start until another one finishes, put `Blocked by: #<sequence_id>` in its description — `next-task` skips it until the blocker reaches Done/Cancelled. If it is safe to unblock as soon as the blocker's PR is up for review (e.g. a shared interface is already stable and will not change before merge, or the blocker's branch does not need to be deployed to prod before this task can be implemented), write `Blocked by: #<sequence_id> (review)` instead — it then unblocks once the blocker reaches its Review state. Default to the plain (Done-gated) form; only use `(review)` when you are confident merge-time changes to the blocker cannot affect the blocked task. A task depending on more than one other task can list several `Blocked by: #<sequence_id>` lines, one per blocker — each is gated independently (plain or `(review)`), and the task stays skipped until every listed blocker has resolved.
- **This task blocked on another:** if partway through you discover this task itself cannot proceed until another task finishes (see step 3.2.2), add `Blocked by: #<sequence_id>` to its own description using the same convention, then end the iteration with `<promise>TASK_BLOCKED</promise>` instead of `<promise>TASK_DONE</promise>`. The loop moves it back to **Todo** instead of Review, so `next-task` automatically skips it until the blocker resolves rather than it sitting in Review waiting on a human.
- **Per-task model override:** a task's description can contain `Model: <name>` (e.g. `Model: opus`, `Model: sonnet`, `Model: haiku`, `Model: fable`, or a full model id like `claude-sonnet-5`) to run just that task on a different model than the loop's configured default. The loop reads this from the description before starting the iteration, so it has no effect if added mid-iteration — it only takes effect the next time the task starts (including on a re-pick after `TASK_BLOCKED`). Use this when creating a sub-task that is simple/cheap enough for a smaller model (e.g. `Model: haiku` on a small, well-specified follow-up).
- **Per-task effort override:** the same convention, `Effort: <level>` (`low`, `medium`, `high`, `xhigh`, or `max`), overrides the loop's configured reasoning-effort default for just that task — same timing caveat as `Model:` above (read before the iteration starts, no effect if added mid-iteration). Use a lower level on a small, well-specified sub-task to save cost, and `xhigh`/`max` on a genuinely hard one.

## Plane API Helper

All Plane interactions go through `ralph/plane.sh` (run from repo root). **Comment and description bodies must be HTML.**

```bash
ralph/plane.sh add-comment <id> "<html>"           # Post an HTML comment on the issue
ralph/plane.sh get-comments <id>                    # List all comments [{id,body,created_at}]
ralph/plane.sh get-issue <id>                       # Full issue JSON
ralph/plane.sh get-task <ref>                       # Look up an issue by human-readable ref (e.g. TM-808) instead of its internal id
ralph/plane.sh list-labels                          # List this project's labels [{id,name}] — use to find a sibling project's exact label name for create-task; naming conventions vary per board, so always check here rather than guessing
ralph/plane.sh update-description <id>              # Replace description_html (reads HTML from stdin)
ralph/plane.sh append-description <id>             # Append HTML to END of description (reads from stdin)
ralph/plane.sh prepend-description <id>            # Prepend HTML to START of description (reads from stdin)
ralph/plane.sh set-branch <id> <branch>            # Append branch tag to description AND post a comment
ralph/plane.sh set-pr <id> <pr_url>                # Append PR link to description AND post a comment
ralph/plane.sh create-task <name> [desc] [priority] [backlog|todo] [label] [link_from_id]   # Create new task (priority: urgent|high|medium|low|none, default none — any other value is rejected loudly; default state: backlog, this project's own label — pass [label] to target a sibling project's label instead); with [link_from_id], also appends a link to the new task onto that task's description — pass <id> to link it from the task you are already working; put "Blocked by: #<seq>" or "Blocked by: #<seq> (review)" in desc to gate it on another task
ralph/plane.sh task-url <id>                        # Print an issue's web-app URL, e.g. to link an existing task (not just one you just created) from a comment
ralph/plane.sh upload-asset <file> <id> [project_id]       # Upload an image/file, attached to the task; prints {asset_id, embed_html}
ralph/plane.sh download-asset <asset_id> <out_path> <id> [project_id] # Download an asset attached to the task, to view it
ralph/plane.sh list-images <id>                    # JSON array of asset ids embedded in the task's description + comments
```

**Images in comments/descriptions.** Plane embeds uploaded images as `<image-component src="<asset_id>" width="35%" height="auto" alignment="left"></image-component>` — `src` is an asset UUID, not a literal URL.
- **To view an image already on the task** (e.g. a screenshot in the description or in a comment): each entry in the injected `comments` array carries an `images` field listing any embedded asset ids (comments-only; the description itself is left as raw `description_html`, so scan it directly for `<image-component src="...">` if you need images from there too — or just run `list-images <id>` to get every image id from both in one call). Then `download-asset <asset_id> <local_path> <id>` and read the local file to view it.
- **To embed a new image** (e.g. a screenshot you captured to illustrate a bug or a UI change): `upload-asset <file> <id>` uploads it, attached to the task you're already working, and prints `embed_html` — splice that string directly into the HTML you pass to `add-comment`/`update-description`/`append-description`/`prepend-description`.

> **CRITICAL — `set-branch` and `set-pr` ALREADY post a comment.** Each updates the description **and** posts a comment in a single call. Call each **exactly once** and then **STOP** — do **NOT** follow it with any `add-comment` carrying the same branch/PR link, the commit message, or a "PR is ready" note. The comment is already there. A second `add-comment` is a duplicate and is forbidden.
>
> - ❌ WRONG: `set-pr <id> "$PR_URL"` immediately followed by `add-comment <id> "$(git log -1 ...)"` or `add-comment <id> "[PR #57](...)"`.
> - ✅ RIGHT: `set-pr <id> "$PR_URL"` — and nothing else about the PR.

When creating sub-tasks during implementation, use `backlog` (the default). They are not picked up until manually moved to **Todo**.

## GitHub Helper

GitHub operations go through `ralph/github.sh` (wraps `gh`):

```bash
ralph/github.sh pr-number <branch>            # PR number for a branch ("" if none)
ralph/github.sh pr-url <branch>               # PR html URL for a branch ("" if none)
ralph/github.sh pr-state <branch>             # OPEN | MERGED | CLOSED | NONE
ralph/github.sh tests-status <branch>         # configured CI checks only: SUCCESS | FAILURE | PENDING | NONE
ralph/github.sh unresolved-threads <branch>   # unresolved review threads as JSON [{id, body}]
ralph/github.sh resolve-thread <thread_id>    # mark a review thread resolved
ralph/github.sh create-pr <base> <head> <title> <body>   # create a PR, prints its URL
```

## Development Steps

### 0. Read the injected task

The task is in the `## Your task` JSON appended to this prompt. It is **already In Progress** — do not move it. Extract:

- `id` — issue UUID (used in all Plane API calls)
- `sequence_id` — integer (used in the branch name)
- `name` — task title
- `description_html` — description (HTML)
- `priority`
- `comments` — array of `{id, body, images, created_at}` (may be empty); `images` lists any embedded image asset ids (see *Images in comments/descriptions* above)
- `pr_unresolved_threads` — unresolved GitHub PR review threads, already fetched by the automation (`[]` if no branch/PR exists yet)

### 0.1. Sync comments to description checklist

**Always run this step — even if there appear to be no comments.**

#### 1. Collect all pending items

- **Plane task comments** — already in the injected `comments` array.
- **GitHub PR review threads** — already in the injected `pr_unresolved_threads` array (fetched by the automation before this iteration started; empty if no branch/PR exists yet). Keep each thread `id` — needed to resolve it later. No need to call `unresolved-threads` yourself unless you want a fresher read mid-iteration (e.g. after pushing a fix and waiting on new review comments).

#### 2. Add new items to the description checklist

Read the current description and compare against checklist lines (containing `[ ]` or `[x]`). For every comment/thread body **not yet present**, append it as a new `[ ]` item (HTML):

```bash
printf '<p>[ ] <new item text></p>' | ralph/plane.sh append-description <id>
```

If there is no checklist yet, append a heading first:

```bash
printf '<hr/><p><strong>Checklist:</strong></p><p>[ ] <item></p>' | ralph/plane.sh append-description <id>
```

#### 3. After implementing each checklist item

Mark it done in the description and (for PR threads) resolve the GitHub conversation:

```bash
# Mark done in description (rewrite the full HTML)
UPDATED=$(ralph/plane.sh get-issue <id> | jq -r '.description_html' | sed 's/\[ \] fix X/[x] fix X/')
printf '%s' "$UPDATED" | ralph/plane.sh update-description <id>

# Resolve the GitHub thread (if this item came from a PR review)
ralph/github.sh resolve-thread <thread_id>
```

#### 4. Detect merge instruction

Scan every comment body (Plane + PR) for `merge with <branch>`, `merge to <branch>`, or `merge into <branch>` (case-insensitive). If found, note the target branch — used in step 5.1.

#### 5. Answer questions in comments

If any comment or the description poses a question you can answer, **answer it in a comment** before or during implementation:

```bash
ralph/plane.sh add-comment <id> "<p>Answer: …</p>"
```

### 1. Create a git branch

**If the task requires no repository changes** (e.g. Plane-pages-only docs work, a test/verification task, or investigation that concludes nothing needs to change in this repo): skip steps 1–6 entirely — no branch, no test/quality-gate run, no commit, no PR — post a comment summarizing what was found/done instead, then go straight to step 7 (post-task analysis — still mandatory, never skipped) and step 9 (signal completion). This task will never be re-queued by *Re-queue on test failure* above, since it has no PR/CI checks to key off — that is expected, not a loop failure.

If `description_html` mentions a specific branch (e.g. "implement in branch X" or "branch: X"), use that name. Otherwise generate one.

Branch name format: `feature/{sequence_id}_{name_slug}`

Rules for `name_slug`: lowercase the name; spaces → hyphens; remove non-alphanumeric except hyphens; collapse repeated hyphens; strip leading/trailing hyphens; truncate to 50 chars at a word boundary.

```bash
git checkout master
git pull origin master
git checkout -b <branch>
ralph/plane.sh set-branch <id> <branch>
```

#### Iteration detection

If the description already contains a `Branch: <code>…</code>` tag (written by `set-branch` in a prior iteration), this task is continuing. Detect the existing PR state:

```bash
BRANCH=$(ralph/plane.sh get-issue <id> | jq -r '.description_html' | grep -oP '(?<=Branch: <code>)[^<]+' | tail -1)
PR_STATE=$(ralph/github.sh pr-state "$BRANCH")
```

- **`OPEN`** — check out the existing branch and continue; **do not create a new branch or call `set-branch`**:
  ```bash
  git fetch origin
  git checkout "$BRANCH"
  ```
- **`MERGED` or `NONE`** — a new PR is needed. Create a new branch by appending `-v2` (then `-v3`, …, until unused):
  ```bash
  NEW_BRANCH="${BRANCH}-v2"
  git checkout master
  git pull origin master
  git checkout -b "$NEW_BRANCH"
  ralph/plane.sh set-branch <id> "$NEW_BRANCH"
  ```

### 3. Investigate and implement

3.1. Read `name` and `description_html` to understand the task.

3.2. **If the description is short** (no checklist, no investigation notes, no clear subtasks) — investigate the relevant code first, then write findings back into the description before touching code:

```bash
CURRENT_HTML=$(ralph/plane.sh get-issue <id> | jq -r '.description_html // ""')
printf '<hr/><p><strong>Investigation:</strong></p><p>…</p><p><strong>Checklist:</strong></p><p>[ ] subtask 1</p><p>[ ] subtask 2</p>' | ralph/plane.sh append-description <id>
```

If questions surface during investigation, post them as a comment and stop — this "post and stop" pattern (comment, then emit the completion signal, nothing else) recurs at every stopping point below:
```bash
ralph/plane.sh add-comment <id> "<p>Question: …</p>"
```
```
<promise>TASK_DONE</promise>
```

If no questions, continue to implementation using the checklist you just wrote.

3.2.1. **If the task is purely technical** (names a class/method/file/config to change without business context) and investigation reveals missing context needed to implement correctly (unclear API contract, unknown callers, undescribed integration point), post the specific blockers as a comment and stop the same way as 3.2:

```bash
ralph/plane.sh add-comment <id> "<p>Technical blockers:</p><ul><li>…</li></ul>"
```

3.2.2. **If part of this task's own work needs to be split off into a new task that must finish before you can continue** (e.g. investigation reveals a chunk is out of scope for this task, or has to land first as its own PR) — create that new task and make it a blocker on this one, rather than filing it as an independent follow-up. This is different from the ordinary **New sub-tasks** case (*Task states* above): most tasks you create during implementation are unrelated future work, and this task keeps going without waiting on them — only use this flow when this task genuinely cannot proceed until the new one is done. (The same flow also covers discovering a dependency on an already-existing task, not just one you create here.) Either way this needs no human answer and resolves itself automatically once the blocker is done, so do not use the "post and stop" `TASK_DONE` pattern. Instead:

```bash
NEW=$(ralph/plane.sh create-task "<name>" "<desc>" <priority> todo "" <id>)
NEW_SEQ=$(echo "$NEW" | jq -r '.sequence_id')
ralph/plane.sh add-comment <id> "<p>Blocked on #${NEW_SEQ} — <reason>.</p>"
printf '<p>Blocked by: #%s</p>' "$NEW_SEQ" | ralph/plane.sh append-description <id>
```
`create-task`'s 6th arg (`<id>`, the task you are already working) auto-appends a clickable link to the new task onto this task's description — the empty `""` 5th arg keeps the default label; pass an explicit sibling label there instead if the new task is for a different project (see *Task states*).
```
<promise>TASK_BLOCKED</promise>
```

Append `(review)` after the sequence id (`Blocked by: #<blocker_sequence_id> (review)`) if it is safe to unblock as soon as the blocker's PR is up for review rather than waiting for it to merge — see *Task states*.

3.3. Investigate the relevant code (if not done in 3.2).
3.4. If questions arise before writing code, post them as a comment and stop the same way.
3.5. Implement following all project rules in `CLAUDE.md`. After each checklist item, mark it done in the description (step 0.1 #3).
3.6. Add or update tests for changed functionality.

### 4. Run tests and quality gates

**4.1. Run the test suite.** Tests run directly on the host (no Docker in this repo). If `pytest` is not available yet, install the dev dependencies first with `pip install -e ".[dev]"`. Then run:

```bash
pytest tests/
```

All tests must pass.

**4.2. Code quality checks:** This repo has no configured linting or type-checking tooling — skip this step.

Fix all reported test failures. **If a test cannot run at all** (missing dependencies/environment failure rather than a code defect), post a comment describing it (step "Communication rules") and stop.

### 5. Commit and push

**Never push to `master` or `master`.** Always push to the feature branch.

```bash
git add -p
git commit -m "feat: <short description>

- Detail 1;
- Detail 2."
git push origin <branch>
```

### 5.1. Merge into target branch (only if a merge instruction was found in step 0.1)

```bash
git checkout <target_branch>
git pull origin <target_branch>
git merge <feature_branch>
git push origin <target_branch>
git checkout <feature_branch>
```

Then continue to step 6.

### 6. Create PR and record it on the task

```bash
PR_URL=$(ralph/github.sh create-pr master <branch> "<task name>" "Plane task: <sequence_id>")
ralph/plane.sh set-pr <id> "$PR_URL"
```

`set-pr` posts the comment too (see the CRITICAL note under *Plane API Helper*) — recording the PR is **done** after this call; do not follow it with another `add-comment` about the PR.

### 7. Post-task analysis (mandatory — run every iteration, never skip)

Before signalling done, you must reflect on this iteration against all four of the following:

- **`CLAUDE.md`** — was a rule, convention, or constraint missing, wrong, or out of date?
- **The skills** (if the repo has any, e.g. `.claude/skills/`) — was a recurring/procedural task missing a skill, or did an existing skill mislead you?
- **The ralph loop itself** — this `PLANE.md` prompt, and the `plane.sh`/`github.sh`/other helper scripts alongside it — was a step ambiguous, a helper command missing, or something in the loop unnecessary or out of order?
- **Command discoverability** — for every shell command you ran this iteration, ralph-related (`plane.sh`, `github.sh`, other helper scripts) or project-related (a build/test/lint/deploy script, etc.): could you tell how to invoke it correctly from its documented usage/help text alone, or did you have to open and read the `.sh` file's source to get the invocation right? Needing to read the source to use a command correctly is itself a finding — flag it (missing `--help`/usage comment, undocumented flag, `CLAUDE.md` not mentioning the script at all).

The reflection itself is never skipped. Only post a comment if it turned up something concrete to suggest — do not post a comment that just says nothing was found:

```bash
ralph/plane.sh add-comment <id> "<p>CLAUDE.md / skills / ralph loop suggestions:</p><ul><li>…</li></ul>"
```

### 8. Cleanup

No project-specific cleanup required.

### 9. Signal completion

End the iteration with exactly one promise marker:

- `<promise>TASK_DONE</promise>` — normal path (including the "post and stop" cases in 3.2/3.2.1/3.4). The loop posts stats, moves the task to **Review**, and picks the next task.
- `<promise>TASK_BLOCKED</promise>` — only after 3.2.2, once `Blocked by: #<sequence_id>` is already on this task's own description. The loop posts stats, moves the task back to **Todo** instead of Review, and picks the next task.

Either signal starts a fresh session for the next task; without one, the loop still posts stats and moves the task to Review (never Todo), but does not start a fresh session.

## Commit rules

### Format
```
type: short description

- Detailed point 1;
- Detailed point 2.
```

### Types
`feat` · `improvement` · `fix` · `refactor` · `docs` · `test` · `chore`

### Rules
- Do NOT add "Generated with Claude Code" or similar attribution
- Do NOT add "Co-Authored-By" lines
