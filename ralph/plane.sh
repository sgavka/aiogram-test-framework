#!/usr/bin/env bash
# Plane.so API helper for the ralph-plane.sh workflow.
#
# Usage (run from repo root):
#   docs/plane.sh next-task                              — highest-priority Todo task + its comments (filtered by PLANE_LABEL)
#   docs/plane.sh set-in-progress <id>                   — move issue to "In Progress" state (automation-internal)
#   docs/plane.sh set-review <id>                        — move issue to "Review" state (automation-internal)
#   docs/plane.sh set-todo <id>                          — move issue back to "Todo" state (automation-internal)
#   docs/plane.sh list-review                            — Review-state tasks [{id,sequence_id,name,description_html}]
#   docs/plane.sh add-comment <id> <html>                — post a comment on an issue (body must be HTML)
#   docs/plane.sh get-comments <id>                      — list all comments on an issue as JSON
#   docs/plane.sh update-description <id>                — replace description_html (reads new HTML from stdin)
#   docs/plane.sh append-description <id>                — append HTML to the end of description_html (reads from stdin)
#   docs/plane.sh prepend-description <id>               — prepend HTML to the start of description_html (reads from stdin)
#   docs/plane.sh set-branch <id> <branch>              — append branch tag to description AND post a comment
#   docs/plane.sh set-pr <id> <pr_url>                  — append PR link to description AND post a comment
#   docs/plane.sh task-in-progress                      — in-progress task (filtered by PLANE_LABEL); {"done":true} if none
#   docs/plane.sh create-task <name> [desc] [priority] [backlog|todo]  — create new issue
#   docs/plane.sh create-page <name> [desc_html]         — create new project page
#   docs/plane.sh main-page                              — get the project's main doc page (needs PLANE_MAIN_DOC_PAGE_ID; see how-to-add-plane-pages.md)
#   docs/plane.sh page-url <id>                          — print the page's web-app URL (for linking it from another page)
#   docs/plane.sh append-to-page <id>                    — append HTML to the end of a page's description_html (reads from stdin)
#   docs/plane.sh get-page <id>                          — print full page JSON (includes description_html)
#   docs/plane.sh edit-page <id> [name] [desc_html]      — patch a page's name and/or description (pass "" to skip one)
#   docs/plane.sh remove-page <id>                       — delete a page (must be archived first — see archive-page)
#   docs/plane.sh archive-page <id>                      — archive a page (and descendants); required before remove-page
#   docs/plane.sh unarchive-page <id>                    — unarchive a page (and descendants)
#   docs/plane.sh search-pages <query>                   — server-side search for pages by name
#   docs/plane.sh replace-in-page <id> <search> <replace> — literal (non-regex) search/replace within a page's description_html
#   docs/plane.sh done-in-period <from> [<to>]          — list tasks in Done state updated within a date range
#   docs/plane.sh review-done-in-period <from> [<to>]   — grouped text report of Done/Processing/Cancelled tasks updated within a range
#   docs/plane.sh set-done <id>                          — move issue to Done (operator-triggered only)
#   docs/plane.sh set-cancelled <id>                     — move issue to Cancelled (operator-triggered only)
#   docs/plane.sh get-issue <id>                         — print full issue JSON
#   docs/plane.sh list-states                            — print all project states
#   docs/plane.sh list-projects                          — print all workspace projects
#   docs/plane.sh upload-asset <file> <issue_id> [project_id]              — upload an image/file, attached to the issue; print {asset_id, embed_html}
#   docs/plane.sh download-asset <asset_id> <out_path> <issue_id> [project_id] — download an asset attached to the issue (e.g. an image embedded in a comment/description)
#   docs/plane.sh list-images <issue_id>                 — JSON array of asset ids embedded in the issue's description + comments
#
# All comment/description bodies sent to Plane must be HTML, not Markdown.
#
# Images in comments/descriptions: Plane's editor embeds uploaded images as
# <image-component src="<asset_id>" width="35%" height="auto" alignment="left"></image-component>
# — the src attribute is an asset UUID, not a literal URL. To embed a new
# image, run `upload-asset <file> <issue_id>` and splice its `embed_html` into
# the HTML you send via add-comment/update-description/append-description. To
# view an image someone else attached, run `list-images <issue_id>` to find
# asset ids, then `download-asset <asset_id> <out_path> <issue_id>` and read
# the file locally.
#
# upload-asset/download-asset go through the per-issue work-item-attachments
# endpoint (not the generic workspace-assets endpoint) because the generic
# endpoint returns HTTP 500 on this Plane instance (confirmed on two separate
# projects) — the issue-attachments endpoint is the one that actually works,
# hence the required <issue_id>.
#
# Required in .env: PLANE_HOST, PLANE_TOKEN, PLANE_USERNAME
# Optional in .env: PLANE_PROJECT_ID       (auto-detected from first project if absent)
#                   PLANE_MAIN_DOC_PAGE_ID  (id of the project's main Plane doc page, used by main-page;
#                                            empty until the page has been created once — see how-to-add-plane-pages.md)
#                   PLANE_STATE_IN_PROGRESS (default: searches by name "In Progress" in started group)
#                   PLANE_STATE_REVIEW      (default: searches by name containing "review")
#                   PLANE_STATE_DONE        (default: searches completed group for name "done")
#                   PLANE_STATE_CANCELLED   (default: first state in cancelled group)
#                   PLANE_LABEL             (name or UUID; next-task/task-in-progress only returns issues with this label)
#                   PLANE_RESPECT_BLOCKERS  (1 to skip next-task candidates blocked by an unresolved "Blocked by: #<seq>" reference)

set -euo pipefail

# ---------------------------------------------------------------------------
# Load PLANE_* vars from .env
# ---------------------------------------------------------------------------
if [ -f .env ]; then
    while IFS= read -r line; do
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${line// }" ]] && continue
        if [[ "$line" =~ ^(PLANE_[A-Z_]+)=(.*)$ ]]; then
            key="${BASH_REMATCH[1]}"
            val="${BASH_REMATCH[2]}"
            val="${val%\"}" ; val="${val#\"}"
            val="${val%\'}" ; val="${val#\'}"
            export "$key=$val"
        fi
    done < .env
fi

for var in PLANE_HOST PLANE_TOKEN PLANE_USERNAME; do
    if [ -z "${!var:-}" ]; then
        echo "ERROR: $var not set in .env" >&2
        exit 1
    fi
done

BASE="https://$PLANE_HOST/api/v1/workspaces/$PLANE_USERNAME"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_curl() {
    curl -sf -H "X-API-Key: $PLANE_TOKEN" -H "Content-Type: application/json" "$@"
}

_project_id() {
    if [ -n "${PLANE_PROJECT_ID:-}" ]; then
        echo "$PLANE_PROJECT_ID"
        return
    fi
    local id
    id=$(_curl "$BASE/projects/" | jq -r '.results[0].id // empty')
    if [ -z "$id" ]; then
        echo "ERROR: no projects found in workspace $PLANE_USERNAME" >&2
        exit 1
    fi
    echo "$id"
}

_states() {
    local pid="$1"
    _curl "$BASE/projects/$pid/states/"
}

_state_id_by_group_or_name() {
    local pid="$1" group="$2" name_hint="$3"
    local states
    states=$(_states "$pid")
    local id
    id=$(echo "$states" | jq -r --arg g "$group" --arg n "$name_hint" '
        .results[] |
        if (.group == $g and (.name | ascii_downcase | contains($n | ascii_downcase))) then .id
        else empty end
    ' | head -1)
    if [ -z "$id" ]; then
        id=$(echo "$states" | jq -r --arg g "$group" '.results[] | select(.group == $g) | .id' | head -1)
    fi
    if [ -z "$id" ]; then
        echo "ERROR: no state found for group=$group / name_hint=$name_hint" >&2
        exit 1
    fi
    echo "$id"
}

# jq expression that strips noise keys from an issue object before returning it.
# sequence_id is intentionally KEPT (used for branch names / PR bodies).
_STRIP_NOISE='del(.point, .description_binary, .start_date, .target_date, .sort_order, .is_draft, .external_source, .external_id, .project, .workspace, .estimate_point, .description_text)'

_get_desc() {
    local pid="$1" issue_id="$2"
    _curl "$BASE/projects/$pid/issues/$issue_id/" | jq -r '.description_html // ""'
}

_patch_desc() {
    local pid="$1" issue_id="$2" new_desc="$3"
    local payload
    payload=$(jq -n --arg d "$new_desc" '{description_html: $d}')
    _curl -X PATCH -d "$payload" "$BASE/projects/$pid/issues/$issue_id/" >/dev/null
}

# Post an HTML comment. Bodies are sent as-is (must already be HTML); a plain
# string with no tags is wrapped in a single <p> for convenience.
_post_comment() {
    local pid="$1" issue_id="$2" html="$3"
    if [[ "$html" != *"<"*">"* ]]; then
        html="<p>${html}</p>"
    fi
    local payload
    payload=$(jq -n --arg c "$html" '{comment_html: $c}')
    _curl -X POST -d "$payload" "$BASE/projects/$pid/issues/$issue_id/comments/" >/dev/null
}

# ---------------------------------------------------------------------------
# Commands
# ---------------------------------------------------------------------------

cmd_list_projects() {
    _curl "$BASE/projects/" | jq '.results[] | {id, name, identifier}'
}

cmd_list_states() {
    local pid
    pid=$(_project_id)
    _states "$pid" | jq '.results[] | {id, name, group}'
}

cmd_get_issue() {
    local issue_id="$1"
    local pid
    pid=$(_project_id)
    _curl "$BASE/projects/$pid/issues/$issue_id/" | jq "$_STRIP_NOISE"
}

cmd_next_task() {
    local pid
    pid=$(_project_id)

    # Fetched unconditionally: needed both for todo-state resolution below and,
    # when PLANE_RESPECT_BLOCKERS=1, to resolve which states count as "done".
    local states
    states=$(_states "$pid")

    local todo_ids
    if [ -n "${PLANE_STATE_TODO:-}" ]; then
        todo_ids="$PLANE_STATE_TODO"
    else
        # Collect IDs of unstarted (Todo) states only — Backlog is staging, not ready to implement
        todo_ids=$(echo "$states" | jq -r '.results[] | select(.group == "unstarted") | .id' | tr '\n' ',')
        todo_ids="${todo_ids%,}"
    fi

    if [ -z "$todo_ids" ]; then
        echo '{"error": "no todo states found"}' >&2
        exit 1
    fi

    # Resolve label filter from PLANE_LABEL env var (name or UUID)
    local label_id=""
    if [ -n "${PLANE_LABEL:-}" ]; then
        if [[ "${PLANE_LABEL}" =~ ^[0-9a-f-]{36}$ ]]; then
            label_id="$PLANE_LABEL"
        else
            label_id=$(_curl "$BASE/projects/$pid/labels/" \
                | jq -r --arg name "$PLANE_LABEL" \
                '.results[] | select(.name | ascii_downcase == ($name | ascii_downcase)) | .id' \
                | head -1)
            if [ -z "$label_id" ]; then
                echo "ERROR: label \"$PLANE_LABEL\" not found in project" >&2
                exit 1
            fi
        fi
    fi

    # Fetch all issues into a temp file (large per_page avoids pagination; temp file avoids ARG_MAX)
    local issues_tmp
    issues_tmp=$(mktemp)
    _curl "$BASE/projects/$pid/issues/?per_page=500&page=1" > "$issues_tmp"

    # Filter to todo states + optional label, sort by priority
    local priority_order='{"urgent":0,"high":1,"medium":2,"low":3,"none":4}'
    local candidates
    candidates=$(jq -c --argjson order "$priority_order" --arg ids "$todo_ids" --arg lbl "$label_id" '
        .results |
        map(
            select(.state as $s | ($ids | split(",")) | index($s) != null) |
            if $lbl != "" then select(.labels | index($lbl) != null) else . end
        ) |
        sort_by($order[.priority] // 5)
    ' "$issues_tmp")

    # Blocking-relationship gate: Plane's v1 API does not expose issue-relations
    # (blocked_by/blocking) at all, so this approximates it via a text convention —
    # "Blocked by: #<sequence_id>" in description_html — instead of a real relations
    # API call. Opt in with PLANE_RESPECT_BLOCKERS=1. A referenced sequence_id that
    # can't be found among the currently-fetched issues fails open (not blocking),
    # since it's more likely a stale/typo'd reference than an intentional gate.
    local next
    if [ "${PLANE_RESPECT_BLOCKERS:-0}" = "1" ]; then
        local resolved_ids
        resolved_ids=$(echo "$states" | jq -c '[.results[] | select(.group == "completed" or .group == "cancelled") | .id]')

        local seq_to_state
        seq_to_state=$(jq -c '[.results[] | {(.sequence_id | tostring): .state}] | add // {}' "$issues_tmp")

        next=$(printf '%s' "$candidates" | jq -c --argjson resolved "$resolved_ids" --argjson seqmap "$seq_to_state" '
            def blocked_seq_ids:
                (.description_html // "") |
                [scan("(?i)blocked[- ]by:?\\s*#?([0-9]+)")] | map(.[0] | tonumber);
            first(.[] | select(
                (blocked_seq_ids | map($seqmap[. | tostring]) | map(select(. != null))) as $blocker_states |
                ($blocker_states | all(. as $s | $resolved | index($s) != null))
            ))
        ')
    else
        next=$(printf '%s' "$candidates" | jq 'first')
    fi
    rm -f "$issues_tmp"

    if [ -z "$next" ] || [ "$next" = "null" ]; then
        if [ "$(echo "$candidates" | jq 'length')" -gt 0 ]; then
            echo '{"done": true, "message": "all candidate tasks are blocked by unresolved dependencies"}'
        else
            echo '{"done": true, "message": "no tasks in todo states"}'
        fi
        exit 0
    fi

    # Fetch comments and include them in the response (description stays as description_html)
    local issue_id
    issue_id=$(echo "$next" | jq -r '.id')
    local comments
    comments=$(_curl "$BASE/projects/$pid/issues/$issue_id/comments/" \
        | jq '[.results[] | {
            id,
            body: (.comment_html // "" | gsub("<[^>]*>"; "") | gsub("^\\s+|\\s+$"; "")),
            images: [(.comment_html // "") | scan("<(?:image-component|img)[^>]*\\bsrc=\"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\"") | .[0]],
            created_at
        }] | sort_by(.created_at)')

    echo "$next" | jq \
        --argjson comments "$comments" \
        ". + {comments: \$comments} | $_STRIP_NOISE"
}

cmd_set_in_progress() {
    local issue_id="$1"
    local pid
    pid=$(_project_id)

    local state_id="${PLANE_STATE_IN_PROGRESS:-}"
    if [ -z "$state_id" ]; then
        state_id=$(_state_id_by_group_or_name "$pid" "started" "in progress")
    fi

    _curl -X PATCH -d "{\"state\": \"$state_id\"}" \
        "$BASE/projects/$pid/issues/$issue_id/" | jq '{id, state, name}'
}

cmd_set_review() {
    local issue_id="$1"
    local pid
    pid=$(_project_id)

    local state_id="${PLANE_STATE_REVIEW:-}"
    if [ -z "$state_id" ]; then
        local states
        states=$(_states "$pid")
        state_id=$(echo "$states" | jq -r '
            .results[] |
            select(.name | ascii_downcase | contains("review")) |
            .id
        ' | head -1)
    fi
    if [ -z "$state_id" ]; then
        echo "ERROR: no review state found; set PLANE_STATE_REVIEW in .env" >&2
        exit 1
    fi

    _curl -X PATCH -d "{\"state\": \"$state_id\"}" \
        "$BASE/projects/$pid/issues/$issue_id/" | jq '{id, state, name}'
}

# Move an issue back to the Todo (unstarted) state. Used by the loop's
# pre-iteration sweep when a Review task's PR tests have failed.
cmd_set_todo() {
    local issue_id="$1"
    local pid
    pid=$(_project_id)

    local state_id="${PLANE_STATE_TODO:-}"
    if [ -z "$state_id" ]; then
        state_id=$(_state_id_by_group_or_name "$pid" "unstarted" "todo")
    fi

    _curl -X PATCH -d "{\"state\": \"$state_id\"}" \
        "$BASE/projects/$pid/issues/$issue_id/" | jq '{id, state, name}'
}

# List tasks currently in the Review state (filtered by PLANE_LABEL).
# Returns [{id, sequence_id, name, description_html}] — used by the loop's
# pre-iteration sweep to re-check each PR's test status.
cmd_list_review() {
    local pid
    pid=$(_project_id)

    local state_id="${PLANE_STATE_REVIEW:-}"
    if [ -z "$state_id" ]; then
        local states
        states=$(_states "$pid")
        state_id=$(echo "$states" | jq -r '
            .results[] |
            select(.name | ascii_downcase | contains("review")) |
            .id
        ' | head -1)
    fi
    if [ -z "$state_id" ]; then
        echo "ERROR: no review state found; set PLANE_STATE_REVIEW in .env" >&2
        exit 1
    fi

    local label_id=""
    if [ -n "${PLANE_LABEL:-}" ]; then
        if [[ "${PLANE_LABEL}" =~ ^[0-9a-f-]{36}$ ]]; then
            label_id="$PLANE_LABEL"
        else
            label_id=$(_curl "$BASE/projects/$pid/labels/" \
                | jq -r --arg name "$PLANE_LABEL" \
                '.results[] | select(.name | ascii_downcase == ($name | ascii_downcase)) | .id' \
                | head -1)
        fi
    fi

    local issues_tmp
    issues_tmp=$(mktemp)
    _curl "$BASE/projects/$pid/issues/?per_page=500&page=1" > "$issues_tmp"

    jq --arg state "$state_id" --arg lbl "$label_id" '
        .results |
        map(
            select(.state == $state) |
            if $lbl != "" then select(.labels | index($lbl) != null) else . end
        ) |
        sort_by(.sequence_id) |
        map({id, sequence_id, name, description_html})
    ' "$issues_tmp"
    rm -f "$issues_tmp"
}

# Append the branch tag to the description AND post it as a comment.
cmd_set_branch() {
    local issue_id="$1"
    local branch="$2"
    local pid
    pid=$(_project_id)

    local frag="<p>Branch: <code>${branch}</code></p>"
    local current_desc
    current_desc=$(_get_desc "$pid" "$issue_id")
    _patch_desc "$pid" "$issue_id" "${current_desc}${frag}"
    _post_comment "$pid" "$issue_id" "$frag"

    jq -n --arg id "$issue_id" --arg branch "$branch" '{id: $id, branch: $branch}'
}

# Append the PR link to the description AND post it as a comment.
cmd_set_pr() {
    local issue_id="$1"
    local pr_url="$2"
    local pid
    pid=$(_project_id)

    local frag="<p>PR: <a href=\"${pr_url}\">${pr_url}</a></p>"
    local current_desc
    current_desc=$(_get_desc "$pid" "$issue_id")
    _patch_desc "$pid" "$issue_id" "${current_desc}${frag}"
    _post_comment "$pid" "$issue_id" "$frag"

    jq -n --arg id "$issue_id" --arg pr "$pr_url" '{id: $id, pr: $pr}'
}

# Post a comment. The body must be HTML (a tag-less string is wrapped in <p>).
cmd_add_comment() {
    local issue_id="$1"
    local comment="$2"
    local pid
    pid=$(_project_id)

    _post_comment "$pid" "$issue_id" "$comment"
    jq -n --arg id "$issue_id" '{id: $id, ok: true}'
}

cmd_get_comments() {
    local issue_id="$1"
    local pid
    pid=$(_project_id)
    _curl "$BASE/projects/$pid/issues/$issue_id/comments/" \
        | jq '[.results[] | {
            id,
            body: (.comment_html // "" | gsub("<[^>]*>"; "") | gsub("^\\s+|\\s+$"; "")),
            images: [(.comment_html // "") | scan("<(?:image-component|img)[^>]*\\bsrc=\"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\"") | .[0]],
            created_at
        }] | sort_by(.created_at)'
}

cmd_update_description() {
    local issue_id="$1"
    local pid
    pid=$(_project_id)
    local desc_html
    desc_html=$(cat)
    local payload
    payload=$(jq -n --arg d "$desc_html" '{description_html: $d}')
    _curl -X PATCH -d "$payload" \
        "$BASE/projects/$pid/issues/$issue_id/" | jq '{id, name}'
}

# Append HTML (read from stdin) to the END of the existing description_html.
cmd_append_description() {
    local issue_id="$1"
    local pid
    pid=$(_project_id)
    local frag
    frag=$(cat)
    local current_desc
    current_desc=$(_get_desc "$pid" "$issue_id")
    _patch_desc "$pid" "$issue_id" "${current_desc}${frag}"
    jq -n --arg id "$issue_id" '{id: $id, ok: true}'
}

# Prepend HTML (read from stdin) to the START of the existing description_html.
cmd_prepend_description() {
    local issue_id="$1"
    local pid
    pid=$(_project_id)
    local frag
    frag=$(cat)
    local current_desc
    current_desc=$(_get_desc "$pid" "$issue_id")
    _patch_desc "$pid" "$issue_id" "${frag}${current_desc}"
    jq -n --arg id "$issue_id" '{id: $id, ok: true}'
}

cmd_done_in_period() {
    local from_date="${1:?from_date required (YYYY-MM-DD or ISO datetime)}"
    local to_date="${2:-}"
    local pid
    pid=$(_project_id)

    local states
    states=$(_states "$pid")

    # Find the "Done" state (completed group, name contains "done")
    local done_state_id
    done_state_id=$(echo "$states" | jq -r '
        .results[] |
        select(.group == "completed" and (.name | ascii_downcase | contains("done"))) |
        .id
    ' | head -1)

    if [ -z "$done_state_id" ]; then
        echo "ERROR: no Done state found in completed group" >&2
        exit 1
    fi

    # Normalize from_date to ISO datetime
    if [[ "$from_date" != *T* ]]; then
        from_date="${from_date}T00:00:00Z"
    fi

    # Normalize to_date (default: end of today)
    if [ -z "$to_date" ]; then
        to_date=$(date -u +"%Y-%m-%dT23:59:59Z")
    elif [[ "$to_date" != *T* ]]; then
        to_date="${to_date}T23:59:59Z"
    fi

    local issues_tmp
    issues_tmp=$(mktemp)
    _curl "$BASE/projects/$pid/issues/?per_page=500&page=1" > "$issues_tmp"

    jq --arg state "$done_state_id" --arg from "$from_date" --arg to "$to_date" '
        .results |
        map(
            select(.state == $state) |
            select(.updated_at >= $from and .updated_at <= $to)
        ) |
        sort_by(.updated_at) |
        map({id, sequence_id, name, priority, updated_at})
    ' "$issues_tmp"

    rm -f "$issues_tmp"
}

cmd_task_in_progress() {
    local pid
    pid=$(_project_id)

    local state_id="${PLANE_STATE_IN_PROGRESS:-}"
    if [ -z "$state_id" ]; then
        state_id=$(_state_id_by_group_or_name "$pid" "started" "in progress")
    fi

    local label_id=""
    if [ -n "${PLANE_LABEL:-}" ]; then
        if [[ "${PLANE_LABEL}" =~ ^[0-9a-f-]{36}$ ]]; then
            label_id="$PLANE_LABEL"
        else
            label_id=$(_curl "$BASE/projects/$pid/labels/" \
                | jq -r --arg name "$PLANE_LABEL" \
                '.results[] | select(.name | ascii_downcase == ($name | ascii_downcase)) | .id' \
                | head -1)
            if [ -z "$label_id" ]; then
                echo "ERROR: label \"$PLANE_LABEL\" not found in project" >&2
                exit 1
            fi
        fi
    fi

    local issues_tmp
    issues_tmp=$(mktemp)
    _curl "$BASE/projects/$pid/issues/?per_page=500&page=1" > "$issues_tmp"

    local next
    next=$(jq --arg state "$state_id" --arg lbl "$label_id" '
        .results |
        map(
            select(.state == $state) |
            if $lbl != "" then select(.labels | index($lbl) != null) else . end
        ) |
        sort_by(.updated_at) |
        first
    ' "$issues_tmp")
    rm -f "$issues_tmp"

    if [ -z "$next" ] || [ "$next" = "null" ]; then
        echo '{"done": true, "message": "no tasks in progress"}'
        exit 0
    fi

    local issue_id
    issue_id=$(echo "$next" | jq -r '.id')
    local comments
    comments=$(_curl "$BASE/projects/$pid/issues/$issue_id/comments/" \
        | jq '[.results[] | {
            id,
            body: (.comment_html // "" | gsub("<[^>]*>"; "") | gsub("^\\s+|\\s+$"; "")),
            images: [(.comment_html // "") | scan("<(?:image-component|img)[^>]*\\bsrc=\"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\"") | .[0]],
            created_at
        }] | sort_by(.created_at)')

    echo "$next" | jq \
        --argjson comments "$comments" \
        ". + {comments: \$comments} | $_STRIP_NOISE"
}

cmd_done_in_period() {
    local from_date="${1:?from_date required (YYYY-MM-DD or ISO datetime)}"
    local to_date="${2:-}"
    local pid
    pid=$(_project_id)

    local states
    states=$(_states "$pid")

    local done_state_id="${PLANE_STATE_DONE:-}"
    if [ -z "$done_state_id" ]; then
        done_state_id=$(echo "$states" | jq -r '
            .results[] |
            select(.group == "completed" and (.name | ascii_downcase | contains("done"))) |
            .id
        ' | head -1)
    fi

    if [ -z "$done_state_id" ]; then
        echo "ERROR: no Done state found in completed group" >&2
        exit 1
    fi

    if [[ "$from_date" != *T* ]]; then
        from_date="${from_date}T00:00:00Z"
    fi

    if [ -z "$to_date" ]; then
        to_date=$(date -u +"%Y-%m-%dT23:59:59Z")
    elif [[ "$to_date" != *T* ]]; then
        to_date="${to_date}T23:59:59Z"
    fi

    local issues_tmp
    issues_tmp=$(mktemp)
    _curl "$BASE/projects/$pid/issues/?per_page=500&page=1" > "$issues_tmp"

    jq --arg state "$done_state_id" --arg from "$from_date" --arg to "$to_date" '
        .results |
        map(
            select(.state == $state) |
            select(.updated_at >= $from and .updated_at <= $to)
        ) |
        sort_by(.updated_at) |
        map({id, sequence_id, name, priority, updated_at})
    ' "$issues_tmp"

    rm -f "$issues_tmp"
}

# Tasks currently in the Done, Review OR Cancelled state, updated within [from, to].
# Output is a grouped plain-text report (sequence_id - name), one task per line:
#   Done tasks:        (Done state)
#   Processing tasks:  (Review state)
#   Cancelled tasks:   (Cancelled state)
# NOTE: filters by *current* state + updated_at (same approach as done-in-period);
# it is not a true transition-history query. A task that passed through Review and
# then moved to Done in the window shows up once, under "Done tasks".
cmd_review_done_in_period() {
    local from_date="${1:?from_date required (YYYY-MM-DD or ISO datetime)}"
    local to_date="${2:-}"
    local pid
    pid=$(_project_id)

    local states
    states=$(_states "$pid")

    local done_state_id="${PLANE_STATE_DONE:-}"
    if [ -z "$done_state_id" ]; then
        done_state_id=$(echo "$states" | jq -r '
            .results[] |
            select(.group == "completed" and (.name | ascii_downcase | contains("done"))) |
            .id
        ' | head -1)
    fi

    local review_state_id="${PLANE_STATE_REVIEW:-}"
    if [ -z "$review_state_id" ]; then
        review_state_id=$(echo "$states" | jq -r '
            .results[] |
            select(.name | ascii_downcase | contains("review")) |
            .id
        ' | head -1)
    fi

    local cancelled_state_id="${PLANE_STATE_CANCELLED:-}"
    if [ -z "$cancelled_state_id" ]; then
        cancelled_state_id=$(echo "$states" | jq -r '
            .results[] |
            select(.group == "cancelled") |
            .id
        ' | head -1)
    fi

    if [ -z "$done_state_id" ] && [ -z "$review_state_id" ] && [ -z "$cancelled_state_id" ]; then
        echo "ERROR: no Done, Review or Cancelled state found" >&2
        exit 1
    fi

    if [[ "$from_date" != *T* ]]; then
        from_date="${from_date}T00:00:00Z"
    fi

    if [ -z "$to_date" ]; then
        to_date=$(date -u +"%Y-%m-%dT23:59:59Z")
    elif [[ "$to_date" != *T* ]]; then
        to_date="${to_date}T23:59:59Z"
    fi

    local issues_tmp
    issues_tmp=$(mktemp)
    _curl "$BASE/projects/$pid/issues/?per_page=500&page=1" > "$issues_tmp"

    jq -r --arg done "$done_state_id" --arg review "$review_state_id" --arg cancelled "$cancelled_state_id" \
       --arg from "$from_date" --arg to "$to_date" '
        .results
        | map(select(
            (.state == $done or .state == $review or .state == $cancelled)
            and .updated_at >= $from and .updated_at <= $to
        ))
        | (map(select(.state == $done))      | sort_by(.sequence_id)) as $d
        | (map(select(.state == $review))    | sort_by(.sequence_id)) as $r
        | (map(select(.state == $cancelled)) | sort_by(.sequence_id)) as $c
        | (
            ["Done tasks:"]         + ($d | map("- \(.sequence_id) - \(.name)"))
            + ["Processing tasks:"] + ($r | map("- \(.sequence_id) - \(.name)"))
            + ["Cancelled tasks:"]  + ($c | map("- \(.sequence_id) - \(.name)"))
          )
        | .[]
    ' "$issues_tmp"

    rm -f "$issues_tmp"
}

cmd_set_done() {
    local issue_id="$1"
    local pid
    pid=$(_project_id)

    local state_id="${PLANE_STATE_DONE:-}"
    if [ -z "$state_id" ]; then
        state_id=$(_state_id_by_group_or_name "$pid" "completed" "done")
    fi

    _curl -X PATCH -d "{\"state\": \"$state_id\"}" \
        "$BASE/projects/$pid/issues/$issue_id/" | jq '{id, state, name}'
}

cmd_set_cancelled() {
    local issue_id="$1"
    local pid
    pid=$(_project_id)

    local state_id="${PLANE_STATE_CANCELLED:-}"
    if [ -z "$state_id" ]; then
        local states
        states=$(_states "$pid")
        state_id=$(echo "$states" | jq -r '.results[] | select(.group == "cancelled") | .id' | head -1)
    fi

    if [ -z "$state_id" ]; then
        echo "ERROR: no cancelled state found; set PLANE_STATE_CANCELLED in .env" >&2
        exit 1
    fi

    _curl -X PATCH -d "{\"state\": \"$state_id\"}" \
        "$BASE/projects/$pid/issues/$issue_id/" | jq '{id, state, name}'
}

cmd_create_task() {
    local name="${1:?task name required}"
    local description="${2:-}"
    local priority="${3:-none}"
    local state_name="${4:-backlog}"
    local pid
    pid=$(_project_id)

    # Resolve state by name (backlog or todo)
    local state_id
    case "${state_name,,}" in
        todo)    state_id=$(_state_id_by_group_or_name "$pid" "unstarted" "todo") ;;
        backlog) state_id=$(_state_id_by_group_or_name "$pid" "backlog" "backlog") ;;
        *)
            echo "ERROR: unknown state \"$state_name\"; use backlog or todo" >&2
            exit 1
            ;;
    esac

    # Resolve label from PLANE_LABEL if set (UUID or name)
    local label_id=""
    if [ -n "${PLANE_LABEL:-}" ]; then
        if [[ "${PLANE_LABEL}" =~ ^[0-9a-f-]{36}$ ]]; then
            label_id="$PLANE_LABEL"
        else
            label_id=$(_curl "$BASE/projects/$pid/labels/" \
                | jq -r --arg n "$PLANE_LABEL" \
                '.results[] | select(.name | ascii_downcase == ($n | ascii_downcase)) | .id' \
                | head -1)
        fi
    fi

    local desc_html=""
    if [ -n "$description" ]; then
        desc_html="<p>$description</p>"
    fi

    local payload
    payload=$(jq -n \
        --arg name "$name" \
        --arg desc "$desc_html" \
        --arg priority "$priority" \
        --arg state "$state_id" \
        --arg lbl "$label_id" '
        {name: $name, priority: $priority, state: $state} +
        (if $desc != "" then {description_html: $desc} else {} end) +
        (if $lbl != "" then {labels: [$lbl]} else {} end)
    ')

    _curl -X POST -d "$payload" \
        "$BASE/projects/$pid/issues/" | jq '{id, sequence_id, name, priority, state}'
}

# Create a new page in the project. A plain-text description is wrapped in
# <p>; a string already containing tags is sent through as-is (HTML).
cmd_create_page() {
    local name="${1:?page name required}"
    local description="${2:-}"
    local pid
    pid=$(_project_id)

    local desc_html=""
    if [ -n "$description" ]; then
        if [[ "$description" != *"<"*">"* ]]; then
            desc_html="<p>${description}</p>"
        else
            desc_html="$description"
        fi
    fi

    local payload
    payload=$(jq -n \
        --arg name "$name" \
        --arg desc "$desc_html" '
        {name: $name} +
        (if $desc != "" then {description_html: $desc} else {} end)
    ')

    _curl -X POST -d "$payload" \
        "$BASE/projects/$pid/pages/" | jq '{id, name, access}'
}

cmd_get_page() {
    local page_id="${1:?page_id required}"
    local pid
    pid=$(_project_id)
    _curl "$BASE/projects/$pid/pages/$page_id/" | jq '.'
}

# Direct lookup of the project's main doc page via its known id, so the agent
# does not have to re-run search-pages (a fuzzy substring search, not an exact
# match) every iteration. Requires PLANE_MAIN_DOC_PAGE_ID in .env — see
# how-to-add-plane-pages.md for how that gets set the first time the main page
# is created.
cmd_main_page() {
    if [ -z "${PLANE_MAIN_DOC_PAGE_ID:-}" ]; then
        echo "ERROR: PLANE_MAIN_DOC_PAGE_ID not set in .env — run 'search-pages <project-name>' to find the main page (or create-page to make it), then add PLANE_MAIN_DOC_PAGE_ID=<id> to .env." >&2
        exit 1
    fi
    cmd_get_page "$PLANE_MAIN_DOC_PAGE_ID"
}

# Plane/PageDetail has no url/web_url field, so the web-app link has to be
# built by hand — used to link a newly created page from the main page (see
# how-to-add-plane-pages.md: every page must be linked from the main page).
cmd_page_url() {
    local page_id="${1:?page_id required}"
    local pid
    pid=$(_project_id)
    echo "https://$PLANE_HOST/$PLANE_USERNAME/projects/$pid/pages/$page_id/"
}

# Append HTML (read from stdin) to the END of a page's existing
# description_html — mirrors append-description for issues. Used to add a
# link to a newly created page onto the main page without having to fetch
# and resend its whole existing content by hand.
cmd_append_to_page() {
    local page_id="${1:?page_id required}"
    local pid
    pid=$(_project_id)
    local frag
    frag=$(cat)
    local current_desc
    current_desc=$(_curl "$BASE/projects/$pid/pages/$page_id/" | jq -r '.description_html // ""')
    local payload
    payload=$(jq -n --arg d "${current_desc}${frag}" '{description_html: $d}')
    _curl -X PATCH -d "$payload" "$BASE/projects/$pid/pages/$page_id/" \
        | jq '{id, name, description_html}'
}

# Patch a page's name and/or description_html. Either arg may be "" to leave
# that field untouched. A plain-text description is wrapped in <p>; a string
# already containing tags is sent through as-is (HTML).
cmd_edit_page() {
    local page_id="${1:?page_id required}"
    local name="${2:-}"
    local description="${3:-}"
    local pid
    pid=$(_project_id)

    local desc_html=""
    if [ -n "$description" ]; then
        if [[ "$description" != *"<"*">"* ]]; then
            desc_html="<p>${description}</p>"
        else
            desc_html="$description"
        fi
    fi

    local payload
    payload=$(jq -n \
        --arg name "$name" \
        --arg desc "$desc_html" '
        (if $name != "" then {name: $name} else {} end) +
        (if $desc != "" then {description_html: $desc} else {} end)
    ')

    if [ "$payload" = "{}" ]; then
        echo "ERROR: nothing to update — provide a name and/or description" >&2
        exit 1
    fi

    _curl -X PATCH -d "$payload" \
        "$BASE/projects/$pid/pages/$page_id/" | jq '{id, name, access, description_html}'
}

# Delete a page. Plane's API only allows deleting an already-archived page
# (400 "should be archived before deleting" otherwise) — use archive-page first.
cmd_remove_page() {
    local page_id="${1:?page_id required}"
    local pid
    pid=$(_project_id)
    _curl -X DELETE "$BASE/projects/$pid/pages/$page_id/" >/dev/null
    jq -n --arg id "$page_id" '{id: $id, deleted: true}'
}

# Archive a page (and its descendants). Required before remove-page will
# succeed. Only the page owner or a project admin can archive it.
cmd_archive_page() {
    local page_id="${1:?page_id required}"
    local pid
    pid=$(_project_id)
    _curl -X POST "$BASE/projects/$pid/pages/$page_id/archive/" \
        | jq --arg id "$page_id" '{id: $id, archived_at}'
}

# Unarchive a page (and its descendants). Only the page owner or a project
# admin can unarchive it.
cmd_unarchive_page() {
    local page_id="${1:?page_id required}"
    local pid
    pid=$(_project_id)
    _curl -X DELETE "$BASE/projects/$pid/pages/$page_id/archive/" >/dev/null
    jq -n --arg id "$page_id" '{id: $id, archived: false}'
}

# Server-side name search via the pages/search/ endpoint.
cmd_search_pages() {
    local query="${1:?search query required}"
    local pid
    pid=$(_project_id)
    _curl -G "$BASE/projects/$pid/pages/search/" --data-urlencode "search=$query" \
        | jq 'map({id, name, access, archived_at, updated_at})'
}

# Literal (non-regex) search/replace within a page's description_html.
# Uses jq split/join rather than gsub so regex metacharacters in the search
# string (., *, etc.) are matched literally.
cmd_replace_in_page() {
    local page_id="${1:?page_id required}"
    local search="${2:?search string required}"
    local replace="${3:-}"
    local pid
    pid=$(_project_id)

    local current_desc
    current_desc=$(_curl "$BASE/projects/$pid/pages/$page_id/" | jq -r '.description_html // ""')

    local count
    count=$(jq -n --arg d "$current_desc" --arg s "$search" '($d | split($s) | length) - 1')

    if [ "$count" -eq 0 ]; then
        echo "ERROR: search string not found in page $page_id" >&2
        exit 1
    fi

    local new_desc
    new_desc=$(jq -n -r --arg d "$current_desc" --arg s "$search" --arg r "$replace" '$d | split($s) | join($r)')

    local payload
    payload=$(jq -n --arg d "$new_desc" '{description_html: $d}')

    _curl -X PATCH -d "$payload" "$BASE/projects/$pid/pages/$page_id/" \
        | jq --argjson count "$count" '{id, name, replacements: $count}'
}

# Upload a file as an issue attachment and mark it uploaded, in one shot:
# create the attachment (presigned S3 POST), stream the file straight to that
# presigned URL, then PATCH is_uploaded=true. Prints {asset_id, embed_html} —
# splice embed_html into any HTML sent via add-comment / update-description /
# append-description / prepend-description to show the image inline. The src
# attribute of <image-component> is the asset UUID, not a literal URL
# (Plane's editor resolves it client-side).
#
# Goes through /issues/<id>/issue-attachments/ rather than the generic
# /assets/ endpoint — the generic endpoint returns HTTP 500 on this Plane
# instance regardless of payload (confirmed against two separate projects on
# 2026-07-12), while the per-issue attachments endpoint works.
cmd_upload_asset() {
    local file_path="${1:?file path required}"
    local issue_id="${2:?issue_id required}"
    local project_id="${3:-}"

    if [ ! -f "$file_path" ]; then
        echo "ERROR: file not found: $file_path" >&2
        exit 1
    fi
    if [ -z "$project_id" ]; then
        project_id=$(_project_id)
    fi

    local name size mime
    name=$(basename "$file_path")
    size=$(stat -c%s "$file_path" 2>/dev/null || stat -f%z "$file_path")
    mime=$(file -b --mime-type "$file_path")

    local payload
    payload=$(jq -n --arg name "$name" --arg type "$mime" --argjson size "$size" \
        '{name: $name, type: $type, size: $size}')

    local resp
    resp=$(_curl -X POST -d "$payload" "$BASE/projects/$project_id/issues/$issue_id/issue-attachments/")

    local asset_id upload_url
    asset_id=$(echo "$resp" | jq -r '.asset_id // empty')
    upload_url=$(echo "$resp" | jq -r '.upload_data.url // empty')

    if [ -z "$asset_id" ] || [ -z "$upload_url" ]; then
        echo "ERROR: failed to create attachment: $resp" >&2
        exit 1
    fi

    # S3 presigned POST: every policy field must be sent as its own form
    # field, in order, with the file itself last.
    local -a form_args=()
    while IFS=$'\t' read -r key value; do
        form_args+=(-F "${key}=${value}")
    done < <(echo "$resp" | jq -r '.upload_data.fields | to_entries[] | "\(.key)\t\(.value)"')

    curl -sf "${form_args[@]}" -F "file=@${file_path};type=${mime}" "$upload_url" -o /dev/null

    _curl -X PATCH -d '{"is_uploaded": true}' \
        "$BASE/projects/$project_id/issues/$issue_id/issue-attachments/${asset_id}/" >/dev/null

    local embed="<image-component src=\"${asset_id}\" width=\"35%\" height=\"auto\" alignment=\"left\"></image-component>"
    jq -n --arg id "$asset_id" --arg embed "$embed" '{asset_id: $id, embed_html: $embed}'
}

# Download an asset (e.g. an image embedded in a comment/description) to a
# local path so it can be viewed. The per-issue attachments endpoint responds
# with a redirect straight to the presigned download URL (no JSON envelope),
# unlike the generic /assets/<id>/ endpoint.
cmd_download_asset() {
    local asset_id="${1:?asset_id required}"
    local output_path="${2:?output_path required}"
    local issue_id="${3:?issue_id required}"
    local project_id="${4:-}"

    if [ -z "$project_id" ]; then
        project_id=$(_project_id)
    fi

    curl -sfL -H "X-API-Key: $PLANE_TOKEN" \
        "$BASE/projects/$project_id/issues/$issue_id/issue-attachments/${asset_id}/" \
        -o "$output_path"

    jq -n --arg path "$output_path" '{path: $path}'
}

# Scan an issue's description_html and all its comments' comment_html for
# embedded <image-component>/<img> asset ids (src holding a UUID), so the
# agent has one place to look before manually grepping HTML. Returns a JSON
# array of unique asset ids — pass each to download-asset to view it.
cmd_list_images() {
    local issue_id="${1:?issue_id required}"
    local pid
    pid=$(_project_id)

    local desc
    desc=$(_curl "$BASE/projects/$pid/issues/$issue_id/" | jq -r '.description_html // ""')
    local comments_html
    comments_html=$(_curl "$BASE/projects/$pid/issues/$issue_id/comments/" | jq -r '[.results[].comment_html // ""] | join(" ")')

    jq -n --arg d "$desc" --arg c "$comments_html" '
        ($d + " " + $c) as $html |
        [$html | scan("<(?:image-component|img)[^>]*\\bsrc=\"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\"") | .[0]] | unique
    '
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

CMD="${1:-}"
shift || true

case "$CMD" in
    next-task)           cmd_next_task ;;
    task-in-progress)    cmd_task_in_progress ;;
    set-in-progress)     cmd_set_in_progress "${1:?issue_id required}" ;;
    set-review)          cmd_set_review "${1:?issue_id required}" ;;
    set-todo)            cmd_set_todo "${1:?issue_id required}" ;;
    list-review)         cmd_list_review ;;
    set-done)            cmd_set_done "${1:?issue_id required}" ;;
    set-cancelled)       cmd_set_cancelled "${1:?issue_id required}" ;;
    set-branch)          cmd_set_branch "${1:?issue_id required}" "${2:?branch required}" ;;
    set-pr)              cmd_set_pr "${1:?issue_id required}" "${2:?pr_url required}" ;;
    add-comment)         cmd_add_comment "${1:?issue_id required}" "${2:?comment required}" ;;
    get-comments)        cmd_get_comments "${1:?issue_id required}" ;;
    update-description)  cmd_update_description "${1:?issue_id required}" ;;
    append-description)  cmd_append_description "${1:?issue_id required}" ;;
    prepend-description) cmd_prepend_description "${1:?issue_id required}" ;;
    create-task)         cmd_create_task "${1:?task name required}" "${2:-}" "${3:-none}" "${4:-backlog}" ;;
    create-page)         cmd_create_page "${1:?page name required}" "${2:-}" ;;
    main-page)            cmd_main_page ;;
    page-url)             cmd_page_url "${1:?page_id required}" ;;
    append-to-page)       cmd_append_to_page "${1:?page_id required}" ;;
    get-page)             cmd_get_page "${1:?page_id required}" ;;
    edit-page)            cmd_edit_page "${1:?page_id required}" "${2:-}" "${3:-}" ;;
    remove-page)          cmd_remove_page "${1:?page_id required}" ;;
    archive-page)         cmd_archive_page "${1:?page_id required}" ;;
    unarchive-page)       cmd_unarchive_page "${1:?page_id required}" ;;
    search-pages)         cmd_search_pages "${1:?search query required}" ;;
    replace-in-page)      cmd_replace_in_page "${1:?page_id required}" "${2:?search string required}" "${3:-}" ;;
    done-in-period)   cmd_done_in_period "${1:?from_date required}" "${2:-}" ;;
    review-done-in-period) cmd_review_done_in_period "${1:?from_date required}" "${2:-}" ;;
    get-issue)        cmd_get_issue "${1:?issue_id required}" ;;
    list-states)      cmd_list_states ;;
    list-projects)    cmd_list_projects ;;
    upload-asset)     cmd_upload_asset "${1:?file path required}" "${2:?issue_id required}" "${3:-}" ;;
    download-asset)   cmd_download_asset "${1:?asset_id required}" "${2:?output_path required}" "${3:?issue_id required}" "${4:-}" ;;
    list-images)      cmd_list_images "${1:?issue_id required}" ;;
    *)
        echo "Usage: $0 <command> [args]"
        echo "Commands: next-task | task-in-progress | set-in-progress <id> | set-review <id> | set-todo <id> | list-review | set-done <id> | set-cancelled <id> | set-branch <id> <branch> | set-pr <id> <pr_url> | add-comment <id> <html> | get-comments <id> | update-description <id> | append-description <id> | prepend-description <id> | create-task <name> [desc] [priority] [backlog|todo] | create-page <name> [desc_html] | main-page | page-url <id> | append-to-page <id> | get-page <id> | edit-page <id> [name] [desc_html] | remove-page <id> | archive-page <id> | unarchive-page <id> | search-pages <query> | replace-in-page <id> <search> <replace> | done-in-period <from> [<to>] | review-done-in-period <from> [<to>] | get-issue <id> | list-states | list-projects | upload-asset <file> <issue_id> [project_id] | download-asset <asset_id> <out_path> <issue_id> [project_id] | list-images <issue_id>"
        exit 1
        ;;
esac
