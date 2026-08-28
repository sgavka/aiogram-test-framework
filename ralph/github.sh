#!/usr/bin/env bash
# GitHub helper for the ralph-plane.sh workflow. Wraps the `gh` CLI calls used
# during the development loop so PLANE.md can reference short commands instead
# of inline `gh api graphql` blocks.
#
# Usage (run from repo root):
#   github.sh pr-number <branch>            — PR number for a branch ("" if none)
#   github.sh pr-url <branch>               — PR html URL for a branch ("" if none)
#   github.sh pr-state <branch>             — PR state: OPEN | MERGED | CLOSED | NONE
#   github.sh tests-status <branch>         — test check only: SUCCESS | FAILURE | PENDING | NONE
#   github.sh mergeable <branch>            — merge conflict status: MERGEABLE | CONFLICTING | UNKNOWN | NONE
#   github.sh unresolved-threads <branch>   — unresolved review threads as JSON
#                                                  [{id, path, line, startLine, side, outdated, author, url, body, diffHunk}]
#   github.sh resolve-thread <thread_id>    — mark a review thread resolved
#   github.sh create-pr <base> <head> <title> <body>  — create a PR, print its URL
#   github.sh deploy <workflow> <branch>    — trigger a GitHub Actions workflow_dispatch (e.g. to deploy <branch> to a preview/dev environment)
#
# Required in .env: GH_OWNER (repo owner/org), GH_REPO (repo name)
# Optional in .env: PR_CI_CHECK_PATTERNS — comma-separated, case-insensitive
#   substrings of PR check names to treat as this project's CI signal for
#   `tests-status` (default: "test"). E.g. "tests,cq" matches both a "Run
#   tests in container" check and a "cq" code-quality check.

set -euo pipefail

# Load GH_*/PR_* keys from .env if present and not already set (mirrors the
# regex-based loader in plane.sh/ralph-plane.sh rather than `source`, to avoid
# choking on shell-special characters in unrelated .env values).
#
# Deliberately NOT exported: `gh` itself reserves GH_REPO (and GH_HOST) as an
# override that repoints every command at "[HOST/]OWNER/REPO" — our GH_REPO
# only ever holds the bare repo name, so exporting it under that exact name
# made every unscoped `gh` call in this script fail with `expected the
# "[HOST/]OWNER/REPO" format` (and cmd_pr_state's `|| echo "NONE"` silently
# turned that failure into a false "no PR" result). Nothing downstream needs
# these in the actual process environment — every use below is this script's
# own `$GH_OWNER`/`$GH_REPO`/`$PR_CI_CHECK_PATTERNS` shell variables, or an
# explicit `-F owner=.../-F repo=...` GraphQL argument, never env-inherited.
if [ -f .env ]; then
    while IFS='=' read -r key value; do
        if [[ "$key" =~ ^(GH|PR)_[A-Z_]+$ ]] && [ -z "${!key:-}" ]; then
            printf -v "$key" '%s' "$value"
        fi
    done < <(grep -E '^(GH|PR)_[A-Z_]+=' .env)
fi

OWNER="${GH_OWNER:?GH_OWNER not set in .env (repo owner, e.g. an org or user name)}"
REPO="${GH_REPO:?GH_REPO not set in .env (repo name)}"
CI_CHECK_PATTERNS="${PR_CI_CHECK_PATTERNS:-test}"

cmd_pr_number() {
    local branch="${1:?branch required}"
    gh pr list --head "$branch" --json number --jq '.[0].number // empty'
}

cmd_pr_url() {
    local branch="${1:?branch required}"
    gh pr list --head "$branch" --json url --jq '.[0].url // empty'
}

cmd_pr_state() {
    local branch="${1:?branch required}"
    local out
    if out=$(gh pr list --head "$branch" --json state --jq '.[0].state // "NONE"' 2>&1); then
        echo "$out"
    else
        # Surface the real gh error on stderr instead of silently reporting
        # "NONE" — a false "no PR" can trigger a needless new branch/PR.
        echo "WARNING: gh pr list failed for branch $branch: $out" >&2
        echo "NONE"
    fi
}

# Aggregate conclusion of every PR check whose name matches any pattern in
# PR_CI_CHECK_PATTERNS (comma list, case-insensitive substring match, default
# "test"). Prints: SUCCESS | FAILURE | PENDING | NONE
#   - Checks that match none of the configured patterns are ignored on
#     purpose, so e.g. a Build/Deploy check failing with green tests+cq still
#     reports SUCCESS.
#   - Priority across all matched rows: FAILURE (any fail/cancel) > PENDING
#     (any pending) > SUCCESS (all matched rows pass) > NONE (no rows matched).
#   - NONE = no PR, no configured check has reported a result yet, or this
#     repo has no PR-time CI at all (a push-only pipeline never produces a
#     check here).
# Note: this gh (2.46) has no --json on `gh pr checks`; output is TSV
#   (name<TAB>bucket<TAB>elapsed<TAB>link). bucket ∈ pass|fail|pending|skipping|cancel.
cmd_tests_status() {
    local branch="${1:?branch required}"
    local pr
    pr=$(gh pr list --head "$branch" --json number --jq '.[0].number // empty')
    if [ -z "$pr" ]; then
        echo "NONE"
        return
    fi
    local pattern
    pattern=$(echo "${CI_CHECK_PATTERNS,,}" | tr ',' '|')
    # `gh pr checks` exits non-zero when any check failed; `|| true` keeps that
    # from tripping `set -e` (we collect all matched rows, not just the first).
    local buckets
    buckets=$(gh pr checks "$pr" 2>/dev/null | awk -F'\t' -v pat="$pattern" 'tolower($1) ~ pat {print $2}') || true
    if [ -z "$buckets" ]; then
        echo "NONE"
        return
    fi
    if echo "$buckets" | grep -qE '^(fail|cancel)$'; then
        echo "FAILURE"
    elif echo "$buckets" | grep -qE '^pending$'; then
        echo "PENDING"
    elif echo "$buckets" | grep -qE '^pass$'; then
        echo "SUCCESS"
    else
        echo "NONE"
    fi
}

# GitHub computes mergeability asynchronously after a push, so a freshly
# opened/updated PR can briefly report UNKNOWN before settling into
# MERGEABLE/CONFLICTING — callers should treat UNKNOWN as "not yet known",
# not as "no conflict", and re-check later rather than acting on it.
cmd_mergeable() {
    local branch="${1:?branch required}"
    local pr
    pr=$(gh pr list --head "$branch" --json number --jq '.[0].number // empty')
    if [ -z "$pr" ]; then
        echo "NONE"
        return
    fi
    gh pr view "$pr" --json mergeable --jq '.mergeable // "UNKNOWN"'
}

cmd_unresolved_threads() {
    local branch="${1:?branch required}"
    local pr
    pr=$(gh pr list --head "$branch" --json number --jq '.[0].number // empty')
    if [ -z "$pr" ]; then
        echo "[]"
        return
    fi
    gh api graphql -f query='
query($owner:String!, $repo:String!, $pr:Int!) {
  repository(owner:$owner, name:$repo) {
    pullRequest(number:$pr) {
      reviewThreads(first:50) {
        nodes {
          id
          isResolved
          isOutdated
          path
          line
          originalLine
          startLine
          diffSide
          comments(first:1) {
            nodes { body url author { login } diffHunk }
          }
        }
      }
    }
  }
}' -F owner="$OWNER" -F repo="$REPO" -F pr="$pr" \
      --jq '[.data.repository.pullRequest.reviewThreads.nodes[]
             | select(.isResolved == false)
             | {
                 id,
                 path,
                 line: (.line // .originalLine),
                 startLine,
                 side: .diffSide,
                 outdated: .isOutdated,
                 author: .comments.nodes[0].author.login,
                 url: .comments.nodes[0].url,
                 body: .comments.nodes[0].body,
                 diffHunk: .comments.nodes[0].diffHunk
               }]'
}

cmd_resolve_thread() {
    local thread_id="${1:?thread_id required}"
    gh api graphql \
        -f query='mutation($id:ID!) { resolveReviewThread(input:{threadId:$id}) { thread { isResolved } } }' \
        -F id="$thread_id" \
        --jq '.data.resolveReviewThread.thread.isResolved'
}

cmd_create_pr() {
    local base="${1:?base required}"
    local head="${2:?head required}"
    local title="${3:?title required}"
    local body="${4:-}"
    gh pr create --base "$base" --head "$head" --title "$title" --body "$body"
}

cmd_deploy() {
    local workflow="${1:?workflow required (e.g. deploy-ralph.yml)}"
    local branch="${2:?branch required}"
    gh workflow run "$workflow" --ref "$branch"
}

CMD="${1:-}"
shift || true

case "$CMD" in
    pr-number)           cmd_pr_number "${1:-}" ;;
    pr-url)              cmd_pr_url "${1:-}" ;;
    pr-state)            cmd_pr_state "${1:-}" ;;
    tests-status)        cmd_tests_status "${1:-}" ;;
    mergeable)           cmd_mergeable "${1:-}" ;;
    unresolved-threads)  cmd_unresolved_threads "${1:-}" ;;
    resolve-thread)      cmd_resolve_thread "${1:-}" ;;
    create-pr)           cmd_create_pr "${1:-}" "${2:-}" "${3:-}" "${4:-}" ;;
    deploy)              cmd_deploy "${1:-}" "${2:-}" ;;
    *)
        echo "Usage: $0 <command> [args]"
        echo "Commands: pr-number <branch> | pr-url <branch> | pr-state <branch> | tests-status <branch> | mergeable <branch> | unresolved-threads <branch> | resolve-thread <thread_id> | create-pr <base> <head> <title> <body> | deploy <workflow> <branch>"
        exit 1
        ;;
esac
