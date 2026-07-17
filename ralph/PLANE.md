# PLANE - Development Process with Plane.so

Development loop using Plane.so as the task board. **The task you must work on is injected into this prompt** (see the `## Your task` section appended below) — you do not fetch it. The automation owns task selection and all Plane state transitions: it moves the task to **In Progress** before this iteration and to **Review** after it. Implement the task in a dedicated branch, open a PR, then signal completion.

## Communication rules (read first)

- **All communication goes through task comments — never address the operator in your stdout/response.** Questions, answers, status, and blockers must be posted with `docs/plane.sh add-comment <id> "<html>"`. Your textual response is not seen by anyone.
- **Everything sent to Plane must be HTML, not Markdown.** Comments and description fragments use `<p>`, `<code>`, `<a href>`, `<ul><li>`, `<strong>`, etc. Never send `**bold**`, `` `code` ``, `[text](url)`, or `- bullet` Markdown — it will not render.
  - ❌ WRONG: `add-comment <id> "[PR #57](https://github.com/x/pull/57)"` → renders as the literal text `[PR #57](...)`.
  - ✅ RIGHT: `add-comment <id> "<p><a href=\"https://github.com/x/pull/57\">PR #57</a></p>"`.
  - Before every `add-comment`, re-read the body: if it contains `[`…`](`, `**`, `` ` ``, or a leading `- `, rewrite it as HTML first.
- **If a comment or the description asks a question, answer it in a comment** (`add-comment`). Do not answer only in your response.
- **If you hit an infrastructure problem** — cannot run code, tests fail to start, missing Python dependencies, pip install failures, aiogram version incompatibilities — **post a comment describing the problem** (what you ran, the error) so the operator sees it, then signal completion.
- **When mentioning code in comments/descriptions, link to it on GitHub** using HTML anchors and full permalinks: `<a href="https://github.com/sgavka/aiogram-test-framework/blob/<branch>/<path>#L<line>">UserService.handle()</a>`

## Task states (managed by the loop)

You never change task state — the loop owns every transition. Your task is **already In Progress**; the loop moves it to **Review** when the iteration ends. Do **not** call `set-in-progress`, `set-review`, `set-done`, or `set-cancelled`.

- **Re-queue on test failure:** before each iteration the loop moves any **Review** task whose PR's `test` check(s) **failed** back to **Todo** (only checks configured via `PR_CI_CHECK_PATTERNS` count — other checks are ignored). A re-picked task continues on its existing branch/PR — see _Iteration detection_. This repo has no PR-time CI (the only workflow, publish.yml, runs its test matrix on push to master, on releases, and on manual dispatch — never on pull requests), so this never fires here — treat step 4 (Run tests and quality gates) as authoritative.
- **New sub-tasks** you create default to **Backlog** (staging); they are promoted to **Todo** manually when ready.

## Plane API Helper

All Plane interactions go through `docs/plane.sh` (run from repo root). **Comment and description bodies must be HTML.**

```bash
docs/plane.sh add-comment <id> "<html>"           # Post an HTML comment on the issue
docs/plane.sh get-comments <id>                    # List all comments [{id,body,created_at}]
docs/plane.sh get-issue <id>                       # Full issue JSON
docs/plane.sh update-description <id>              # Replace description_html (reads HTML from stdin)
docs/plane.sh append-description <id>             # Append HTML to END of description (reads from stdin)
docs/plane.sh prepend-description <id>            # Prepend HTML to START of description (reads from stdin)
docs/plane.sh set-branch <id> <branch>            # Append branch tag to description AND post a comment
docs/plane.sh set-pr <id> <pr_url>                # Append PR link to description AND post a comment
docs/plane.sh create-task <name> [desc] [priority] [backlog|todo]   # Create new task (default: backlog)
docs/plane.sh upload-asset <file> <id> [project_id]       # Upload an image/file, attached to the task; prints {asset_id, embed_html}
docs/plane.sh download-asset <asset_id> <out_path> <id> [project_id] # Download an asset attached to the task, to view it
docs/plane.sh list-images <id>                    # JSON array of asset ids embedded in the task's description + comments
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

GitHub operations go through `docs/github.sh` (wraps `gh`):

```bash
docs/github.sh pr-number <branch>            # PR number for a branch ("" if none)
docs/github.sh pr-url <branch>               # PR html URL for a branch ("" if none)
docs/github.sh pr-state <branch>             # OPEN | MERGED | CLOSED | NONE
docs/github.sh tests-status <branch>         # configured CI checks only: SUCCESS | FAILURE | PENDING | NONE
docs/github.sh unresolved-threads <branch>   # unresolved review threads as JSON [{id, body}]
docs/github.sh resolve-thread <thread_id>    # mark a review thread resolved
docs/github.sh create-pr <base> <head> <title> <body>   # create a PR, prints its URL
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

### 0.1. Sync comments to description checklist

**Always run this step — even if there appear to be no comments.**

#### 1. Collect all pending items

- **Plane task comments** — already in the injected `comments` array.
- **GitHub PR review threads** — if `description_html` contains a `Branch: <code>…</code>` tag, fetch unresolved threads:
  ```bash
  docs/github.sh unresolved-threads <branch>   # → [{id, body}]
  ```
  Keep each thread `id` — needed to resolve it later.

#### 2. Add new items to the description checklist

Read the current description and compare against checklist lines (containing `[ ]` or `[x]`). For every comment/thread body **not yet present**, append it as a new `[ ]` item (HTML):

```bash
printf '<p>[ ] <new item text></p>' | docs/plane.sh append-description <id>
```

If there is no checklist yet, append a heading first:

```bash
printf '<hr/><p><strong>Checklist:</strong></p><p>[ ] <item></p>' | docs/plane.sh append-description <id>
```

#### 3. After implementing each checklist item

Mark it done in the description and (for PR threads) resolve the GitHub conversation:

```bash
# Mark done in description (rewrite the full HTML)
UPDATED=$(docs/plane.sh get-issue <id> | jq -r '.description_html' | sed 's/\[ \] fix X/[x] fix X/')
printf '%s' "$UPDATED" | docs/plane.sh update-description <id>

# Resolve the GitHub thread (if this item came from a PR review)
docs/github.sh resolve-thread <thread_id>
```

#### 4. Detect merge instruction

Scan every comment body (Plane + PR) for `merge with <branch>`, `merge to <branch>`, or `merge into <branch>` (case-insensitive). If found, note the target branch — used in step 5.1.

#### 5. Answer questions in comments

If any comment or the description poses a question you can answer, **answer it in a comment** before or during implementation:

```bash
docs/plane.sh add-comment <id> "<p>Answer: …</p>"
```

### 1. Create a git branch

If `description_html` mentions a specific branch (e.g. "implement in branch X" or "branch: X"), use that name. Otherwise generate one.

Branch name format: `feature/{sequence_id}_{name_slug}`

Rules for `name_slug`: lowercase the name; spaces → hyphens; remove non-alphanumeric except hyphens; collapse repeated hyphens; strip leading/trailing hyphens; truncate to 50 chars at a word boundary.

```bash
git checkout master
git pull origin master
git checkout -b <branch>
docs/plane.sh set-branch <id> <branch>
```

#### Iteration detection

If the description already contains a `Branch: <code>…</code>` tag (written by `set-branch` in a prior iteration), this task is continuing. Detect the existing PR state:

```bash
BRANCH=$(docs/plane.sh get-issue <id> | jq -r '.description_html' | grep -oP '(?<=Branch: <code>)[^<]+' | tail -1)
PR_STATE=$(docs/github.sh pr-state "$BRANCH")
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
  docs/plane.sh set-branch <id> "$NEW_BRANCH"
  ```

### 3. Investigate and implement

3.1. Read `name` and `description_html` to understand the task.

3.2. **If the description is short** (no checklist, no investigation notes, no clear subtasks) — investigate the relevant code first, then write findings back into the description before touching code:

```bash
CURRENT_HTML=$(docs/plane.sh get-issue <id> | jq -r '.description_html // ""')
printf '<hr/><p><strong>Investigation:</strong></p><p>…</p><p><strong>Checklist:</strong></p><p>[ ] subtask 1</p><p>[ ] subtask 2</p>' | docs/plane.sh append-description <id>
```

If questions surface during investigation, post them as a comment and stop — this "post and stop" pattern (comment, then emit the completion signal, nothing else) recurs at every stopping point below:
```bash
docs/plane.sh add-comment <id> "<p>Question: …</p>"
```
```
<promise>TASK_DONE</promise>
```

If no questions, continue to implementation using the checklist you just wrote.

3.2.1. **If the task is purely technical** (names a class/method/file/config to change without business context) and investigation reveals missing context needed to implement correctly (unclear API contract, unknown callers, undescribed integration point), post the specific blockers as a comment and stop the same way as 3.2:

```bash
docs/plane.sh add-comment <id> "<p>Technical blockers:</p><ul><li>…</li></ul>"
```

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
PR_URL=$(docs/github.sh create-pr master <branch> "<task name>" "Plane task: <sequence_id>")
docs/plane.sh set-pr <id> "$PR_URL"
```

`set-pr` posts the comment too (see the CRITICAL note under *Plane API Helper*) — recording the PR is **done** after this call; do not follow it with another `add-comment` about the PR.

### 7. Post-task analysis

Before signalling done, reflect on what knowledge was **missing from `CLAUDE.md` or the skills** that would have made this task easier (an undocumented pattern, a missing helper command, an architectural rule, a `PLANE.md` ambiguity). If anything significant is missing, post a comment with specific suggestions (HTML). If everything was available, skip this.

```bash
docs/plane.sh add-comment <id> "<p>CLAUDE.md / skills suggestions:</p><ul><li>…</li></ul>"
```

### 8. Cleanup

No project-specific cleanup required.

### 9. Signal completion

Emit the completion signal to end the iteration — the loop posts stats, moves the task to Review, and picks the next task. The task moves to Review either way, but only this signal starts a fresh session for the next one:
```
<promise>TASK_DONE</promise>
```

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
