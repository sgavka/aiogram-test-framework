#!/usr/bin/env bash
# Generic Grafana Loki query helper for the ralph-plane.sh workflow — the
# Loki equivalent of elastic.sh, for projects that ship logs to Loki/Grafana
# Cloud instead of (or in addition to) Elasticsearch.
#
# Usage: docs/loki.sh <command> [options]
#
# Env:
#   LOKI_URL              push endpoint from the project's .env, e.g.
#                         https://logs-prod-025.grafana.net/loki/api/v1/push
#                         The query base is derived by stripping the trailing
#                         "/push" (Grafana Cloud serves push and query on the
#                         same host/path prefix).
#   LOKI_BEARER_TOKEN     Grafana Cloud credential in "<instance-id>:<api-key>"
#                         form — despite the env var name this is sent as
#                         HTTP Basic auth (curl -u), which is what Grafana
#                         Cloud's Loki API expects for this credential shape.
#   LOKI_APPLICATION_NAME \
#   LOKI_ENVIRONMENT       base stream selector labels: {application="...",
#                         environment="..."}. Both required — these are the
#                         labels the app's Loki handler attaches to every line.
#   LOKI_EXTRA_LABELS     comma list of "flag:label" pairs beyond
#                         application/environment, e.g. "host:hostname". Each
#                         pair adds a --<flag> filter (exact label match,
#                         added to the stream selector — not a line filter) and
#                         a breakdown in `stats`. Leave empty if there are no
#                         other indexed labels.
#
# Commands:
#   errors  [N] [filters]          last N lines matching level ERROR (default: 20, lookback 24h)
#   search  <query> [N] [filters]  substring line search (default: 20, lookback 24h)
#   tail    [N] [filters]          recent logs oldest-first (default: 20, lookback 24h)
#   stats   [period]               breakdown by label + best-effort level scan (default: 24h)
#   labels                         list available label names
#   values  <label>                list values seen for a label
#
# Filters (work on errors, search, tail):
#   --level ERROR                  case-insensitive substring line filter
#   --<flag> <value>                filter by any label declared in LOKI_EXTRA_LABELS
#   --query '<LogQL filter>'       raw LogQL piped after the stream selector, e.g. |= "timeout"
#   --since 1h|24h|7d               lookback window (default: 24h)

set -euo pipefail

LOKI_URL="${LOKI_URL:?LOKI_URL not set}"
LOKI_BEARER_TOKEN="${LOKI_BEARER_TOKEN:?LOKI_BEARER_TOKEN not set}"
APP_NAME="${LOKI_APPLICATION_NAME:?LOKI_APPLICATION_NAME not set}"
ENVIRONMENT="${LOKI_ENVIRONMENT:?LOKI_ENVIRONMENT not set}"
EXTRA_LABELS_RAW="${LOKI_EXTRA_LABELS:-}"

QUERY_BASE="${LOKI_URL%/push}"

_loki_get() {
    # $1 = path (e.g. /loki/api/v1/query_range), $2... = -d/--data-urlencode args
    curl -s -u "$LOKI_BEARER_TOKEN" -G "$QUERY_BASE$1" "${@:2}"
}

# Parse "flag:label,flag:label" into two parallel arrays.
EXTRA_FLAG_NAMES=()
EXTRA_LABEL_NAMES=()
if [ -n "$EXTRA_LABELS_RAW" ]; then
    IFS=',' read -ra _pairs <<< "$EXTRA_LABELS_RAW"
    for pair in "${_pairs[@]}"; do
        EXTRA_FLAG_NAMES+=("${pair%%:*}")
        EXTRA_LABEL_NAMES+=("${pair##*:}")
    done
fi

_period_to_seconds() {
    local p="$1" unit="${1: -1}" num="${1%?}"
    case "$unit" in
        s) echo "$num" ;;
        m) echo $((num * 60)) ;;
        h) echo $((num * 3600)) ;;
        d) echo $((num * 86400)) ;;
        *) echo "ERROR: unrecognized period '$p' (use e.g. 30m, 1h, 24h, 7d)" >&2; exit 1 ;;
    esac
}

_parse_common_flags() {
    LEVEL="${LEVEL:-}"
    QUERY_STR="${QUERY_STR:-}"
    SINCE="${SINCE:-24h}"
    declare -gA EXTRA_VALS=()
    EXTRA_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --level) LEVEL="$2"; shift 2 ;;
            --query) QUERY_STR="$2"; shift 2 ;;
            --since) SINCE="$2"; shift 2 ;;
            --*)
                local flag="${1#--}" matched=false i
                for i in "${!EXTRA_FLAG_NAMES[@]}"; do
                    if [ "${EXTRA_FLAG_NAMES[$i]}" = "$flag" ]; then
                        EXTRA_VALS["$flag"]="$2"
                        matched=true
                        break
                    fi
                done
                if [ "$matched" = false ]; then
                    echo "ERROR: unknown flag --$flag (available: level, query, since${EXTRA_FLAG_NAMES[*]:+, $(IFS=,; echo "${EXTRA_FLAG_NAMES[*]}")})" >&2
                    exit 1
                fi
                shift 2
                ;;
            *) EXTRA_ARGS+=("$1"); shift ;;
        esac
    done
}

# Builds the {application="...", environment="...", ...} stream selector.
# Extra labels are matched here (indexed), --level/--query become line filters.
_build_selector() {
    local parts=("application=\"$APP_NAME\"" "environment=\"$ENVIRONMENT\"")
    local i
    for i in "${!EXTRA_FLAG_NAMES[@]}"; do
        local flag="${EXTRA_FLAG_NAMES[$i]}" label="${EXTRA_LABEL_NAMES[$i]}"
        local val="${EXTRA_VALS[$flag]:-}"
        [ -n "$val" ] && parts+=("${label}=\"${val}\"")
    done
    local joined
    joined=$(printf '%s, ' "${parts[@]}")
    echo "{${joined%, }}"
}

_build_line_filters() {
    local filters=""
    if [[ -n "${LEVEL:-}" ]]; then
        local esc="${LEVEL//\"/\\\"}"
        filters+=" |~ \"(?i)${esc}\""
    fi
    if [[ -n "${QUERY_STR:-}" ]]; then
        filters+=" ${QUERY_STR}"
    fi
    echo "$filters"
}

# Reads a Loki query_range response (streams format) from stdin and prints
# "timestamp  line" one per line. Pass "reverse" to print oldest-first.
PRINT_STREAMS='
import json, sys
reverse = sys.argv[1] == "reverse"
data = json.load(sys.stdin)
entries = []
for stream in data.get("data", {}).get("result", []):
    for ts, line in stream.get("values", []):
        entries.append((int(ts), line))
entries.sort(key=lambda e: e[0], reverse=not reverse)
print(f"Total: {len(entries):,}")
for ts, line in entries:
    import datetime
    dt = datetime.datetime.utcfromtimestamp(ts / 1e9).strftime("%Y-%m-%d %H:%M:%S")
    print(f"{dt}  {line[:200]}")
'

cmd="${1:-help}"
shift || true

case "$cmd" in
  errors)
    LEVEL="ERROR"
    _parse_common_flags "$@"
    set -- "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    N="${1:-20}"
    SELECTOR=$(_build_selector)
    LOGQL="${SELECTOR}$(_build_line_filters)"
    NOW_NS=$(date -u +%s%N)
    START_NS=$((NOW_NS - $(_period_to_seconds "$SINCE") * 1000000000))
    _loki_get /loki/api/v1/query_range \
        --data-urlencode "query=$LOGQL" \
        --data-urlencode "limit=$N" \
        --data-urlencode "start=$START_NS" \
        --data-urlencode "end=$NOW_NS" \
        --data-urlencode "direction=backward" \
        | python3 -c "$PRINT_STREAMS" "normal"
    ;;

  search)
    _parse_common_flags "$@"
    set -- "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    if [[ $# -gt 0 && -z "${QUERY_STR:-}" ]]; then
        esc="${1//\"/\\\"}"
        QUERY_STR="|= \"${esc}\""
        shift
    fi
    [[ -z "${QUERY_STR:-}" ]] && { echo "Usage: loki.sh search <query> [N] [filters...]"; exit 1; }
    N="${1:-20}"
    SELECTOR=$(_build_selector)
    LOGQL="${SELECTOR}$(_build_line_filters)"
    NOW_NS=$(date -u +%s%N)
    START_NS=$((NOW_NS - $(_period_to_seconds "$SINCE") * 1000000000))
    _loki_get /loki/api/v1/query_range \
        --data-urlencode "query=$LOGQL" \
        --data-urlencode "limit=$N" \
        --data-urlencode "start=$START_NS" \
        --data-urlencode "end=$NOW_NS" \
        --data-urlencode "direction=backward" \
        | python3 -c "$PRINT_STREAMS" "normal"
    ;;

  tail)
    _parse_common_flags "$@"
    set -- "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    N="${1:-20}"
    SELECTOR=$(_build_selector)
    LOGQL="${SELECTOR}$(_build_line_filters)"
    NOW_NS=$(date -u +%s%N)
    START_NS=$((NOW_NS - $(_period_to_seconds "$SINCE") * 1000000000))
    _loki_get /loki/api/v1/query_range \
        --data-urlencode "query=$LOGQL" \
        --data-urlencode "limit=$N" \
        --data-urlencode "start=$START_NS" \
        --data-urlencode "end=$NOW_NS" \
        --data-urlencode "direction=backward" \
        | python3 -c "$PRINT_STREAMS" "reverse"
    ;;

  stats)
    PERIOD="${1:-24h}"
    SELECTOR=$(_build_selector)
    NOW_NS=$(date -u +%s%N)
    START_NS=$((NOW_NS - $(_period_to_seconds "$PERIOD") * 1000000000))
    CAP=5000
    echo "By level (best-effort substring scan, capped at $CAP lines — Loki has no level label here):"
    _loki_get /loki/api/v1/query_range \
        --data-urlencode "query=$SELECTOR" \
        --data-urlencode "limit=$CAP" \
        --data-urlencode "start=$START_NS" \
        --data-urlencode "end=$NOW_NS" \
        --data-urlencode "direction=backward" \
        | python3 -c '
import json, re, sys
data = json.load(sys.stdin)
counts = {}
levels = ["CRITICAL", "ERROR", "WARNING", "WARN", "INFO", "DEBUG"]
for stream in data.get("data", {}).get("result", []):
    for _, line in stream.get("values", []):
        for lvl in levels:
            if re.search(lvl, line, re.IGNORECASE):
                counts[lvl] = counts.get(lvl, 0) + 1
                break
for lvl, count in sorted(counts.items(), key=lambda x: -x[1]):
    print(f"  {lvl:<10} {count:>10,}")
'
    for i in "${!EXTRA_FLAG_NAMES[@]}"; do
        flag="${EXTRA_FLAG_NAMES[$i]}" label="${EXTRA_LABEL_NAMES[$i]}"
        echo ""
        echo "By ${flag} (${label}):"
        _loki_get /loki/api/v1/query \
            --data-urlencode "query=sum by (${label}) (count_over_time(${SELECTOR}[${PERIOD}]))" \
            --data-urlencode "time=$NOW_NS" \
            | python3 -c '
import json, sys
data = json.load(sys.stdin)
rows = data.get("data", {}).get("result", [])
rows.sort(key=lambda r: -float(r["value"][1]))
for r in rows:
    label_val = next(iter(r.get("metric", {}).values()), "-")
    print(f"  {label_val:<16} {int(float(r[\"value\"][1])):>10,}")
'
    done
    ;;

  labels)
    _loki_get /loki/api/v1/labels | python3 -c '
import json, sys
data = json.load(sys.stdin)
for name in data.get("data", []):
    print(name)
'
    ;;

  values)
    LABEL="${1:?Usage: loki.sh values <label>}"
    _loki_get "/loki/api/v1/label/$LABEL/values" | python3 -c '
import json, sys
data = json.load(sys.stdin)
for v in data.get("data", []):
    print(v)
'
    ;;

  *)
    echo "Usage: docs/loki.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  errors  [N] [filters]          last N lines matching level ERROR (default: 20, lookback 24h)"
    echo "  search  <query> [N] [filters]  substring line search (default: 20, lookback 24h)"
    echo "  tail    [N] [filters]          recent logs oldest-first (default: 20, lookback 24h)"
    echo "  stats   [period]               breakdown by label + best-effort level scan (default: 24h)"
    echo "  labels                         list available label names"
    echo "  values  <label>                list values seen for a label"
    echo ""
    echo "Filters (work on errors, search, tail):"
    echo "  --level ERROR"
    if [ -n "$EXTRA_LABELS_RAW" ]; then
        for f in "${EXTRA_FLAG_NAMES[@]}"; do
            echo "  --$f <value>"
        done
    fi
    echo "  --query '|= \"timeout\"'"
    echo "  --since 1h|24h|7d (default: 24h)"
    echo ""
    echo "Examples:"
    echo "  docs/loki.sh errors 50"
    echo "  docs/loki.sh search 'connection refused' 10"
    echo "  docs/loki.sh tail 30 --level ERROR --since 6h"
    echo "  docs/loki.sh stats 1h"
    echo "  docs/loki.sh labels"
    ;;
esac
