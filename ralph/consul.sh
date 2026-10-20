#!/usr/bin/env bash
# Generic Consul KV helper for the ralph-plane.sh workflow. Primary use case:
# reading per-tenant database credentials that live in Consul KV instead of
# a project .env (jobscanner-new and jobscanner-python share the same tenant
# databases, so credentials are centralized in Consul rather than duplicated
# across both repos' .env files).
#
# Usage: consul.sh <command> [options]
#
# Env:
#   CONSUL_URL   (default: http://localhost:8500)
#
# Commands:
#   get <key>           raw value of a KV key
#   list <prefix>       list keys under a KV prefix
#   put <key> <value>   write a KV key (prompts before touching a prod prefix)
#   delete <key>        delete a KV key (prompts before touching a prod prefix)
#
# Writes to a key whose path contains "prod" require an interactive "yes"
# confirmation. Set CONSUL_ALLOW_PROD=1 to skip that prompt in a non-interactive
# context (a deliberate opt-in, so an accidental prod write cannot happen by
# default from a script or an agent).

set -euo pipefail

CONSUL_URL="${CONSUL_URL:-http://localhost:8500}"
CONSUL_ALLOW_PROD="${CONSUL_ALLOW_PROD:-0}"

confirm_prod() {
    local key="$1" action="$2"
    case "$key" in
        *prod*) ;;
        *) return 0 ;;
    esac
    if [ "$CONSUL_ALLOW_PROD" = "1" ]; then
        echo "WARNING: $action production key $key (CONSUL_ALLOW_PROD=1)" >&2
        return 0
    fi
    echo "About to $action PRODUCTION key: $key" >&2
    printf 'Type "yes" to continue: ' >&2
    local answer=""
    read -r answer || true
    if [ "$answer" != "yes" ]; then
        echo "Aborted." >&2
        exit 1
    fi
}

cmd="${1:-help}"
shift || true

case "$cmd" in
  get)
    KEY="${1:?Usage: consul.sh get <key>}"
    if ! curl -sf "$CONSUL_URL/v1/kv/$KEY?raw"; then
        echo "ERROR: key not found in Consul KV: $KEY" >&2
        exit 1
    fi
    echo
    ;;

  list)
    PREFIX="${1:?Usage: consul.sh list <prefix>}"
    curl -sf "$CONSUL_URL/v1/kv/${PREFIX}?keys" || {
        echo "ERROR: could not list under $PREFIX" >&2
        exit 1
    }
    echo
    ;;

  put)
    KEY="${1:?Usage: consul.sh put <key> <value>}"
    if [ "$#" -lt 2 ]; then
        echo "Usage: consul.sh put <key> <value>" >&2
        exit 1
    fi
    VALUE="$2"
    confirm_prod "$KEY" "OVERWRITE"
    if ! curl -sf -X PUT --data-binary "$VALUE" "$CONSUL_URL/v1/kv/$KEY" >/dev/null; then
        echo "ERROR: could not write $KEY" >&2
        exit 1
    fi
    echo "OK: $KEY"
    ;;

  delete)
    KEY="${1:?Usage: consul.sh delete <key>}"
    confirm_prod "$KEY" "DELETE"
    if ! curl -sf -X DELETE "$CONSUL_URL/v1/kv/$KEY" >/dev/null; then
        echo "ERROR: could not delete $KEY" >&2
        exit 1
    fi
    echo "DELETED: $KEY"
    ;;

  *)
    echo "Usage: consul.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  get <key>           raw value of a KV key"
    echo "  list <prefix>       list keys under a KV prefix"
    echo "  put <key> <value>   write a KV key"
    echo "  delete <key>        delete a KV key"
    echo ""
    echo "Writes touching a *prod* key ask for an interactive \"yes\"."
    echo "Set CONSUL_ALLOW_PROD=1 to opt out of that prompt."
    echo ""
    echo "Examples:"
    echo "  consul.sh list db/"
    echo "  consul.sh get db/us/host"
    echo "  consul.sh get job_boards/some_key"
    echo "  consul.sh put ats/prod/SESSION_DRIVER redis"
    echo "  consul.sh delete ats/prod/SESSION_LEFITIME"
    ;;
esac
