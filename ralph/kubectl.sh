#!/usr/bin/env bash
# Thin delegator to the sibling k8s-stack repo's own kubectl wrapper
# (scripts/kubectl.sh there) — that script owns the actual SSH-relay-through-
# Proxmox connection to the cluster and its own credentials
# (inventory/secrets.env, gitignored in that repo). Nothing k8s-specific is
# duplicated here; this just locates that repo and execs into it.
#
# Usage: kubectl.sh <kubectl args...>
#
# Env:
#   K8S_STACK_DIR   path to the k8s-stack repo checkout (default: ../k8s-stack
#                   — the two repos are deployed as sibling directories under
#                   /root/projects on the shared VM)

set -euo pipefail

K8S_STACK_DIR="${K8S_STACK_DIR:-../k8s-stack}"
TARGET="$K8S_STACK_DIR/scripts/kubectl.sh"

if [ ! -f "$TARGET" ]; then
    echo "ERROR: $TARGET not found — is k8s-stack checked out as a sibling directory? (K8S_STACK_DIR=$K8S_STACK_DIR)" >&2
    exit 1
fi

if [ ! -f "$K8S_STACK_DIR/scripts/inventory/secrets.env" ]; then
    echo "ERROR: $K8S_STACK_DIR/scripts/inventory/secrets.env not found — k8s-stack's own SSH/Proxmox credentials are not set up on this VM" >&2
    exit 1
fi

exec bash "$TARGET" "$@"
