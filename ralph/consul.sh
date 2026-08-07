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
#   get <key>       raw value of a KV key
#   list <prefix>   list keys under a KV prefix

set -euo pipefail

CONSUL_URL="${CONSUL_URL:-http://localhost:8500}"

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

  *)
    echo "Usage: consul.sh <command> [options]"
    echo ""
    echo "Commands:"
    echo "  get <key>       raw value of a KV key"
    echo "  list <prefix>   list keys under a KV prefix"
    echo ""
    echo "Examples:"
    echo "  consul.sh list db/"
    echo "  consul.sh get db/us/host"
    echo "  consul.sh get job_boards/some_key"
    ;;
esac
