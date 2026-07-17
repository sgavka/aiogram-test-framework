#!/usr/bin/env bash
set -euo pipefail

# Allow `claude --dangerously-skip-permissions` to run as root inside the container.
# Without this, the CLI refuses the flag for root/sudo and exits silently with no output
# (empty iteration logs, in=0/out=0/turns=0, "finished (no signal)").
export IS_SANDBOX=1

MODEL=""
CONTINUE_MODE=false
ITERATION=0
PROMPT_FILE="docs/PLANE.md"

while [[ $# -gt 0 ]]; do
    case "$1" in
        -c|--continue)
            CONTINUE_MODE=true
            shift
            ;;
        --model|-m)
            MODEL="$2"
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

# Load PLANE_* and RALPH_* vars from .env (avoids sourcing values with shell-special chars)
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

MODEL="${MODEL:-${RALPH_MODEL:-claude-sonnet-4-6}}"
RALPH_BASE_BRANCH="${RALPH_BASE_BRANCH:-main}"
RALPH_MAX_LIMIT_PCT="${RALPH_MAX_LIMIT_PCT:-80}"
RALPH_WAIT_INTERVAL="${RALPH_WAIT_INTERVAL:-60}"
# Higher limit allowed during off-hours (22:00–07:00 local time)
RALPH_NIGHT_MAX_LIMIT_PCT="${RALPH_NIGHT_MAX_LIMIT_PCT:-90}"
RALPH_NIGHT_START="${RALPH_NIGHT_START:-22}"
RALPH_NIGHT_END="${RALPH_NIGHT_END:-7}"

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
    review_json=$(docs/plane.sh list-review 2>/dev/null) || return 0
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
        status=$(docs/github.sh tests-status "$branch" 2>/dev/null || echo "NONE")
        if [ "$status" = "FAILURE" ]; then
            printf "\033[90m[%s]\033[0m \033[31mTests failed on #%s (%s) — moving → Todo\033[0m\n" \
                "$(date +%H:%M:%S)" "$seq" "$branch"
            pr_url=$(docs/github.sh pr-url "$branch" 2>/dev/null || echo "")
            cmt="<p>CI <strong>tests failed</strong> on branch <code>${branch}</code> — moved back to Todo to fix."
            if [ -n "$pr_url" ]; then
                cmt="${cmt} See <a href=\"${pr_url}/checks\">PR checks</a>."
            fi
            cmt="${cmt}</p>"
            docs/plane.sh add-comment "$id" "$cmt" 2>/dev/null || true
            docs/plane.sh set-todo "$id" 2>/dev/null || true
        fi
    done
}

LOGS_DIR="docs/ralph-logs/$(date +%Y%m%d-%H%M%S)"
mkdir -p "$LOGS_DIR"

echo -e "\033[1;35m════════════════════════════════════════\033[0m"
echo -e "\033[1;35m  Ralph (Plane.so)\033[0m"
echo -e "\033[1;35m  Model: $MODEL\033[0m"
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

    # Pre-iteration sweep: demote Review tasks whose PR tests failed back to Todo.
    sweep_failed_tests

    # Pre-iteration gate: wait until a task exists AND Claude API limits are acceptable
    while true; do
        printf "\033[90m[%s] Checking tasks...\033[0m" "$(date +%H:%M:%S)"

        # Check for an interrupted in-progress task first (resume after restart)
        IP_RESULT=""
        if IP_RESULT=$(docs/plane.sh task-in-progress 2>/dev/null); then
            IP_DONE=$(echo "$IP_RESULT" | jq -r '.done // false' 2>/dev/null || echo "false")
            if [ "$IP_DONE" != "true" ]; then
                ITER_RESUME=true
                TASK_JSON="$IP_RESULT"
                printf " \033[33mresuming in-progress task\033[0m\n"
            fi
        fi

        if [ "$ITER_RESUME" = "false" ]; then
            NEXT_TASK_CHECK=""
            if NEXT_TASK_CHECK=$(docs/plane.sh next-task 2>/dev/null); then
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
        docs/plane.sh set-in-progress "$TASK_ID" >/dev/null 2>&1 && printf " \033[32mOK\033[0m\n" || printf " \033[33mfailed\033[0m\n"
    else
        printf "\033[90m[%s] Resuming task %s (already In Progress)\033[0m\n" "$(date +%H:%M:%S)" "$TASK_ID"
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

    while IFS= read -r line; do
        if [ -n "$line" ]; then
            printf "\033[90m[%s]\033[0m %s\n" "$(date +%H:%M:%S)" "$line"
            echo "$line" >> "$TMPFILE"
        fi
    done < <(cat "$PROMPT_INPUT" | claude --model "$MODEL" --print --verbose --dangerously-skip-permissions --output-format stream-json 2>/dev/null \
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

    printf "\033[90m  tokens: in=%'d  out=%'d  turns=%d  peak ctx: %'d/%'d (%s%%)  cost=\$%s\033[0m\n" \
        "$ITER_IN_TOTAL" "$ITER_OUT" "$ITER_TURNS" "$PEAK_CTX" "$ITER_CTX_WINDOW" "$PEAK_PCT" "$ITER_COST"

    # End of iteration: post stats and move the task to Review — with signal or not.
    if [ -n "$TASK_ID" ]; then
        printf "\033[90m[%s] Finishing task %s (→ Review)...\033[0m" "$(date +%H:%M:%S)" "$TASK_ID"
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

        # Post stats (+ secret log link if the gist was created) and move the task to Review.
        ITER_COMMENT="<p><code>in=${ITER_IN_TOTAL}</code> <code>out=${ITER_OUT}</code> <code>turns=${ITER_TURNS}</code> <code>peak_ctx=${PEAK_CTX}/${ITER_CTX_WINDOW} (${PEAK_PCT}%)</code> <code>cost=\$${ITER_COST}</code></p>"
        if [ -n "$GIST_URL" ]; then
            ITER_COMMENT="${ITER_COMMENT}<p>Ralph logs (secret gist): <a href=\"${GIST_URL}\">${GIST_URL}</a></p>"
        fi
        docs/plane.sh add-comment "$TASK_ID" "$ITER_COMMENT" 2>/dev/null || true
        docs/plane.sh set-review "$TASK_ID" 2>/dev/null || true
        printf " \033[32mOK\033[0m\n"
    fi

    rm -f "$PROMPT_INPUT"

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
