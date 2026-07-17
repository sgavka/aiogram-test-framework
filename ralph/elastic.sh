#!/usr/bin/env bash
# Generic Elasticsearch query helper for the ralph-plane.sh workflow.
# The filterable field set is project-specific and configured entirely via env
# (no per-project script edits needed) — see ELASTIC_EXTRA_FIELDS below.
#
# Usage: docs/elastic.sh <command> [options]
#
# Env:
#   ELASTIC_URL           (default: http://localhost:9200)
#   ELASTIC_APP_INDEX     (default: app-logs-*)
#   ELASTIC_EXTRA_FIELDS  comma list of "flag:field" pairs beyond the built-in
#                         timestamp/level/message, e.g.:
#                           "instance:instance_code,code:code,website:website"
#                         Each pair adds a --<flag> filter (term match on
#                         <field>.keyword) and a [<field>] column in output.
#                         Leave empty for a minimal level-only setup.
#
# Commands:
#   errors  [N] [filters]          last N errors (default: 20)
#   search  <query> [N] [filters]  ES query_string search
#   tail    [N] [filters]          recent logs oldest-first (default: 20)
#   stats   [period]               breakdown by level + configured extra fields (default: 24h)
#   indices                        list app log indices
#
# Filters (work on errors, search, tail):
#   --level ERROR                  filter by level_name (always available)
#   --<flag> <value>               filter by any field declared in ELASTIC_EXTRA_FIELDS
#   --query '<ES query_string>'

set -euo pipefail

ELASTIC_URL="${ELASTIC_URL:-http://localhost:9200}"
APP_INDEX="${ELASTIC_APP_INDEX:-app-logs-*}"
EXTRA_FIELDS_RAW="${ELASTIC_EXTRA_FIELDS:-}"

_es_post() {
    curl -s -X POST "$ELASTIC_URL/$1/_search" \
        -H 'Content-Type: application/json' \
        -d "$2"
}

# Parse "flag:field,flag:field" into two parallel arrays.
EXTRA_FLAG_NAMES=()
EXTRA_FIELD_NAMES=()
if [ -n "$EXTRA_FIELDS_RAW" ]; then
    IFS=',' read -ra _pairs <<< "$EXTRA_FIELDS_RAW"
    for pair in "${_pairs[@]}"; do
        EXTRA_FLAG_NAMES+=("${pair%%:*}")
        EXTRA_FIELD_NAMES+=("${pair##*:}")
    done
fi

SOURCE_FIELDS='["@timestamp", "level_name", "message"'
for f in "${EXTRA_FIELD_NAMES[@]+"${EXTRA_FIELD_NAMES[@]}"}"; do
    SOURCE_FIELDS+=", \"$f\""
done
SOURCE_FIELDS+=']'

# Python hit printer — pass "reverse" or "normal" as first arg.
# Reads ES response JSON from stdin; extra field list comes via env (avoids
# rebuilding the python source string per invocation).
PRINT_HITS='
import json, os, sys
reverse = sys.argv[1] == "reverse"
extra = [p.split(":", 1) for p in os.environ.get("ELASTIC_EXTRA_FIELDS", "").split(",") if p]
data = json.load(sys.stdin)
hits = data.get("hits", {}).get("hits", [])
total = data.get("hits", {}).get("total", {}).get("value", 0)
print(f"Total: {total:,}")
if reverse:
    hits = list(reversed(hits))
for h in hits:
    s = h["_source"]
    ts = s.get("@timestamp", "")[:19].replace("T", " ")
    lvl = s.get("level_name", "-")
    extra_vals = [s.get(field, "-") for _, field in extra]
    extras = "".join(f" [{v}]" for v in extra_vals)
    msg = s.get("message", "")[:150]
    print(f"{ts}  [{lvl}]{extras}  {msg}")
'

_parse_common_flags() {
    LEVEL="${LEVEL:-}"
    QUERY_STR="${QUERY_STR:-}"
    declare -gA EXTRA_VALS=()
    EXTRA_ARGS=()
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --level) LEVEL="$2"; shift 2 ;;
            --query) QUERY_STR="$2"; shift 2 ;;
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
                    echo "ERROR: unknown flag --$flag (available: level, query${EXTRA_FLAG_NAMES[*]:+, $(IFS=,; echo "${EXTRA_FLAG_NAMES[*]}")})" >&2
                    exit 1
                fi
                shift 2
                ;;
            *) EXTRA_ARGS+=("$1"); shift ;;
        esac
    done
}

_build_filters() {
    local parts=()
    [[ -n "${LEVEL:-}" ]] && parts+=("{\"term\": {\"level_name.keyword\": \"$LEVEL\"}}")
    local i
    for i in "${!EXTRA_FLAG_NAMES[@]}"; do
        local flag="${EXTRA_FLAG_NAMES[$i]}" field="${EXTRA_FIELD_NAMES[$i]}"
        local val="${EXTRA_VALS[$flag]:-}"
        [ -n "$val" ] && parts+=("{\"term\": {\"${field}.keyword\": \"$val\"}}")
    done
    if [[ -n "${QUERY_STR:-}" ]]; then
        local escaped="${QUERY_STR//\"/\\\"}"
        parts+=("{\"query_string\": {\"query\": \"$escaped\", \"default_field\": \"message\"}}")
    fi
    local joined
    joined=$(printf '%s,' "${parts[@]+"${parts[@]}"}")
    echo "[${joined%,}]"
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  errors)
    LEVEL="ERROR"
    _parse_common_flags "$@"
    set -- "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    N="${1:-20}"
    FILTERS=$(_build_filters)
    BODY="{\"size\": $N, \"sort\": [{\"@timestamp\": \"desc\"}], \"query\": {\"bool\": {\"filter\": $FILTERS}}, \"_source\": $SOURCE_FIELDS}"
    _es_post "$APP_INDEX" "$BODY" | ELASTIC_EXTRA_FIELDS="$EXTRA_FIELDS_RAW" python3 -c "$PRINT_HITS" "normal"
    ;;

  search)
    _parse_common_flags "$@"
    set -- "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    if [[ $# -gt 0 && -z "${QUERY_STR:-}" ]]; then
        QUERY_STR="$1"; shift
    fi
    [[ -z "${QUERY_STR:-}" ]] && { echo "Usage: elastic.sh search <query> [N] [filters...]"; exit 1; }
    N="${1:-20}"
    FILTERS=$(_build_filters)
    BODY="{\"size\": $N, \"sort\": [{\"@timestamp\": \"desc\"}], \"query\": {\"bool\": {\"filter\": $FILTERS}}, \"_source\": $SOURCE_FIELDS}"
    _es_post "$APP_INDEX" "$BODY" | ELASTIC_EXTRA_FIELDS="$EXTRA_FIELDS_RAW" python3 -c "$PRINT_HITS" "normal"
    ;;

  tail)
    _parse_common_flags "$@"
    set -- "${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"}"
    N="${1:-20}"
    FILTERS=$(_build_filters)
    BODY="{\"size\": $N, \"sort\": [{\"@timestamp\": \"desc\"}], \"query\": {\"bool\": {\"filter\": $FILTERS}}, \"_source\": $SOURCE_FIELDS}"
    _es_post "$APP_INDEX" "$BODY" | ELASTIC_EXTRA_FIELDS="$EXTRA_FIELDS_RAW" python3 -c "$PRINT_HITS" "reverse"
    ;;

  stats)
    PERIOD="${1:-24h}"
    AGGS='{"by_level": {"terms": {"field": "level_name.keyword", "size": 10}}'
    for i in "${!EXTRA_FLAG_NAMES[@]}"; do
        field="${EXTRA_FIELD_NAMES[$i]}"
        AGGS+=", \"by_${field}\": {\"terms\": {\"field\": \"${field}.keyword\", \"size\": 20}}"
    done
    AGGS+='}'
    BODY="{\"size\": 0, \"query\": {\"range\": {\"@timestamp\": {\"gte\": \"now-$PERIOD\"}}}, \"aggs\": $AGGS}"
    _es_post "$APP_INDEX" "$BODY" | ELASTIC_EXTRA_FIELDS="$EXTRA_FIELDS_RAW" python3 -c '
import json, os, sys
data = json.load(sys.stdin)
aggs = data.get("aggregations", {})
extra = [p.split(":", 1) for p in os.environ.get("ELASTIC_EXTRA_FIELDS", "").split(",") if p]
def print_agg(label, key):
    buckets = aggs.get(key, {}).get("buckets", [])
    if not buckets:
        return
    print(f"{label}:")
    for b in sorted(buckets, key=lambda x: -x["doc_count"]):
        key, count = b["key"], b["doc_count"]
        print(f"  {key:<16} {count:>10,}")
    print()
print_agg("By level", "by_level")
for flag, field in extra:
    print_agg(f"By {flag}", f"by_{field}")
'
    ;;

  indices)
    curl -s "$ELASTIC_URL/_cat/indices/${APP_INDEX}?h=index,docs.count,store.size&s=index"
    ;;

  *)
    echo "Usage: docs/elastic.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  errors  [N] [filters]          last N errors (default: 20)"
    echo "  search  <query> [N] [filters]  ES query_string search"
    echo "  tail    [N] [filters]          recent logs oldest-first (default: 20)"
    echo "  stats   [period]               breakdown by level + configured extra fields (default: 24h)"
    echo "  indices                        list app log indices"
    echo ""
    echo "Filters (work on errors, search, tail):"
    echo "  --level ERROR"
    if [ -n "$EXTRA_FIELDS_RAW" ]; then
        for f in "${EXTRA_FLAG_NAMES[@]}"; do
            echo "  --$f <value>"
        done
    fi
    echo '  --query '\''level_name.keyword:"ERROR" AND NOT message:"some message"'\'''
    echo ""
    echo "Examples:"
    echo "  docs/elastic.sh errors 50"
    echo "  docs/elastic.sh search 'connection refused' 10"
    echo '  docs/elastic.sh search --query '\''level_name.keyword:"ERROR" AND NOT message:"Jobs found"'\'' 20'
    echo "  docs/elastic.sh tail 30 --level ERROR"
    echo "  docs/elastic.sh stats 1h"
    ;;
esac
