#!/usr/bin/env bash
set -euo pipefail

# Allow `claude --dangerously-skip-permissions` to run as root inside the container.
# Without this, the CLI refuses the flag for root/sudo and exits silently with no output
# (empty iteration logs, in=0/out=0/turns=0, "finished (no signal)").
export IS_SANDBOX=1

MODEL=""
CLI_MODEL=""
CONTINUE_MODE=false
ITERATION=0
# The dir this script (and PLANE.md, plane.sh, github.sh, ...) lives in —
# derived from the script's own location so the same file works from docs/,
# ralph/, or any other folder (see RALPH_SCRIPT in ralph.md / render.sh).
RALPH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROMPT_FILE="$RALPH_DIR/PLANE.md"

# Live status for the `agent` script / Telegram watcher (see ralph.md) — a fixed
# VM-global path, not a RALPH_* config key, so every project's loop and the
# VM-wide tooling reading across all of them agree on the same location.
REPO_NAME="$(basename "$(dirname "$RALPH_DIR")")"
AGENT_STATE_DIR="/root/agent-state"
STATE_FILE="$AGENT_STATE_DIR/${REPO_NAME}.json"
mkdir -p "$AGENT_STATE_DIR" 2>/dev/null || true
LIVE_CTX=0
LIVE_CTX_WINDOW=200000
WATCHER_PID=""

# status is "running" only while a claude call for the current iteration is
# actually executing; "idle" the rest of the time (waiting for a task, waiting
# on API limits, between iterations).
write_state() {
    local status="$1"
    mkdir -p "$AGENT_STATE_DIR" 2>/dev/null || true
    cat > "$STATE_FILE" 2>/dev/null <<EOF || true
{"repo":"$REPO_NAME","status":"$status","iteration":${ITERATION},"started_at":${ITER_STARTED_AT:-0},"context_tokens":${LIVE_CTX:-0},"context_window":${LIVE_CTX_WINDOW:-200000},"updated_at":$(date +%s)}
EOF
}

# Background side-reader of the raw stream-json capture ($RAWFILE, already
# written by the existing `tee` in the claude pipeline below) — polls the
# latest assistant message's usage and refreshes the state file, without
# touching the existing display jq filter.
state_watcher() {
    local rawfile="$1"
    while true; do
        sleep 5
        if [ -f "$rawfile" ]; then
            local usage ctx
            usage=$(tail -c 300000 "$rawfile" 2>/dev/null | grep '^{' | jq -c 'select(.type=="assistant") | .message.usage // empty' 2>/dev/null | tail -1)
            if [ -n "$usage" ]; then
                ctx=$(echo "$usage" | jq -r '((.input_tokens // 0)+(.cache_creation_input_tokens // 0)+(.cache_read_input_tokens // 0))' 2>/dev/null || echo 0)
                LIVE_CTX="${ctx:-0}"
            fi
        fi
        write_state "running"
    done
}

trap '[ -n "$WATCHER_PID" ] && kill "$WATCHER_PID" 2>/dev/null; rm -f "$STATE_FILE" "$AGENT_STATE_DIR/tasks/${REPO_NAME}.want" "$AGENT_STATE_DIR/tasks/${REPO_NAME}.granted" 2>/dev/null' EXIT

# Optional per-project daily iteration cap (RALPH_MAX_ITERATIONS_PER_DAY).
# Persisted outside the process (this loop runs forever, but the counter must
# survive a restart within the same day) as "<local-date>:<count>" so a new
# day's date mismatch naturally resets it without a separate cron/reset step.
DAILY_COUNT_FILE="$AGENT_STATE_DIR/${REPO_NAME}.daily"

_today() { date +%Y-%m-%d; }

_daily_iteration_count() {
    [ -f "$DAILY_COUNT_FILE" ] || { echo 0; return; }
    local stored_date stored_count
    IFS=: read -r stored_date stored_count < "$DAILY_COUNT_FILE" 2>/dev/null
    if [ "$stored_date" != "$(_today)" ]; then
        echo 0
    else
        echo "${stored_count:-0}"
    fi
}

_increment_daily_iteration_count() {
    local count
    count=$(_daily_iteration_count)
    count=$((count + 1))
    mkdir -p "$AGENT_STATE_DIR" 2>/dev/null || true
    echo "$(_today):$count" > "$DAILY_COUNT_FILE" 2>/dev/null || true
}

_seconds_until_midnight() {
    local now next_midnight
    now=$(date +%s)
    next_midnight=$(date -d "tomorrow 00:00:00" +%s)
    echo $(( next_midnight - now ))
}

# System-wide task-execution concurrency (see ralph.md's agent-scheduler.sh):
# this loop touches a .want file to signal it's ready to run its next
# iteration, then blocks until the broker grants it a .granted file — the
# broker is the ONLY writer of .granted files, so no distributed locking is
# needed, just polling. Concurrency is capped here, not at `agent start` —
# every project loop runs continuously; only starting a new iteration waits.
TASK_QUEUE_DIR="$AGENT_STATE_DIR/tasks"
WANT_FILE="$TASK_QUEUE_DIR/${REPO_NAME}.want"
GRANT_FILE="$TASK_QUEUE_DIR/${REPO_NAME}.granted"

request_task_slot() {
    mkdir -p "$TASK_QUEUE_DIR" 2>/dev/null || true
    rm -f "$GRANT_FILE" 2>/dev/null || true
    date +%s > "$WANT_FILE" 2>/dev/null || true
    write_state "queued"
    while [ ! -f "$GRANT_FILE" ]; do
        sleep 3
    done
    rm -f "$WANT_FILE" 2>/dev/null || true
}

release_task_slot() {
    rm -f "$GRANT_FILE" "$WANT_FILE" 2>/dev/null || true
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--continue)
            CONTINUE_MODE=true
            shift
            ;;
        --model|-m)
            CLI_MODEL="$2"
            shift 2
            ;;
        *)
            echo "ERROR: Unknown argument: $1"
                echo "Usage: $0 [--model MODEL] [-c|--continue]"
                exit 1
            shift
            ;;
    esac
done

# Load PLANE_* and RALPH_* vars from .env (avoids sourcing values with shell-special
# chars). Re-run at the top of every iteration (see the main loop below) so an
# operator can edit .env (branch, limits, model, ...) without restarting the loop —
# it only ever overwrites keys present in .env; a key removed from .env keeps its
# last-known value rather than reverting to the built-in default.
load_env() {
    if [ -f .env ]; then
        while IFS= read -r line; do
            # Skip blank lines and comments
            [[ "$line" =~ ^[[:space:]]*# ]] && continue
            [[ -z "${line// }" ]] && continue
            if [[ "$line" =~ ^((PLANE|RALPH)_[A-Z_]+)=(.*)$ ]]; then
                key="${BASH_REMATCH[1]}"
                val="${BASH_REMATCH[3]}"
                # Strip surrounding quotes if present
                val="${val%\"}"
                val="${val#\"}"
                val="${val%\'}"
                val="${val#\'}"
                export "$key=$val"
            fi
        done < .env
    fi

    RALPH_BASE_BRANCH="${RALPH_BASE_BRANCH:-main}"
    RALPH_MAX_LIMIT_PCT="${RALPH_MAX_LIMIT_PCT:-80}"
    RALPH_WAIT_INTERVAL="${RALPH_WAIT_INTERVAL:-60}"
    # Higher limit allowed during off-hours (22:00-07:00 local time)
    RALPH_NIGHT_MAX_LIMIT_PCT="${RALPH_NIGHT_MAX_LIMIT_PCT:-90}"
    RALPH_NIGHT_START="${RALPH_NIGHT_START:-22}"
    RALPH_NIGHT_END="${RALPH_NIGHT_END:-7}"
    # Optional per-project cap on iterations (claude calls) per local day; 0 = unlimited.
    RALPH_MAX_ITERATIONS_PER_DAY="${RALPH_MAX_ITERATIONS_PER_DAY:-0}"
    # Iteration post-mortem thresholds (see end of the main loop below) — either
    # set to 0 disables that trigger; both 0 disables the analysis entirely.
    # Same default durations as the VM-global Telegram watcher (ralph.md) so
    # a "why was this long" comment tends to land on the same iterations that
    # already paged Telegram.
    RALPH_ANALYZE_SECONDS="${RALPH_ANALYZE_SECONDS:-600}"
    RALPH_ANALYZE_TOKENS="${RALPH_ANALYZE_TOKENS:-150000}"
    RALPH_ANALYZE_MODEL="${RALPH_ANALYZE_MODEL:-haiku}"
    # CLI --model always wins over RALPH_MODEL, every reload.
    MODEL="${CLI_MODEL:-${RALPH_MODEL:-claude-opus-5}}"
    # Reasoning-effort level passed to every `claude` call (--effort). Default
    # "high" regardless of whatever the CLI's own built-in default happens to
    # be, so behavior here doesn't silently drift across claude-code releases.
    # A task can override this per-iteration via "Effort: <level>" in its
    # description (see below) the same way "Model: <name>" does.
    EFFORT="${RALPH_EFFORT:-high}"
    case "$EFFORT" in
        low|medium|high|xhigh|max) ;;
        *)
            echo "WARNING: invalid RALPH_EFFORT \"$EFFORT\" (use low, medium, high, xhigh, or max) — falling back to high" >&2
            EFFORT="high"
            ;;
    esac
}

load_env

# Resolve a short model name (opus, sonnet, haiku, fable) to its full model
# id. Anything that is not one of these short names passes through unchanged,
# so a full id (e.g. claude-sonnet-5, claude-haiku-4-5-20251001) also works —
# this lets a task's "Model: <name>" override (see below) accept either form.
resolve_model_alias() {
    local name
    name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
    case "$name" in
        opus)   echo "claude-opus-5" ;;
        sonnet) echo "claude-sonnet-5" ;;
        haiku)  echo "claude-haiku-4-5-20251001" ;;
        fable)  echo "claude-fable-5" ;;
        *)      echo "$1" ;;
    esac
}

# Validate required Plane.so env vars
for var in PLANE_HOST PLANE_TOKEN PLANE_USERNAME; do
    val="${!var:-}"
    if [ -z "$val" ]; then
        echo "ERROR: $var is not set in .env" >&2
        exit 1
    fi
done

if [ ! -f "$PROMPT_FILE" ]; then
    echo "ERROR: $PROMPT_FILE not found" >&2
    exit 1
fi

# Token tracking
declare -a ITER_INPUT_TOKENS=()
declare -a ITER_OUTPUT_TOKENS=()
declare -a ITER_COSTS=()
declare -a ITER_CONTEXTS=()
TOTAL_INPUT=0
TOTAL_OUTPUT=0
TOTAL_COST=0

print_usage_summary() {
    echo ""
    echo -e "\033[1;35m═══════════════════════════════════════════════════════════════\033[0m"
    echo -e "\033[1;35m  Token Usage Summary\033[0m"
    echo -e "\033[1;35m═══════════════════════════════════════════════════════════════\033[0m"
    for i in "${!ITER_INPUT_TOKENS[@]}"; do
        local iter=$((i + 1))
        local inp=${ITER_INPUT_TOKENS[$i]}
        local out=${ITER_OUTPUT_TOKENS[$i]}
        local sum=$((inp + out))
        local cost=${ITER_COSTS[$i]}
        local ctx=${ITER_CONTEXTS[$i]}
        local peak=${ctx%%/*}
        local ctx_max=${ctx##*/}
        local ctx_pct
        if [ "$peak" -gt 0 ] && [ "$ctx_max" -gt 0 ]; then
            ctx_pct=$(echo "scale=1; $peak * 100 / $ctx_max" | bc)
        else
            ctx_pct="0"
        fi
        printf "  \033[90mIteration %d:\033[0m  in: \033[33m%'d\033[0m  out: \033[33m%'d\033[0m  peak ctx: \033[36m%'d/%'d (%s%%)\033[0m  cost: \033[32m\$%s\033[0m\n" "$iter" "$inp" "$out" "$peak" "$ctx_max" "$ctx_pct" "$cost"
    done
    echo -e "\033[1;35m───────────────────────────────────────────────────────────────\033[0m"
    local grand=$((TOTAL_INPUT + TOTAL_OUTPUT))
    printf "  \033[1mTotal:\033[0m        in: \033[33m%'d\033[0m  out: \033[33m%'d\033[0m  tokens: \033[1;33m%'d\033[0m  cost: \033[1;32m\$%s\033[0m\n" "$TOTAL_INPUT" "$TOTAL_OUTPUT" "$grand" "$TOTAL_COST"
    echo -e "\033[1;35m═══════════════════════════════════════════════════════════════\033[0m"
}

# Returns true (exit 0) if the current local hour is within the night window.
# Night window crosses midnight: RALPH_NIGHT_START (default 22) to RALPH_NIGHT_END (default 7).
is_night_time() {
    local h
    h=$(date +%-H)
    local s="${RALPH_NIGHT_START:-22}" e="${RALPH_NIGHT_END:-7}"
    if [ "$s" -gt "$e" ]; then
        # Overnight range: e.g. 22–7 → true if h>=22 OR h<7
        [ "$h" -ge "$s" ] || [ "$h" -lt "$e" ]
    else
        [ "$h" -ge "$s" ] && [ "$h" -lt "$e" ]
    fi
}

# Check current Claude subscription usage via `claude -p "/usage"`.
# Returns the highest percentage found across all "Current" limit lines (0-100).
check_claude_limits() {
    local output
    output=$(claude -p "/usage" 2>/dev/null) || output=""
    # Strip ANSI escape codes before parsing (output differs in non-interactive mode)
    local clean
    clean=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
    local max_pct
    max_pct=$(printf '%s' "$clean" | grep "Current session:" | sed -n 's/.*: \([0-9]*\)% used.*/\1/p')
    echo "${max_pct:-99}"
}

# Pre-iteration sweep: any task in Review whose PR's *test* check failed is moved
# back to Todo so next-task can re-pick it (next-task still decides ordering).
# Non-test CI failures (build, code quality, deploy) are ignored on purpose — only
# a genuine test failure demotes the task. PENDING/NONE leaves it in Review.
sweep_failed_tests() {
    local review_json count
    review_json=$("$RALPH_DIR/plane.sh" list-review 2>/dev/null) || return 0
    [ -z "$review_json" ] && return 0
    count=$(echo "$review_json" | jq 'length' 2>/dev/null || echo 0)
    [ "${count:-0}" -eq 0 ] && return 0

    local i id seq branch status pr_url cmt
    for i in $(seq 0 $((count - 1))); do
        id=$(echo "$review_json" | jq -r ".[$i].id")
        seq=$(echo "$review_json" | jq -r ".[$i].sequence_id // \"?\"")
        branch=$(echo "$review_json" | jq -r ".[$i].description_html // \"\"" \
            | grep -oP '(?<=Branch: <code>)[^<]+' | tail -1 || echo "")
        [ -z "$branch" ] && continue
        status=$("$RALPH_DIR/github.sh" tests-status "$branch" 2>/dev/null || echo "NONE")
        if [ "$status" = "FAILURE" ]; then
            printf "\033[90m[%s]\033[0m \033[31mTests failed on #%s (%s) — moving → Todo\033[0m\n" \
                "$(date +%H:%M:%S)" "$seq" "$branch"
            pr_url=$("$RALPH_DIR/github.sh" pr-url "$branch" 2>/dev/null || echo "")
            cmt="<p>CI <strong>tests failed</strong> on branch <code>${branch}</code> — moved back to Todo to fix."
            if [ -n "$pr_url" ]; then
                cmt="${cmt} See <a href=\"${pr_url}/checks\">PR checks</a>."
            fi
            cmt="${cmt}</p>"
            "$RALPH_DIR/plane.sh" add-comment "$id" "$cmt" 2>/dev/null || true
            "$RALPH_DIR/plane.sh" set-todo "$id" 2>/dev/null || true
        fi
    done
}

# The VM this loop runs on hosts many concurrent project loops with only
# 14GB RAM (see ralph.md) — a container an agent starts (e.g. via
# docker-compose to run tests) and forgets to tear down accumulates across
# iterations and across projects. Run unconditionally after every iteration,
# regardless of outcome: kills every running container on the host except
# ones whose name matches RALPH_DOCKER_KILL_EXCLUDE (comma list of
# case-insensitive substrings, default: shoper,crypto-trader — those two run
# persistent services that must never be interrupted by another project's
# iteration finishing). Best-effort: silently skipped if docker is not
# installed.
cleanup_docker_containers() {
    command -v docker >/dev/null 2>&1 || return 0
    local exclude="${RALPH_DOCKER_KILL_EXCLUDE:-shoper,crypto-trader}"
    local pattern="${exclude//,/|}"
    local victims
    # The trailing `|| true` matters under `set -o pipefail`: grep exits 1 when
    # every running container matches the exclude pattern (or none are running
    # at all), which would otherwise propagate through the pipe and, being an
    # unguarded assignment, kill the whole loop under `set -e` (see v53).
    victims=$(docker ps --format '{{.ID}} {{.Names}}' 2>/dev/null | grep -viE "$pattern" | awk '{print $1}' || true)
    [ -z "$victims" ] && return 0
    printf "\033[90m[%s] Killing docker containers (except %s)...\033[0m" "$(date +%H:%M:%S)" "$exclude"
    # shellcheck disable=SC2086
    docker kill $victims >/dev/null 2>&1 && printf " \033[32mOK\033[0m\n" || printf " \033[33mfailed\033[0m\n"
}

LOGS_DIR="$RALPH_DIR/ralph-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS_DIR"

echo -e "\033[1;35m════════════════════════════════════════\033[0m"
echo -e "\033[1;35m  Ralph (Plane.so)\033[0m"
echo -e "\033[1;35m  Model: $MODEL (default -- a task can override via Model: <name> in its description)\033[0m"
echo -e "\033[1;35m  Effort: $EFFORT (default -- a task can override via Effort: <level> in its description)\033[0m"
echo -e "\033[1;35m  Continue mode: $CONTINUE_MODE\033[0m"
echo -e "\033[1;35m  Prompt file: $PROMPT_FILE\033[0m"
echo -e "\033[1;35m  Logs: $LOGS_DIR\033[0m"
echo -e "\033[1;35m  Base branch: $RALPH_BASE_BRANCH\033[0m"
echo -e "\033[1;35m  Plane host: $PLANE_HOST\033[0m"
echo -e "\033[1;35m  Workspace: $PLANE_USERNAME\033[0m"
echo -e "\033[1;35m  Max limit usage: ${RALPH_MAX_LIMIT_PCT}%\033[0m"
echo -e "\033[1;35m  Wait interval: ${RALPH_WAIT_INTERVAL}s\033[0m"
echo -e "\033[1;35m  Night limit: ${RALPH_NIGHT_MAX_LIMIT_PCT}% (${RALPH_NIGHT_START}:00-${RALPH_NIGHT_END}:00 local)\033[0m"
echo -e "\033[1;35m════════════════════════════════════════\033[0m"
echo ""

while true; do
    ITER_RESUME=false
    TASK_JSON=""
    TASK_ID=""

    # Re-read .env each iteration so an operator can edit it (branch, limits,
    # model, ...) without restarting the loop.
    load_env

    ITER_STARTED_AT=0
    LIVE_CTX=0
    write_state "idle"

    # Pre-iteration sweep: demote Review tasks whose PR tests failed back to Todo.
    sweep_failed_tests

    # Pre-iteration gate: wait until a task exists AND Claude API limits are acceptable
    while true; do
        printf "\033[90m[%s] Checking tasks...\033[0m" "$(date +%H:%M:%S)"

        # Check for an interrupted in-progress task first (resume after restart)
        IP_RESULT=""
        if IP_RESULT=$("$RALPH_DIR/plane.sh" task-in-progress 2>/dev/null); then
            IP_DONE=$(echo "$IP_RESULT" | jq -r '.done // false' 2>/dev/null || echo "false")
            if [ "$IP_DONE" != "true" ]; then
                ITER_RESUME=true
                TASK_JSON="$IP_RESULT"
                printf " \033[33mresuming in-progress task\033[0m\n"
            fi
        fi

        if [ "$ITER_RESUME" = "false" ]; then
            NEXT_TASK_CHECK=""
            if NEXT_TASK_CHECK=$("$RALPH_DIR/plane.sh" next-task 2>/dev/null); then
                TASK_IS_DONE=$(echo "$NEXT_TASK_CHECK" | jq -r '.done // false' 2>/dev/null || echo "false")
            else
                TASK_IS_DONE="false"
            fi

            if [ "$TASK_IS_DONE" = "true" ]; then
                printf " \033[33mno tasks. Waiting %ss...\033[0m\n" "$RALPH_WAIT_INTERVAL"
                sleep "$RALPH_WAIT_INTERVAL"
                continue
            fi
            TASK_JSON="$NEXT_TASK_CHECK"
            printf " \033[32mOK\033[0m\n"
        fi


        if [ "$RALPH_MAX_ITERATIONS_PER_DAY" -gt 0 ] 2>/dev/null; then
            DAILY_COUNT=$(_daily_iteration_count)
            if [ "$DAILY_COUNT" -ge "$RALPH_MAX_ITERATIONS_PER_DAY" ]; then
                WAIT_SECS=$(_seconds_until_midnight)
                printf "\033[90m[%s] Daily iteration cap reached (%s/%s). Sleeping %ss until local midnight...\033[0m\n" \
                    "$(date +%H:%M:%S)" "$DAILY_COUNT" "$RALPH_MAX_ITERATIONS_PER_DAY" "$WAIT_SECS"
                sleep "$WAIT_SECS"
                continue
            fi
        fi
        printf "\033[90m[%s] Checking limits...\033[0m" "$(date +%H:%M:%S)"
        LIMIT_PCT=$(check_claude_limits)
        LIMIT_PCT="${LIMIT_PCT:-0}"
        EFFECTIVE_MAX_PCT="$RALPH_MAX_LIMIT_PCT"
        is_night_time && EFFECTIVE_MAX_PCT="${RALPH_NIGHT_MAX_LIMIT_PCT:-90}"
        if [ "${LIMIT_PCT:-0}" -ge "$EFFECTIVE_MAX_PCT" ] 2>/dev/null; then
            printf " \033[33m%s%% used >= %s%% threshold. Waiting %ss...\033[0m\n" \
                "$LIMIT_PCT" "$EFFECTIVE_MAX_PCT" "$RALPH_WAIT_INTERVAL"
            sleep "$RALPH_WAIT_INTERVAL"
            continue
        fi
        printf " \033[32m%s%% used (limit %s%%)\033[0m\n" "$LIMIT_PCT" "$EFFECTIVE_MAX_PCT"

        break
    done

    # System-wide task-execution concurrency: request a slot from the
    # agent-scheduler.sh broker (see ralph.md) before actually starting this
    # iteration. All project loops run continuously and unthrottled — only
    # the moment a loop is about to invoke claude for its next iteration is
    # gated, so a project waiting for a slot still shows as a live, running
    # tmux session (status "queued"), not stopped.
    printf "\033[90m[%s] Requesting task-execution slot...\033[0m" "$(date +%H:%M:%S)"
    request_task_slot
    printf " \033[32mgranted\033[0m\n"

    ITERATION=$((ITERATION + 1))
    echo ""
    echo -e "\033[1;32m┌──────────────────────────────────────┐\033[0m"
    echo -e "\033[1;32m│  Iteration $ITERATION  \033[90m$(date +%H:%M:%S)\033[0m"
    echo -e "\033[1;32m└──────────────────────────────────────┘\033[0m"

    if [ "$ITER_RESUME" = "false" ]; then
        printf "\033[90m[%s] Checking out %s + pulling...\033[0m" "$(date +%H:%M:%S)" "$RALPH_BASE_BRANCH"
        git checkout "$RALPH_BASE_BRANCH" 2>/dev/null && git pull origin "$RALPH_BASE_BRANCH" 2>/dev/null && printf " \033[32mOK\033[0m\n" || printf " \033[33mskipped\033[0m\n"
    fi
    TMPFILE=$(mktemp)
    RAWFILE="$LOGS_DIR/iteration-${ITERATION}.json"
    PROMPT_INPUT=$(mktemp)

    cat "$PROMPT_FILE" > "$PROMPT_INPUT"

    # The loop owns task selection and state. Log the task, then start it.
    TASK_ID=$(echo "$TASK_JSON" | jq -r '.id // ""' 2>/dev/null || echo "")
    TASK_SEQ=$(echo "$TASK_JSON" | jq -r '.sequence_id // "?"' 2>/dev/null || echo "?")
    TASK_NAME=$(echo "$TASK_JSON" | jq -r '.name // ""' 2>/dev/null || echo "")
    echo -e "\033[1;36m[$(date +%H:%M:%S)] Task #${TASK_SEQ}: ${TASK_NAME}\033[0m"
    echo -e "\033[90m  task id: ${TASK_ID}\033[0m"

    # Move fresh tasks to In Progress (start); resumed tasks are already In Progress.
    if [ "$ITER_RESUME" = "false" ] && [ -n "$TASK_ID" ]; then
        printf "\033[90m[%s] Starting task %s (→ In Progress)...\033[0m" "$(date +%H:%M:%S)" "$TASK_ID"
        "$RALPH_DIR/plane.sh" set-in-progress "$TASK_ID" >/dev/null 2>&1 && printf " \033[32mOK\033[0m\n" || printf " \033[33mfailed\033[0m\n"
    else
        printf "\033[90m[%s] Resuming task %s (already In Progress)\033[0m\n" "$(date +%H:%M:%S)" "$TASK_ID"
    fi

    # Enrich the task JSON with unresolved GitHub PR review threads (if a branch
    # is already assigned) so the agent does not have to fetch them itself every
    # iteration (formerly PLANE.md.tpl step 0.1's manual unresolved-threads call).
    TASK_BRANCH=$(echo "$TASK_JSON" | jq -r '.description_html // ""' \
        | grep -oP '(?<=Branch: <code>)[^<]+' | tail -1 || echo "")
    PR_THREADS="[]"
    if [ -n "$TASK_BRANCH" ]; then
        PR_THREADS=$("$RALPH_DIR/github.sh" unresolved-threads "$TASK_BRANCH" 2>/dev/null || echo "[]")
        [ -z "$PR_THREADS" ] && PR_THREADS="[]"
    fi
    TASK_JSON=$(echo "$TASK_JSON" | jq --argjson threads "$PR_THREADS" '. + {pr_unresolved_threads: $threads}')

    # Per-task model override: a task's description may contain "Model: <name>"
    # (short name like opus/sonnet/haiku/fable, or a full model id) to run just
    # this task on a different model than RALPH_MODEL — e.g. a cheap/simple
    # follow-up task on haiku. Falls back to the configured default when absent.
    TASK_MODEL_RAW=$(echo "$TASK_JSON" | jq -r '.description_html // ""' \
        | grep -ioP '(?<=model:)[[:space:]]*\K[a-z0-9._-]+' | tail -1 || echo "")
    ITER_MODEL="$MODEL"
    if [ -n "$TASK_MODEL_RAW" ]; then
        ITER_MODEL=$(resolve_model_alias "$TASK_MODEL_RAW")
        echo -e "\033[90m  model override: ${TASK_MODEL_RAW} → ${ITER_MODEL}\033[0m"
    fi

    # Per-task effort override: a task's description may contain "Effort: <level>"
    # (low/medium/high/xhigh/max) to run just this task at a different reasoning
    # depth than RALPH_EFFORT — e.g. "Effort: low" on a small, well-specified
    # follow-up, or "Effort: xhigh" on a genuinely hard one. Falls back to the
    # configured default when absent or invalid.
    TASK_EFFORT_RAW=$(echo "$TASK_JSON" | jq -r '.description_html // ""' \
        | grep -ioP '(?<=effort:)[[:space:]]*\K[a-z]+' | tail -1 || echo "")
    ITER_EFFORT="$EFFORT"
    if [ -n "$TASK_EFFORT_RAW" ]; then
        case "${TASK_EFFORT_RAW,,}" in
            low|medium|high|xhigh|max)
                ITER_EFFORT="${TASK_EFFORT_RAW,,}"
                echo -e "\033[90m  effort override: ${TASK_EFFORT_RAW} → ${ITER_EFFORT}\033[0m"
                ;;
            *)
                echo -e "\033[33m  ignoring invalid effort override \"${TASK_EFFORT_RAW}\" — using ${ITER_EFFORT}\033[0m"
                ;;
        esac
    fi

    # Inject the task JSON directly so Claude already has it and does not fetch it.
    {
        echo ""
        echo "---"
        echo ""
        echo "## Your task"
        echo ""
        if [ "$ITER_RESUME" = true ]; then
            echo "NOTE: This task was already In Progress from a previous session — resume where it left off."
        else
            echo "NOTE: This task has already been moved to In Progress for you."
        fi
        echo "The automation owns task selection and ALL Plane state transitions. Do NOT call next-task, task-in-progress, set-in-progress, or set-review. Work the task described in the JSON below (description is in description_html; comments are in the comments array):"
        echo ""
        echo '```json'
        echo "$TASK_JSON"
        echo '```'
    } >> "$PROMPT_INPUT"

    if [ "$CONTINUE_MODE" = true ] || [ "$ITER_RESUME" = true ]; then
        GIT_DIFF=$(git diff HEAD 2>/dev/null || echo "")
        GIT_DIFF_CACHED=$(git diff --cached 2>/dev/null || echo "")
        {
            echo ""
            echo "---"
            if [ "$ITER_RESUME" = true ]; then
                echo "NOTE: An in-progress task was detected from a previous session. Review the recent code changes below and resume where it left off."
            else
                echo "NOTE: You are continuing implementation of the task. Review the recent code changes below to understand what has already been done, then continue from where it left off."
            fi
            if [ -n "$GIT_DIFF_CACHED" ]; then
                echo ""
                echo "Staged changes (git diff --cached):"
                echo '```'
                echo "$GIT_DIFF_CACHED"
                echo '```'
            fi
            if [ -n "$GIT_DIFF" ]; then
                echo ""
                echo "Unstaged changes (git diff HEAD):"
                echo '```'
                echo "$GIT_DIFF"
                echo '```'
            fi
            if [ -z "$GIT_DIFF" ] && [ -z "$GIT_DIFF_CACHED" ]; then
                echo ""
                echo "No uncommitted changes found. Check recent commits with git log for context."
            fi
        } >> "$PROMPT_INPUT"
    fi

    echo -e "\033[90m[$(date +%H:%M:%S)] Working on task ${TASK_ID} (running Claude)...\033[0m"

    ITER_STARTED_AT=$(date +%s)
    LIVE_CTX=0
    write_state "running"
    state_watcher "$RAWFILE" &
    WATCHER_PID=$!

    while IFS= read -r line; do
        if [ -n "$line" ]; then
            printf "\033[90m[%s]\033[0m %s\n" "$(date +%H:%M:%S)" "$line"
            echo "$line" >> "$TMPFILE"
        fi
    done < <(cat "$PROMPT_INPUT" | claude --model "$ITER_MODEL" --effort "$ITER_EFFORT" --print --verbose --dangerously-skip-permissions --output-format stream-json 2>/dev/null \
        | tee "$RAWFILE" \
        | grep --line-buffered '^{' \
        | jq --unbuffered -r '
            if .type == "assistant" then
                .message.content[]? |
                if .type == "text" then
                    .text // empty
                elif .type == "thinking" then
                    "\u001b[90m💭 thinking... (\(.thinking | length) chars)\u001b[0m"
                elif .type == "tool_use" then
                    "\n\u001b[36m⚡ \(.name)\u001b[0m" + (
                        if .name == "Read" then " \u001b[33m\(.input.file_path // "")\u001b[0m"
                        elif .name == "Write" then " \u001b[33m\(.input.file_path // "")\u001b[0m"
                        elif .name == "Edit" then " \u001b[33m\(.input.file_path // "")\u001b[0m"
                        elif .name == "Glob" then " \u001b[33m\(.input.pattern // "")\u001b[0m"
                        elif .name == "Grep" then " \u001b[33m\(.input.pattern // "")\u001b[0m"
                        elif .name == "Bash" then " \u001b[33m\(.input.command // "")\u001b[0m"
                        elif .name == "Agent" then " \u001b[33m\(.input.description // "")\u001b[0m"
                        elif .name == "Skill" then " \u001b[33m\(.input.skill // "")\u001b[0m"
                        elif .name == "LSP" then " \u001b[33m\(.input.method // "")\u001b[0m"
                        elif .name == "WebFetch" then " \u001b[33m\(.input.url // "")\u001b[0m"
                        elif .name == "WebSearch" then " \u001b[33m\(.input.query // "")\u001b[0m"
                        elif .name == "NotebookEdit" then " \u001b[33m\(.input.file_path // "")\u001b[0m"
                        elif .name == "TodoWrite" then "\n" + ([.input.todos[]? | "  " + (if .status == "in_progress" then "\u001b[33m▶\u001b[0m" elif .status == "completed" then "\u001b[32m✓\u001b[0m" else "\u001b[90m○\u001b[0m" end) + " " + (.content // "")] | join("\n"))
                        elif .name == "ToolSearch" then " \u001b[33m\(.input.query // "")\u001b[0m"
                        else
                            " \u001b[33m\(.input | keys[0:2] | join(", "))\u001b[0m"
                        end
                    )
                elif .type == "tool_result" then
                    "\u001b[90m  ↳ result (\(.content | tostring | length) chars)\u001b[0m"
                else
                    empty
                end
            elif .type == "tool_result" then
                "\u001b[90m  ↳ tool result (\(.content | tostring | length) chars)\u001b[0m"
            elif .type == "system" then
                if .subtype == "thinking_tokens" then
                    "\u001b[35m⚙ thinking_tokens\u001b[0m estimated=\u001b[33m\(.estimated_tokens // 0)\u001b[0m delta=\u001b[33m\(.estimated_tokens_delta // 0)\u001b[0m"
                else
                    "\u001b[35m⚙ system:\(.subtype // "")\u001b[0m model=\u001b[33m\(.model // "?")\u001b[0m tools=\u001b[33m\(.tools | length)\u001b[0m"
                end
            elif .type == "rate_limit_event" then
                "\u001b[90m⏱ rate_limit: \(.rate_limit_info.status // "?")\u001b[0m"
            elif .type == "result" then
                (if (.result // "") != "" then .result else empty end),
                "\n\u001b[1;32m✓ \(.subtype // "done")\u001b[0m \u001b[90mduration=\(.duration_ms // 0)ms turns=\(.num_turns // 0) cost=$\(.total_cost_usd // 0)\u001b[0m"
            else
                empty
            end
        ')

    kill "$WATCHER_PID" 2>/dev/null || true
    wait "$WATCHER_PID" 2>/dev/null || true
    WATCHER_PID=""

    # Release the task-execution slot now that claude has finished — frees it
    # up for the broker to grant to the next-highest-priority waiting repo.
    release_task_slot

    # Captured here, before ITER_STARTED_AT is reset to 0 below for the live
    # status display.
    ITER_ELAPSED_SECONDS=$(( $(date +%s) - ITER_STARTED_AT ))

    echo ""

    RESULT_JSON=$(grep '^{' "$RAWFILE" | jq -c 'select(.type == "result")' 2>/dev/null | tail -1 || echo "{}")
    ITER_IN=$(echo "$RESULT_JSON" | jq -r '.usage.input_tokens // 0' || echo "0")
    ITER_CACHE_CREATE=$(echo "$RESULT_JSON" | jq -r '.usage.cache_creation_input_tokens // 0' || echo "0")
    ITER_CACHE_READ=$(echo "$RESULT_JSON" | jq -r '.usage.cache_read_input_tokens // 0' || echo "0")
    ITER_OUT=$(echo "$RESULT_JSON" | jq -r '.usage.output_tokens // 0' || echo "0")
    ITER_COST=$(echo "$RESULT_JSON" | jq -r '.total_cost_usd // 0' || echo "0")
    ITER_CTX_WINDOW=$(echo "$RESULT_JSON" | jq -r 'if .modelUsage != null then ([.modelUsage[]] | first | .contextWindow // 200000) else 200000 end' || echo "200000")
    ITER_TURNS=$(echo "$RESULT_JSON" | jq -r '.num_turns // 0' || echo "0")
    ITER_IN=${ITER_IN:-0}
    ITER_CACHE_CREATE=${ITER_CACHE_CREATE:-0}
    ITER_CACHE_READ=${ITER_CACHE_READ:-0}
    ITER_OUT=${ITER_OUT:-0}
    ITER_COST=${ITER_COST:-0}
    ITER_CTX_WINDOW=${ITER_CTX_WINDOW:-200000}
    ITER_TURNS=${ITER_TURNS:-0}

    # Persist the real context window for the next iteration's live display,
    # and mark this repo idle again now that the claude call has finished.
    LIVE_CTX_WINDOW="$ITER_CTX_WINDOW"
    ITER_STARTED_AT=0
    LIVE_CTX=0
    write_state "idle"

    PEAK_CTX=$(grep '^{' "$RAWFILE" | jq -r '
        select(.type == "assistant") |
        .message.usage |
        ((.input_tokens // 0) + (.cache_creation_input_tokens // 0) + (.cache_read_input_tokens // 0))
    ' 2>/dev/null | sort -n | tail -1 || echo "0")
    PEAK_CTX=${PEAK_CTX:-0}
    if [ "$PEAK_CTX" -gt 0 ] && [ "$ITER_CTX_WINDOW" -gt 0 ]; then
        PEAK_PCT=$(echo "scale=1; $PEAK_CTX * 100 / $ITER_CTX_WINDOW" | bc)
    else
        PEAK_PCT="0"
    fi

    ITER_IN_TOTAL=$((ITER_IN + ITER_CACHE_CREATE + ITER_CACHE_READ))

    ITER_INPUT_TOKENS+=("$ITER_IN_TOTAL")
    ITER_OUTPUT_TOKENS+=("$ITER_OUT")
    ITER_COSTS+=("$ITER_COST")
    ITER_CONTEXTS+=("$PEAK_CTX/$ITER_CTX_WINDOW")
    TOTAL_INPUT=$((TOTAL_INPUT + ITER_IN_TOTAL))
    TOTAL_OUTPUT=$((TOTAL_OUTPUT + ITER_OUT))
    TOTAL_COST=$(echo "$TOTAL_COST + $ITER_COST" | bc)

    printf "\033[90m  tokens: in=%'d  out=%'d  turns=%d  peak ctx: %'d/%'d (%s%%)  cost=\$%s  elapsed=%ds\033[0m\n" \
        "$ITER_IN_TOTAL" "$ITER_OUT" "$ITER_TURNS" "$PEAK_CTX" "$ITER_CTX_WINDOW" "$PEAK_PCT" "$ITER_COST" "$ITER_ELAPSED_SECONDS"

    # Iteration post-mortem: when this iteration ran unusually long or used a
    # lot of context, ask a cheap model to read back its own raw transcript
    # ($RAWFILE) and explain why — repeated/failed tool calls, large file
    # reads, a retry loop, excessive back-and-forth, or simply a large task —
    # so whoever looks at the task afterward (or the Telegram "running long"
    # alert, if it also fired) gets a cause, not just a bare duration/token
    # count. Either RALPH_ANALYZE_SECONDS or RALPH_ANALYZE_TOKENS set to 0
    # disables that trigger; best-effort, never fails the iteration.
    ANALYSIS_HTML=""
    ANALYZE_REASON=""
    if [ "$RALPH_ANALYZE_SECONDS" -gt 0 ] 2>/dev/null && [ "$ITER_ELAPSED_SECONDS" -ge "$RALPH_ANALYZE_SECONDS" ]; then
        ANALYZE_REASON="ran ${ITER_ELAPSED_SECONDS}s (>= ${RALPH_ANALYZE_SECONDS}s)"
    fi
    if [ "$RALPH_ANALYZE_TOKENS" -gt 0 ] 2>/dev/null && [ "$PEAK_CTX" -ge "$RALPH_ANALYZE_TOKENS" ]; then
        [ -n "$ANALYZE_REASON" ] && ANALYZE_REASON="${ANALYZE_REASON}, "
        ANALYZE_REASON="${ANALYZE_REASON}peak context ${PEAK_CTX} tokens (>= ${RALPH_ANALYZE_TOKENS})"
    fi
    if [ -n "$ANALYZE_REASON" ]; then
        printf "\033[90m[%s] Analyzing why this iteration %s...\033[0m" "$(date +%H:%M:%S)" "$ANALYZE_REASON"
        ANALYZE_MODEL=$(resolve_model_alias "$RALPH_ANALYZE_MODEL")
        ANALYSIS_PROMPT_FILE=$(mktemp)
        {
            echo "You are reviewing one iteration's raw execution transcript (stream-json events, one per line) from an autonomous coding agent. This iteration ${ANALYZE_REASON}. In 2-4 sentences, explain the likely cause — repeated or failed tool calls, large file reads, a retry loop, excessive back-and-forth, or simply a large/complex task — so an operator glancing at the task can decide whether to intervene. Be concise and concrete. No preamble, no markdown headers."
            echo ""
            echo "Transcript excerpt (assistant turns only, truncated to the end):"
            tail -c 400000 "$RAWFILE" 2>/dev/null | grep '^{' | jq -c 'select(.type=="assistant") | {type, content: (.message.content // empty)}' 2>/dev/null
        } > "$ANALYSIS_PROMPT_FILE"
        ANALYSIS_TEXT=$(cat "$ANALYSIS_PROMPT_FILE" | claude --model "$ANALYZE_MODEL" --print --dangerously-skip-permissions 2>/dev/null || echo "")
        rm -f "$ANALYSIS_PROMPT_FILE"
        if [ -n "$ANALYSIS_TEXT" ]; then
            ANALYSIS_HTML="<p><strong>Why this iteration was slow/expensive:</strong> $(printf '%s' "$ANALYSIS_TEXT" | sed 's/&/\&amp;/g; s/</\&lt;/g; s/>/\&gt;/g')</p>"
            printf " \033[32mOK\033[0m\n"
        else
            printf " \033[33mskipped\033[0m\n"
        fi
    fi

    # End of iteration: post stats, then move the task to Review (default) or back to
    # Todo if the agent signaled <promise>TASK_BLOCKED</promise> (see PLANE.md.tpl
    # step 3.2.2/9 — the task depends on another, unfinished one) — with signal or not.
    TASK_BLOCKED=false
    if grep -q '<promise>TASK_BLOCKED</promise>' "$TMPFILE"; then
        TASK_BLOCKED=true
    fi

    if [ -n "$TASK_ID" ]; then
        NEXT_STATE_LABEL="Review"
        [ "$TASK_BLOCKED" = true ] && NEXT_STATE_LABEL="Todo"
        printf "\033[90m[%s] Finishing task %s (→ %s)...\033[0m" "$(date +%H:%M:%S)" "$TASK_ID" "$NEXT_STATE_LABEL"
        # Upload this iteration's logs (ANSI-stripped) to a SECRET GitHub gist.
        LOG_TXT=$(mktemp)
        {
            echo "Ralph (Plane.so) — task #${TASK_SEQ}: ${TASK_NAME}"
            echo "task id: ${TASK_ID}"
            echo "iteration: ${ITERATION}   date: $(date '+%Y-%m-%d %H:%M:%S')"
            echo "stats: in=${ITER_IN_TOTAL} out=${ITER_OUT} turns=${ITER_TURNS} peak_ctx=${PEAK_CTX}/${ITER_CTX_WINDOW} (${PEAK_PCT}%) cost=\$${ITER_COST}"
            echo "============================================================"
            echo ""
            sed 's/\x1b\[[0-9;]*m//g' "$TMPFILE" 2>/dev/null || true
        } > "$LOG_TXT"
        GIST_NAME="ralph-task-${TASK_SEQ}-iter-${ITERATION}.log"
        GIST_URL=$(gh gist create --filename "$GIST_NAME" --desc "Ralph logs — task #${TASK_SEQ} iter ${ITERATION} (secret)" - < "$LOG_TXT" 2>/dev/null | tail -1 || echo "")
        rm -f "$LOG_TXT"

        # Post stats (+ secret log link if the gist was created) and move the task.
        ITER_COMMENT="<p><code>in=${ITER_IN_TOTAL}</code> <code>out=${ITER_OUT}</code> <code>turns=${ITER_TURNS}</code> <code>peak_ctx=${PEAK_CTX}/${ITER_CTX_WINDOW} (${PEAK_PCT}%)</code> <code>cost=\$${ITER_COST}</code> <code>elapsed=${ITER_ELAPSED_SECONDS}s</code></p>${ANALYSIS_HTML}"
        if [ -n "$GIST_URL" ]; then
            ITER_COMMENT="${ITER_COMMENT}<p>Ralph logs (secret gist): <a href=\"${GIST_URL}\">${GIST_URL}</a></p>"
        fi
        "$RALPH_DIR/plane.sh" add-comment "$TASK_ID" "$ITER_COMMENT" 2>/dev/null || true
        if [ "$TASK_BLOCKED" = true ]; then
            "$RALPH_DIR/plane.sh" set-todo "$TASK_ID" 2>/dev/null || true
        else
            "$RALPH_DIR/plane.sh" set-review "$TASK_ID" 2>/dev/null || true
        fi
        printf " \033[32mOK\033[0m\n"
    fi

    rm -f "$PROMPT_INPUT"

    cleanup_docker_containers

    # Count this iteration toward RALPH_MAX_ITERATIONS_PER_DAY regardless of
    # outcome (blocked/done/no-signal) — one claude call = one iteration.
    _increment_daily_iteration_count

    if [ "$TASK_BLOCKED" = true ]; then
        rm -f "$TMPFILE"
        echo ""
        echo -e "\033[90m[$(date +%H:%M:%S)]\033[0m \033[1;33m── Task ${TASK_ID} blocked — moved back to Todo. Starting fresh session (iteration $ITERATION) ──\033[0m"
        echo ""
        continue
    fi
    if grep -q '<promise>TASK_DONE</promise>' "$TMPFILE"; then
        rm -f "$TMPFILE"
        echo ""
        echo -e "\033[90m[$(date +%H:%M:%S)]\033[0m \033[1;33m── Task ${TASK_ID} done. Starting fresh session (iteration $ITERATION) ──\033[0m"
        echo ""
        continue
    fi
    rm -f "$TMPFILE"
    echo ""
    echo -e "\033[90m[$(date +%H:%M:%S)]\033[0m \033[1;31m── Iteration $ITERATION finished — task ${TASK_ID} (no signal) ──\033[0m"
    echo ""
done

print_usage_summary
exit 0
