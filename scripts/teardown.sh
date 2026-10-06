#!/usr/bin/env bash
# Delete the isolated reproducer namespace.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

echo "Deleting namespace $NS (gateway, routes, rlp, dummy backends)"
oc delete ns "$NS" --wait=false --ignore-not-found
echo "Requested deletion of $NS"
