#!/usr/bin/env bash
# Plane.so API helper for the ralph-plane.sh workflow.
#
# Usage (run from repo root):
#   docs/plane.sh next-task                              — highest-priority Todo task + its comments (filtered by PLANE_LABEL)
#   docs/plane.sh set-in-progress <id>                   — move issue to "In Progress" state (automation-internal)
#   docs/plane.sh set-review <id>                        — move issue to "Review" state (automation-internal)
#   docs/plane.sh set-todo <id>                          — move issue back to "Todo" state (automation-internal)
#   docs/plane.sh set-label <id> <label>                  — replace an issue's labels with a single label (name or UUID) — e.g. to fix a task routed to the wrong sibling project
#   docs/plane.sh set-priority <id> <priority>            — change an existing issue's priority (urgent|high|medium|low|none) — e.g. an operator bumping a task via Telegram's /setpriority
#   docs/plane.sh list-review                            — Review-state tasks [{id,sequence_id,name,description_html}]
#   docs/plane.sh list-blocked                           — Todo tasks held back by an unresolved "Blocked by: #<seq>" reference, with each blocker's sequence_id/name/state/url and whether it is a plain (Done) or "(review)" gate; each blocked task also carries its own url. The read-only counterpart to next-task's blocker gate; evaluates blockers regardless of PLANE_RESPECT_BLOCKERS
#   docs/plane.sh add-comment <id> <html>                — post a comment on an issue (body must be HTML)
#   docs/plane.sh get-comments <id>                      — list all comments on an issue as JSON
#   docs/plane.sh update-description <id>                — replace description_html (reads new HTML from stdin)
#   docs/plane.sh append-description <id>                — append HTML to the end of description_html (reads from stdin)
#   docs/plane.sh prepend-description <id>               — prepend HTML to the start of description_html (reads from stdin)
#   docs/plane.sh set-branch <id> <branch>              — append branch tag to description AND post a comment
#   docs/plane.sh set-pr <id> <pr_url>                  — append PR link to description AND post a comment
#   docs/plane.sh task-in-progress                      — in-progress task (filtered by PLANE_LABEL); {"done":true} if none
#   docs/plane.sh create-task <name> [desc] [priority] [backlog|todo|pre-ai] [label] [link_from_id]  — create new issue; priority must be one of urgent, high, medium, low, none (default none) — any other value is rejected loudly; with link_from_id, appends a link to the new task onto that task's description; pre-ai targets a "Todo (pre-AI)"-style state for a task that needs operator triage before an agent should pick it up
#   docs/plane.sh task-url <id>                          — print an issue's web-app URL (for linking it from a comment/description)
#   docs/plane.sh create-page <name> [desc_html|@file]   — create new project page (@file reads desc from a file)
#   docs/plane.sh main-page [page_name] [env_key]         — get a root doc page by env_key (default PLANE_MAIN_DOC_PAGE_ID), creating it (named page_name) if it does not exist yet; response includes just_created: true/false. Pass a distinct env_key to track more than one root (e.g. separate dev/user doc hierarchies).
#   docs/plane.sh page-url <id>                          — print the page's web-app URL (for linking it from another page)
#   docs/plane.sh get-page <id> [out_file]               — print full page JSON; with out_file, write description_html to it instead
#   docs/plane.sh edit-page <id> [name] [desc_html|@file] — patch a page's name and/or description (pass "" to skip one; @file reads desc from a file)
#   docs/plane.sh rename-page <id> <name>                 — rename a page without touching its description
#   docs/plane.sh remove-page <id>                       — delete a page (must be archived first — see archive-page)
#   docs/plane.sh archive-page <id>                      — archive a page (and descendants); required before remove-page
#   docs/plane.sh unarchive-page <id>                    — unarchive a page (and descendants)
#   docs/plane.sh search-pages <query>                   — server-side search for pages by name
#   docs/plane.sh done-in-period <from> [<to>]          — list tasks in Done state updated within a date range
#   docs/plane.sh review-done-in-period <from> [<to>]   — grouped text report of Done/Processing/Cancelled tasks updated within a range
#   docs/plane.sh set-done <id>                          — move issue to Done (operator-triggered only)
#   docs/plane.sh set-cancelled <id>                     — move issue to Cancelled (operator-triggered only)
#   docs/plane.sh get-issue <id>                         — print full issue JSON
#   docs/plane.sh get-task <PROJECT-123>                 — look up an issue by its human-readable ref (e.g. TM-808) and print full issue JSON + comments
#   docs/plane.sh list-states                            — print all project states
#   docs/plane.sh list-labels                            — print all project labels [{id,name}] (e.g. to find a sibling project's label for create-task)
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
#                   PLANE_MAIN_DOC_PAGE_ID  (id of the project's main Plane doc page, used by main-page as its
#                                            default env_key; empty until the page has been created once — see
#                                            how-to-add-plane-pages.md. Projects with more than one doc hierarchy
#                                            use additional PLANE_*_PAGE_ID keys instead, passed explicitly to
#                                            main-page — e.g. PLANE_DEV_DOCS_PAGE_ID/PLANE_USER_DOCS_PAGE_ID)
#                   PLANE_STATE_IN_PROGRESS (default: searches by name "In Progress" in started group)
#                   PLANE_STATE_REVIEW      (default: searches by name containing "review")
#                   PLANE_STATE_DONE        (default: searches completed group for name "done")
#                   PLANE_STATE_CANCELLED   (default: first state in cancelled group)
#                   PLANE_LABEL             (name or UUID; next-task/task-in-progress/list-blocked only return issues with this
#                                            label. Set but unresolvable is a HARD ERROR, not a silently-dropped filter — a
#                                            loop on a shared board must never fall back to seeing every project's tasks)
#                   PLANE_RESPECT_BLOCKERS  (1 to skip next-task candidates blocked by an unresolved "Blocked by: #<seq>" reference;
#                                            add "(review)" — e.g. "Blocked by: #<seq> (review)" — to resolve as soon as the
#                                            blocker reaches a Review-named state instead of waiting for Done/Cancelled)
#                   PLANE_ASSIGNEE_ID       (member UUID; create-task assigns every new task to this member. Absent = no
#                                            assignee set, same as before this key existed)

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
    curl -sS --fail-with-body -H "X-API-Key: $PLANE_TOKEN" -H "Content-Type: application/json" "$@"
}

# If $1 starts with "@", read and print the rest as a file path; otherwise
# print $1 unchanged. Mirrors curl's -d @file convention.
_resolve_at_file() {
    local val="$1"
    if [[ "$val" == @* ]]; then
        local f="${val#@}"
        if [ ! -f "$f" ]; then
            echo "ERROR: file not found: $f" >&2
            exit 1
        fi
        cat "$f"
    else
        echo -n "$val"
    fi
}

# Build a jq payload that embeds a (possibly large) description_html value
# without going through argv: Linux caps a single argv/environ string at
# MAX_ARG_STRLEN (128 KiB), so `jq -n --arg desc "$big_html"` fails with
# "Argument list too long" once a page description crosses that size — write
# it to a temp file and read it back with --rawfile instead. Extra jq args
# (e.g. --arg name "$name") and the filter string are forwarded as-is; the
# filter refers to the description value as $desc.
_jq_with_desc() {
    local desc_html="$1"; shift
    local tmp
    tmp=$(mktemp)
    trap 'rm -f "$tmp"' RETURN
    printf '%s' "$desc_html" > "$tmp"
    jq -n --rawfile desc "$tmp" "$@"
}

# Update or append KEY=VALUE in .env, so a value discovered at runtime
# (e.g. a newly created page's id) persists for the next loop iteration
# without a separate manual edit step.
_persist_env_key() {
    local key="$1" value="$2"
    if [ -f .env ] && grep -q "^${key}=" .env; then
        sed -i "s|^${key}=.*|${key}=${value}|" .env
    else
        echo "${key}=${value}" >> .env
    fi
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
    # Exact name match wins first — a project can have more than one state in
    # the same group whose name contains the hint (e.g. "Todo" AND "Todo
    # (pre-AI)" both contain "todo"), and a plain substring match picks
    # whichever the API happens to return first, which is not reliably the
    # plain one. Only fall back to substring matching if no exact match exists.
    id=$(echo "$states" | jq -r --arg g "$group" --arg n "$name_hint" '
        .results[] |
        if (.group == $g and (.name | ascii_downcase) == ($n | ascii_downcase)) then .id
        else empty end
    ' | head -1)
    if [ -z "$id" ]; then
        id=$(echo "$states" | jq -r --arg g "$group" --arg n "$name_hint" '
            .results[] |
            if (.group == $g and (.name | ascii_downcase | contains($n | ascii_downcase))) then .id
            else empty end
        ' | head -1)
    fi
    if [ -z "$id" ]; then
        id=$(echo "$states" | jq -r --arg g "$group" '.results[] | select(.group == $g) | .id' | head -1)
    fi
    if [ -z "$id" ]; then
        echo "ERROR: no state found for group=$group / name_hint=$name_hint" >&2
        exit 1
    fi
    echo "$id"
}

# Resolve a label's id by exact case-insensitive name match, or pass a UUID
# straight through. Prints nothing if not found — callers decide whether
# that is an error. per_page=200 avoids silently missing a label past page 1
# on a project with many labels (e.g. a shared multi-project board).
_label_id_by_name() {
    local pid="$1" name_or_id="$2"
    if [[ "$name_or_id" =~ ^[0-9a-f-]{36}$ ]]; then
        echo "$name_or_id"
        return
    fi
    _curl "$BASE/projects/$pid/labels/?per_page=200" \
        | jq -r --arg n "$name_or_id" \
        '.results[] | select(.name | ascii_downcase == ($n | ascii_downcase)) | .id' \
        | head -1
}

# Fetch every issue in the project, following the API's own cursor pagination,
# and print a single {"results": [...]} object (the shape every caller's jq
# filter already expects).
#
# $1 = project id
# $2 = comma-separated `fields=` projection. Include every key the caller's jq
#      filter reads — a key left out of the projection is absent from the
#      response, not null.
#
# Two API behaviours this works around, both measured live against
# tasks.jobscanner.pro on 2026-08-27 (Plane task TM-1450):
#
#   - `page=` is ignored by this Plane version. `page=1`, `page=2` and `page=3`
#     all return the identical newest-`per_page` window, so the previous
#     `?per_page=500&page=1` call could only ever see the newest 500 issues of
#     a project. On a 1393-issue board that made every Todo older than that
#     window permanently invisible to `next-task`. Real pagination is the
#     `next_cursor` string the response carries (e.g. "500:1:0"), fed back as
#     `?cursor=`; `next_page_results` says whether another page exists.
#
#   - There is NO server-side filtering. `state=`, `labels=` and `state__id=`
#     are all silently accepted and ignored (`total_count` stays at the full
#     project count), so state/label filtering has to remain client-side —
#     do not "optimise" a caller by moving its jq `select` into the query
#     string. What the API *does* honour is `fields=`, a server-side
#     projection, and that is the whole reason full pagination is affordable:
#     dropping `description_html` alone takes a 500-row page from 3.8 MB /21s
#     to 130 KB /12s, so reading all 1393 rows costs about 30s in total
#     instead of the ~90s the fat projection would have needed. It also makes
#     a Cloudflare 524 on the call much less likely (see v64).
_all_issues() {
    local pid="$1" fields="$2"
    local per_page="${PLANE_PAGE_SIZE:-1000}"
    local max_pages="${PLANE_MAX_PAGES:-20}"
    local cursor="" url page pages=0
    local tmp
    tmp=$(mktemp)
    while :; do
        url="$BASE/projects/$pid/issues/?per_page=${per_page}&fields=${fields}"
        [ -n "$cursor" ] && url="${url}&cursor=${cursor}"
        page=$(_curl "$url")
        printf '%s\n' "$page" >> "$tmp"
        pages=$((pages + 1))
        [ "$(printf '%s' "$page" | jq -r '.next_page_results // false')" = "true" ] || break
        cursor=$(printf '%s' "$page" | jq -r '.next_cursor // empty')
        [ -n "$cursor" ] || break
        if [ "$pages" -ge "$max_pages" ]; then
            echo "WARNING: stopped after $pages pages (PLANE_MAX_PAGES=$max_pages) — some issues were not read" >&2
            break
        fi
    done
    jq -s '{results: (map(.results // []) | add // [])}' "$tmp"
    rm -f "$tmp"
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

cmd_list_labels() {
    local pid
    pid=$(_project_id)
    _curl "$BASE/projects/$pid/labels/?per_page=200" | jq '[.results[] | {id, name}]'
}

cmd_get_issue() {
    local issue_id="$1"
    local pid
    pid=$(_project_id)
    _curl "$BASE/projects/$pid/issues/$issue_id/" | jq "$_STRIP_NOISE"
}

# Look up an issue by its human-readable ref (project identifier + sequence
# id, e.g. "TM-808" — the form shown in the Plane UI/URLs), as opposed to
# get-issue which takes the internal UUID. Resolves the project by matching
# the ref's prefix against each project's identifier (falls back to the
# configured/default project if no match is found, in case the ref's prefix
# does not correspond to a project identifier), then scans that project's
# issues for a matching sequence_id. Output shape matches next-task: full
# issue JSON plus its comments.
cmd_get_task() {
    local task_ref="$1"
    if [[ ! "$task_ref" =~ ^([A-Za-z]+)-?([0-9]+)$ ]]; then
        echo "ERROR: task ref must look like TM-808" >&2
        exit 1
    fi
    local ident="${BASH_REMATCH[1]}"
    local seq="${BASH_REMATCH[2]}"

    local pid
    pid=$(_curl "$BASE/projects/" \
        | jq -r --arg i "$ident" '.results[] | select(.identifier != null and (.identifier | ascii_upcase) == ($i | ascii_upcase)) | .id' \
        | head -1)
    if [ -z "$pid" ]; then
        pid=$(_project_id)
    fi

    local issues_tmp
    issues_tmp=$(mktemp)
    _all_issues "$pid" "id,sequence_id" > "$issues_tmp"

    local issue_id
    issue_id=$(jq -r --argjson seq "$seq" '.results[] | select(.sequence_id == $seq) | .id' "$issues_tmp" | head -1)
    rm -f "$issues_tmp"

    if [ -z "$issue_id" ]; then
        echo "ERROR: task $task_ref not found" >&2
        exit 1
    fi

    _issue_with_comments "$pid" "$issue_id"
}

# Shared by next-task, list-blocked and (for its own state filter) task-in-progress:
# the comma-separated list of Todo state ids, from PLANE_STATE_TODO when set,
# otherwise every state in the "unstarted" group (Backlog is staging, not ready
# to implement, and lives in its own group).
_todo_state_ids() {
    local states="$1"
    if [ -n "${PLANE_STATE_TODO:-}" ]; then
        printf '%s' "$PLANE_STATE_TODO"
        return
    fi
    local ids
    ids=$(echo "$states" | jq -r '.results[] | select(.group == "unstarted") | .id' | tr '\n' ',')
    printf '%s' "${ids%,}"
}

# Resolve PLANE_LABEL to a label id, or print nothing when PLANE_LABEL is unset.
# A set-but-unresolvable label is a hard error: silently dropping the filter
# would make a project's loop pick up every other project's tasks off a shared
# board (see the onboarding notes in CLAUDE.md).
_required_label_id() {
    local pid="$1"
    [ -n "${PLANE_LABEL:-}" ] || return 0
    local label_id
    label_id=$(_label_id_by_name "$pid" "$PLANE_LABEL")
    if [ -z "$label_id" ]; then
        echo "ERROR: label \"$PLANE_LABEL\" not found in project" >&2
        exit 1
    fi
    printf '%s' "$label_id"
}

# jq program shared by next-task and list-blocked. Given a candidate issue's
# description_html (as $desc), the seq -> state map ($seqmap) and the two
# resolved-state id lists, emit {blocked: bool, blockers: [{id, review, state,
# resolved}]}.
#
# Plane's v1 API does not expose issue-relations (blocked_by/blocking) at all,
# so this approximates them via a text convention — "Blocked by: #<sequence_id>"
# in description_html. By default a reference resolves only once the blocker
# reaches a completed/cancelled state (i.e. Done); appending "(review)" — e.g.
# "Blocked by: #<sequence_id> (review)" — loosens that single reference to
# resolve as soon as the blocker reaches a state whose name contains "review"
# (Done also satisfies it, since Done implies past review). A referenced
# sequence_id that cannot be found among the fetched issues fails open (not
# blocking), since it is more likely a stale/typo'd reference than a real gate.
_BLOCKER_JQ='
    def blocked_refs:
        [scan("(?i)blocked[- ]by:?\\s*#?([0-9]+)(?:\\s*\\(?(review)\\)?)?")] |
        map({id: (.[0] | tonumber), review: (.[1] != null)});
    ($desc | blocked_refs)
    | map(. + {state: $seqmap[.id | tostring]})
    | map(select(.state != null))
    | map(. as $b | $b + {resolved: ((if $b.review then $resolved_review else $resolved end) | index($b.state) != null)})
    | {blocked: (map(.resolved) | all | not), blockers: .}
'

# Fetch an issue by id and append its comments, as next-task/task-in-progress
# both return it. Kept separate from cmd_get_issue so the two selection paths
# stay one function call away from the exact response shape the loop injects.
_issue_with_comments() {
    local pid="$1" issue_id="$2"
    local comments
    comments=$(_curl "$BASE/projects/$pid/issues/$issue_id/comments/" \
        | jq '[.results[] | {
            id,
            body: (.comment_html // "" | gsub("<[^>]*>"; "") | gsub("^\\s+|\\s+$"; "")),
            images: [(.comment_html // "") | scan("<(?:image-component|img)[^>]*\\bsrc=\"([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\"") | .[0]],
            created_at
        }] | sort_by(.created_at)')

    _curl "$BASE/projects/$pid/issues/$issue_id/" | jq \
        --argjson comments "$comments" \
        ". + {comments: \$comments} | $_STRIP_NOISE"
}

cmd_next_task() {
    local pid
    pid=$(_project_id)

    # Fetched unconditionally: needed both for todo-state resolution below and,
    # when PLANE_RESPECT_BLOCKERS=1, to resolve which states count as "done".
    local states
    states=$(_states "$pid")

    local todo_ids
    todo_ids=$(_todo_state_ids "$states")
    if [ -z "$todo_ids" ]; then
        echo '{"error": "no todo states found"}' >&2
        exit 1
    fi

    local label_id
    label_id=$(_required_label_id "$pid")

    # Lean projection on purpose: description_html is NOT fetched for the whole
    # board (that is what made this call 3.8 MB / 20-55s and prone to Cloudflare
    # 524s). It is read per candidate below, and only until one is pickable.
    local issues_tmp
    issues_tmp=$(mktemp)
    _all_issues "$pid" "id,sequence_id,state,labels,priority" > "$issues_tmp"

    # Filter to todo states + optional label, sort by priority
    local priority_order='{"urgent":0,"high":1,"medium":2,"low":3,"none":4}'
    local candidate_ids
    candidate_ids=$(jq -r --argjson order "$priority_order" --arg ids "$todo_ids" --arg lbl "$label_id" '
        .results |
        map(
            select(.state as $s | ($ids | split(",")) | index($s) != null) |
            if $lbl != "" then select(.labels | index($lbl) != null) else . end
        ) |
        sort_by($order[.priority] // 5) |
        .[].id
    ' "$issues_tmp")

    if [ -z "$candidate_ids" ]; then
        rm -f "$issues_tmp"
        echo '{"done": true, "message": "no tasks in todo states"}'
        exit 0
    fi

    if [ "${PLANE_RESPECT_BLOCKERS:-0}" != "1" ]; then
        rm -f "$issues_tmp"
        _issue_with_comments "$pid" "$(printf '%s' "$candidate_ids" | head -1)"
        return
    fi

    local resolved_ids resolved_review_ids seq_to_state
    resolved_ids=$(echo "$states" | jq -c '[.results[] | select(.group == "completed" or .group == "cancelled") | .id]')
    resolved_review_ids=$(echo "$states" | jq -c '[.results[] | select(.group == "completed" or .group == "cancelled" or (.name | test("review"; "i"))) | .id]')
    seq_to_state=$(jq -c '[.results[] | {(.sequence_id | tostring): .state}] | add // {}' "$issues_tmp")
    rm -f "$issues_tmp"

    # Walk candidates highest-priority-first, reading each one's description
    # only until an unblocked one is found — the winner's description is needed
    # for the response anyway, so nothing is fetched twice.
    local id desc blocked
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        desc=$(_get_desc "$pid" "$id")
        blocked=$(jq -n --arg desc "$desc" --argjson seqmap "$seq_to_state" \
            --argjson resolved "$resolved_ids" --argjson resolved_review "$resolved_review_ids" \
            "$_BLOCKER_JQ | .blocked")
        if [ "$blocked" != "true" ]; then
            _issue_with_comments "$pid" "$id"
            return
        fi
    done <<< "$candidate_ids"

    echo '{"done": true, "message": "all candidate tasks are blocked by unresolved dependencies"}'
    exit 0
}

# Todo tasks held back by an unresolved "Blocked by: #<seq>" reference, with
# each blocker's sequence_id, state and whether it is a "(review)" gate. This
# is the read-only counterpart to next-task's blocker gate: when next-task says
# "all candidate tasks are blocked by unresolved dependencies", this says which
# tasks and what they are waiting on. Unlike next-task it always evaluates
# blockers, whatever PLANE_RESPECT_BLOCKERS is set to.
cmd_list_blocked() {
    local pid
    pid=$(_project_id)

    local states
    states=$(_states "$pid")

    local todo_ids
    todo_ids=$(_todo_state_ids "$states")
    if [ -z "$todo_ids" ]; then
        echo '{"error": "no todo states found"}' >&2
        exit 1
    fi

    local label_id
    label_id=$(_required_label_id "$pid")

    local issues_tmp
    issues_tmp=$(mktemp)
    _all_issues "$pid" "id,sequence_id,name,state,labels,priority" > "$issues_tmp"

    local resolved_ids resolved_review_ids seq_to_state seq_to_name seq_to_id state_names url_prefix
    resolved_ids=$(echo "$states" | jq -c '[.results[] | select(.group == "completed" or .group == "cancelled") | .id]')
    resolved_review_ids=$(echo "$states" | jq -c '[.results[] | select(.group == "completed" or .group == "cancelled" or (.name | test("review"; "i"))) | .id]')
    seq_to_state=$(jq -c '[.results[] | {(.sequence_id | tostring): .state}] | add // {}' "$issues_tmp")
    seq_to_name=$(jq -c '[.results[] | {(.sequence_id | tostring): .name}] | add // {}' "$issues_tmp")
    seq_to_id=$(jq -c '[.results[] | {(.sequence_id | tostring): .id}] | add // {}' "$issues_tmp")
    state_names=$(echo "$states" | jq -c '[.results[] | {(.id): .name}] | add // {}')
    # Same shape as cmd_task_url, built inline so every entry/blocker below
    # can carry a ready-to-click link without a per-row task-url call.
    url_prefix="https://$PLANE_HOST/$PLANE_USERNAME/projects/$pid/issues/"

    local candidates
    candidates=$(jq -c --arg ids "$todo_ids" --arg lbl "$label_id" '
        .results |
        map(
            select(.state as $s | ($ids | split(",")) | index($s) != null) |
            if $lbl != "" then select(.labels | index($lbl) != null) else . end
        ) |
        map({id, sequence_id, name, priority})
    ' "$issues_tmp")
    rm -f "$issues_tmp"

    local out="[]" id seq name priority desc verdict entry
    while IFS=$'\t' read -r id seq name priority; do
        [ -n "$id" ] || continue
        desc=$(_get_desc "$pid" "$id")
        verdict=$(jq -n --arg desc "$desc" --argjson seqmap "$seq_to_state" \
            --argjson resolved "$resolved_ids" --argjson resolved_review "$resolved_review_ids" \
            "$_BLOCKER_JQ")
        [ "$(printf '%s' "$verdict" | jq -r '.blocked')" = "true" ] || continue
        entry=$(jq -n --arg id "$id" --argjson seq "$seq" --arg name "$name" --arg priority "$priority" \
            --arg urlprefix "$url_prefix" \
            --argjson verdict "$verdict" --argjson names "$seq_to_name" --argjson snames "$state_names" --argjson ids "$seq_to_id" '
            {
                id: $id, sequence_id: $seq, name: $name, priority: $priority,
                url: ($urlprefix + $id + "/"),
                blocked_by: ($verdict.blockers | map(
                    (.id | tostring) as $bseq |
                    {
                        sequence_id: .id,
                        name: ($names[$bseq] // null),
                        state: ($snames[.state] // .state),
                        gate: (if .review then "review" else "done" end),
                        resolved: .resolved,
                        url: (if $ids[$bseq] then ($urlprefix + $ids[$bseq] + "/") else null end)
                    }
                ))
            }')
        out=$(jq -c -n --argjson acc "$out" --argjson e "$entry" '$acc + [$e]')
    done < <(printf '%s' "$candidates" | jq -r '.[] | [.id, .sequence_id, .name, .priority] | @tsv')

    printf '%s\n' "$out" | jq '.'
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

# Replace an existing issue's labels with a single label (name or UUID) —
# e.g. to correct a task that was routed to the wrong sibling project after
# the fact, without having to recreate it.
cmd_set_label() {
    local issue_id="${1:?issue_id required}"
    local label_source="${2:?label required}"
    local pid
    pid=$(_project_id)

    local label_id
    label_id=$(_label_id_by_name "$pid" "$label_source")
    if [ -z "$label_id" ]; then
        echo "ERROR: label \"$label_source\" not found in project" >&2
        exit 1
    fi

    _curl -X PATCH -d "{\"labels\": [\"$label_id\"]}" \
        "$BASE/projects/$pid/issues/$issue_id/" | jq '{id, labels, name}'
}

# Change an existing issue's priority after the fact — e.g. an operator
# triaging via Telegram's /setpriority bumping a task ahead of the queue.
# Same priority vocabulary/rejection as create-task's 3rd arg.
cmd_set_priority() {
    local issue_id="${1:?issue_id required}"
    local priority="${2:?priority required}"
    local pid
    pid=$(_project_id)

    case "${priority,,}" in
        urgent|high|medium|low|none) priority="${priority,,}" ;;
        *)
            echo "ERROR: unknown priority \"$priority\"; use one of urgent, high, medium, low, none" >&2
            exit 1
            ;;
    esac

    _curl -X PATCH -d "{\"priority\": \"$priority\"}" \
        "$BASE/projects/$pid/issues/$issue_id/" | jq '{id, sequence_id, name, priority}'
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
        label_id=$(_label_id_by_name "$pid" "$PLANE_LABEL")
    fi

    # Lean bulk read, then one description fetch per Review task. Review is a
    # small set (single digits in practice) while the whole board is >1000
    # issues, so pulling description_html for every issue just to read a
    # handful of them was what made this call multi-megabyte — and
    # ralph-plane.sh runs it once per iteration in sweep_failed_tests.
    local issues_tmp
    issues_tmp=$(mktemp)
    _all_issues "$pid" "id,sequence_id,name,state,labels" > "$issues_tmp"

    local rows
    rows=$(jq -r --arg state "$state_id" --arg lbl "$label_id" '
        .results |
        map(
            select(.state == $state) |
            if $lbl != "" then select(.labels | index($lbl) != null) else . end
        ) |
        sort_by(.sequence_id) |
        .[] | [.id, .sequence_id, .name] | @tsv
    ' "$issues_tmp")
    rm -f "$issues_tmp"

    local out="[]" id seq name desc
    while IFS=$'\t' read -r id seq name; do
        [ -n "$id" ] || continue
        desc=$(_get_desc "$pid" "$id")
        out=$(jq -c -n --argjson acc "$out" --arg id "$id" --argjson seq "$seq" \
            --arg name "$name" --arg desc "$desc" \
            '$acc + [{id: $id, sequence_id: $seq, name: $name, description_html: $desc}]')
    done <<< "$rows"

    printf '%s\n' "$out" | jq '.'
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

cmd_task_in_progress() {
    local pid
    pid=$(_project_id)

    local state_id="${PLANE_STATE_IN_PROGRESS:-}"
    if [ -z "$state_id" ]; then
        state_id=$(_state_id_by_group_or_name "$pid" "started" "in progress")
    fi

    local label_id=""
    if [ -n "${PLANE_LABEL:-}" ]; then
        label_id=$(_label_id_by_name "$pid" "$PLANE_LABEL")
        if [ -z "$label_id" ]; then
            echo "ERROR: label \"$PLANE_LABEL\" not found in project" >&2
            exit 1
        fi
    fi

    local issues_tmp
    issues_tmp=$(mktemp)
    _all_issues "$pid" "id,sequence_id,state,labels,updated_at" > "$issues_tmp"

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

    # The bulk read above uses a lean fields= projection (no description_html,
    # no name), so the full issue is re-read by id here rather than returned
    # straight from the dump.
    _issue_with_comments "$pid" "$(echo "$next" | jq -r '.id')"
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
    _all_issues "$pid" "id,sequence_id,name,priority,state,updated_at" > "$issues_tmp"

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
    _all_issues "$pid" "id,sequence_id,name,state,updated_at" > "$issues_tmp"

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

cmd_task_url() {
    local issue_id="${1:?issue_id required}"
    local pid
    pid=$(_project_id)
    echo "https://$PLANE_HOST/$PLANE_USERNAME/projects/$pid/issues/$issue_id/"
}

cmd_create_task() {
    local name="${1:?task name required}"
    local description="${2:-}"
    local priority="${3:-none}"
    local state_name="${4:-backlog}"
    local label_override="${5:-}"
    local link_from_id="${6:-}"
    local pid
    pid=$(_project_id)

    case "${priority,,}" in
        urgent|high|medium|low|none) priority="${priority,,}" ;;
        *)
            echo "ERROR: unknown priority \"$priority\"; use one of urgent, high, medium, low, none" >&2
            exit 1
            ;;
    esac

    # Resolve state by name (backlog, todo, or pre-ai). "todo" checks
    # PLANE_STATE_TODO first, same as set-todo/next-task — without this,
    # create-task fell back to a bare group+name-hint lookup even on a project
    # where PLANE_STATE_TODO is already configured specifically because that
    # project's states don't resolve reliably by name alone (e.g. more than
    # one "unstarted" state whose name contains "todo"). "pre-ai" is the same
    # idea for a project whose board has a distinct "Todo (pre-AI)"-style
    # state for tasks that need operator triage before an agent picks them
    # up — PLANE_STATE_PRE_AI_TODO is optional since the "pre-ai" name hint
    # does not collide with "todo"'s substring-match ambiguity above.
    local state_id
    case "${state_name,,}" in
        todo)
            state_id="${PLANE_STATE_TODO:-}"
            [ -z "$state_id" ] && state_id=$(_state_id_by_group_or_name "$pid" "unstarted" "todo")
            ;;
        pre-ai)
            state_id="${PLANE_STATE_PRE_AI_TODO:-}"
            [ -z "$state_id" ] && state_id=$(_state_id_by_group_or_name "$pid" "unstarted" "pre-ai")
            ;;
        backlog) state_id=$(_state_id_by_group_or_name "$pid" "backlog" "backlog") ;;
        *)
            echo "ERROR: unknown state \"$state_name\"; use backlog, todo, or pre-ai" >&2
            exit 1
            ;;
    esac

    # Resolve label: an explicit 5th arg wins (for a task meant for a sibling
    # project that shares this Plane project's board, e.g. a php-labeled task
    # filed from the python-labeled loop's own PLANE_LABEL); otherwise falls
    # back to this project's own PLANE_LABEL, if set (UUID or name either way).
    # An explicit label that cannot be resolved is an error, not a silent
    # unlabeled/mislabeled task — that is exactly the "wrong project's label"
    # failure mode this arg exists to prevent.
    local label_source="${label_override:-${PLANE_LABEL:-}}"
    local label_id=""
    if [ -n "$label_source" ]; then
        label_id=$(_label_id_by_name "$pid" "$label_source")
        if [ -z "$label_id" ]; then
            echo "ERROR: label \"$label_source\" not found in project" >&2
            exit 1
        fi
    fi

    local desc_html=""
    if [ -n "$description" ]; then
        desc_html="<p>$description</p>"
    fi

    # Every new task is assigned to PLANE_ASSIGNEE_ID (the operator's member UUID)
    # when configured, so tasks the agent files never sit unassigned. Absent =
    # no assignee, same behavior as before this key existed.
    local payload
    payload=$(jq -n \
        --arg name "$name" \
        --arg desc "$desc_html" \
        --arg priority "$priority" \
        --arg state "$state_id" \
        --arg lbl "$label_id" \
        --arg assignee "${PLANE_ASSIGNEE_ID:-}" '
        {name: $name, priority: $priority, state: $state} +
        (if $desc != "" then {description_html: $desc} else {} end) +
        (if $lbl != "" then {labels: [$lbl]} else {} end) +
        (if $assignee != "" then {assignees: [$assignee]} else {} end)
    ')

    local result
    result=$(_curl -X POST -d "$payload" "$BASE/projects/$pid/issues/")

    # Auto-link: if a 6th arg (the calling task's own id) was passed, append
    # a clickable link to the newly created task onto that task's description
    # — the fiddly part of "create a related task" (build the URL, append the
    # HTML) so the agent does not have to do it as a separate manual step.
    if [ -n "$link_from_id" ]; then
        local new_id new_seq new_name new_url link_html
        new_id=$(echo "$result" | jq -r '.id')
        new_seq=$(echo "$result" | jq -r '.sequence_id')
        new_name=$(echo "$result" | jq -r '.name')
        new_url=$(cmd_task_url "$new_id")
        link_html=$(jq -rn --arg u "$new_url" --arg s "$new_seq" --arg n "$new_name" \
            '"<p>Related: <a href=\"" + $u + "\">#" + $s + " " + $n + "</a></p>"')
        printf '%s' "$link_html" | cmd_append_description "$link_from_id" >/dev/null
    fi

    echo "$result" | jq '{id, sequence_id, name, priority, state}'
}

# Create a new page in the project. A plain-text description is wrapped in
# <p>; a string already containing tags is sent through as-is (HTML). Prefix
# description with "@" to read it from a file instead (e.g. @page.html) —
# mirrors curl's -d @file convention.
cmd_create_page() {
    local name="${1:?page name required}"
    local description="${2:-}"
    local pid
    pid=$(_project_id)

    description=$(_resolve_at_file "$description")

    local desc_html=""
    if [ -n "$description" ]; then
        if [[ "$description" != *"<"*">"* ]]; then
            desc_html="<p>${description}</p>"
        else
            desc_html="$description"
        fi
    fi

    local payload
    payload=$(_jq_with_desc "$desc_html" \
        --arg name "$name" '
        {name: $name} +
        (if $desc != "" then {description_html: $desc} else {} end)
    ')

    _curl -X POST -d @- \
        "$BASE/projects/$pid/pages/" <<< "$payload" | jq '{id, name, access}'
}

cmd_get_page() {
    local page_id="${1:?page_id required}"
    local out_file="${2:-}"
    local pid
    pid=$(_project_id)
    local page
    page=$(_curl "$BASE/projects/$pid/pages/$page_id/")

    if [ -n "$out_file" ]; then
        jq -r '.description_html // ""' <<< "$page" > "$out_file"
        jq -n --arg id "$page_id" --arg f "$out_file" '{id: $id, saved_to: $f}'
    else
        jq '.' <<< "$page"
    fi
}

# Get a project's root doc page, creating it if it does not exist yet.
# env_key defaults to PLANE_MAIN_DOC_PAGE_ID (the single-hierarchy case) but
# any PLANE_* key can be passed — e.g. a dual-hierarchy project tracks two
# independent roots under PLANE_DEV_DOCS_PAGE_ID/PLANE_USER_DOCS_PAGE_ID,
# found/created by calling this twice with different (name, env_key) pairs.
# Fast path: env_key already set in .env -> direct get-page, no search. Slow
# path (first run only): search for a page named exactly <page_name>; if
# none is found, create it. Either way, the resolved id is persisted to
# env_key in .env so every later call takes the fast path. The response
# always includes "just_created": true/false so the agent knows whether
# this is a brand-new, still-empty page (safe to populate with landing-page
# content) or an existing one (must not clobber what is already there).
cmd_main_page() {
    local page_name="${1:-}"
    local env_key="${2:-PLANE_MAIN_DOC_PAGE_ID}"
    local current_id="${!env_key:-}"

    if [ -n "$current_id" ]; then
        cmd_get_page "$current_id" | jq '. + {just_created: false}'
        return
    fi

    if [ -z "$page_name" ]; then
        echo "ERROR: $env_key not set in .env and no page name given — run 'main-page <page-name> [$env_key]' once so the page can be found or created." >&2
        exit 1
    fi

    local pid
    pid=$(_project_id)

    local existing_id
    existing_id=$(_curl -G "$BASE/projects/$pid/pages/search/" --data-urlencode "search=$page_name" \
        | jq -r --arg n "$page_name" '[.[] | select(.name == $n and .archived_at == null)] | .[0].id // empty')

    local page_id just_created
    if [ -n "$existing_id" ]; then
        page_id="$existing_id"
        just_created=false
    else
        page_id=$(_curl -X POST -d "$(jq -n --arg name "$page_name" '{name: $name}')" \
            "$BASE/projects/$pid/pages/" | jq -r '.id')
        just_created=true
    fi

    _persist_env_key "$env_key" "$page_id"

    cmd_get_page "$page_id" | jq --argjson c "$just_created" '. + {just_created: $c}'
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

# Patch a page's name and/or description_html. Either arg may be "" to leave
# that field untouched. A plain-text description is wrapped in <p>; a string
# already containing tags is sent through as-is (HTML). Prefix description
# with "@" to read it from a file instead (e.g. @page.html) — mirrors curl's
# -d @file convention.
cmd_edit_page() {
    local page_id="${1:?page_id required}"
    local name="${2:-}"
    local description="${3:-}"
    local pid
    pid=$(_project_id)

    description=$(_resolve_at_file "$description")

    local desc_html=""
    if [ -n "$description" ]; then
        if [[ "$description" != *"<"*">"* ]]; then
            desc_html="<p>${description}</p>"
        else
            desc_html="$description"
        fi
    fi

    local payload
    payload=$(_jq_with_desc "$desc_html" \
        --arg name "$name" '
        (if $name != "" then {name: $name} else {} end) +
        (if $desc != "" then {description_html: $desc} else {} end)
    ')

    if [ "$payload" = "{}" ]; then
        echo "ERROR: nothing to update — provide a name and/or description" >&2
        exit 1
    fi

    _curl -X PATCH -d @- \
        "$BASE/projects/$pid/pages/$page_id/" <<< "$payload" | jq '{id, name, access, description_html}'
}

# Rename a page without touching its description_html — thin wrapper over
# edit-page for the common case where only the name is changing.
cmd_rename_page() {
    local page_id="${1:?page_id required}"
    local name="${2:?new name required}"
    cmd_edit_page "$page_id" "$name" ""
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
    set-label)            cmd_set_label "${1:?issue_id required}" "${2:?label required}" ;;
    set-priority)         cmd_set_priority "${1:?issue_id required}" "${2:?priority required}" ;;
    list-review)         cmd_list_review ;;
    list-blocked)        cmd_list_blocked ;;
    set-done)            cmd_set_done "${1:?issue_id required}" ;;
    set-cancelled)       cmd_set_cancelled "${1:?issue_id required}" ;;
    set-branch)          cmd_set_branch "${1:?issue_id required}" "${2:?branch required}" ;;
    set-pr)              cmd_set_pr "${1:?issue_id required}" "${2:?pr_url required}" ;;
    add-comment)         cmd_add_comment "${1:?issue_id required}" "${2:?comment required}" ;;
    get-comments)        cmd_get_comments "${1:?issue_id required}" ;;
    update-description)  cmd_update_description "${1:?issue_id required}" ;;
    append-description)  cmd_append_description "${1:?issue_id required}" ;;
    prepend-description) cmd_prepend_description "${1:?issue_id required}" ;;
    create-task)         cmd_create_task "${1:?task name required}" "${2:-}" "${3:-none}" "${4:-backlog}" "${5:-}" "${6:-}" ;;
    task-url)             cmd_task_url "${1:?issue_id required}" ;;
    create-page)         cmd_create_page "${1:?page name required}" "${2:-}" ;;
    main-page)            cmd_main_page "${1:-}" "${2:-}" ;;
    page-url)             cmd_page_url "${1:?page_id required}" ;;
    get-page)             cmd_get_page "${1:?page_id required}" "${2:-}" ;;
    edit-page)            cmd_edit_page "${1:?page_id required}" "${2:-}" "${3:-}" ;;
    rename-page)          cmd_rename_page "${1:?page_id required}" "${2:?new name required}" ;;
    remove-page)          cmd_remove_page "${1:?page_id required}" ;;
    archive-page)         cmd_archive_page "${1:?page_id required}" ;;
    unarchive-page)       cmd_unarchive_page "${1:?page_id required}" ;;
    search-pages)         cmd_search_pages "${1:?search query required}" ;;
    done-in-period)   cmd_done_in_period "${1:?from_date required}" "${2:-}" ;;
    review-done-in-period) cmd_review_done_in_period "${1:?from_date required}" "${2:-}" ;;
    get-issue)        cmd_get_issue "${1:?issue_id required}" ;;
    get-task)         cmd_get_task "${1:?task ref required, e.g. TM-808}" ;;
    list-states)      cmd_list_states ;;
    list-labels)      cmd_list_labels ;;
    list-projects)    cmd_list_projects ;;
    upload-asset)     cmd_upload_asset "${1:?file path required}" "${2:?issue_id required}" "${3:-}" ;;
    download-asset)   cmd_download_asset "${1:?asset_id required}" "${2:?output_path required}" "${3:?issue_id required}" "${4:-}" ;;
    list-images)      cmd_list_images "${1:?issue_id required}" ;;
    *)
        echo "Usage: $0 <command> [args]"
        echo "Commands: next-task | task-in-progress | set-in-progress <id> | set-review <id> | set-todo <id> | set-label <id> <label> | set-priority <id> <priority> | list-review | list-blocked | set-done <id> | set-cancelled <id> | set-branch <id> <branch> | set-pr <id> <pr_url> | add-comment <id> <html> | get-comments <id> | update-description <id> | append-description <id> | prepend-description <id> | create-task <name> [desc] [priority] [backlog|todo|pre-ai] [label] [link_from_id] | task-url <id> | create-page <name> [desc_html|@file] | main-page [page_name] [env_key] | page-url <id> | get-page <id> [out_file] | edit-page <id> [name] [desc_html|@file] | rename-page <id> <name> | remove-page <id> | archive-page <id> | unarchive-page <id> | search-pages <query> | done-in-period <from> [<to>] | review-done-in-period <from> [<to>] | get-issue <id> | get-task <ref, e.g. TM-808> | list-states | list-labels | list-projects | upload-asset <file> <issue_id> [project_id] | download-asset <asset_id> <out_path> <issue_id> [project_id] | list-images <issue_id>"
        exit 1
        ;;
esac
