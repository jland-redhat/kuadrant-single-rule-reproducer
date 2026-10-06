#!/usr/bin/env bash
# Grow HTTPRoute count until the kuadrant EnvoyFilter can no longer be written.
# Usage: scale-until-break.sh [--start-routes 12] [--backends 12] [--rules 1] [--step 12] [--max-routes 240]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

START=12
BACKENDS=1
RULES=16
MATCHES=7
STEP=4
MAX=32
SETTLE_SEC="${SETTLE_SEC:-25}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start-routes) START="$2"; shift 2 ;;
    --backends) BACKENDS="$2"; shift 2 ;;
    --rules) RULES="$2"; shift 2 ;;
    --matches) MATCHES="$2"; shift 2 ;;
    --step) STEP="$2"; shift 2 ;;
    --max-routes) MAX="$2"; shift 2 ;;
    --settle-sec) SETTLE_SEC="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

n="$START"
last_ok=0
while (( n <= MAX )); do
  echo "======== scale routes=$n rules=$RULES matches=$MATCHES backends=$BACKENDS ========"
  if ! "$ROOT/scripts/apply.sh" --routes "$n" --rules "$RULES" --matches "$MATCHES" --backends "$BACKENDS"; then
    echo "APPLY_FAILED at routes=$n"
    break
  fi
  sleep "$SETTLE_SEC"
  # wasm EnvoyFilter often lags HTTPRoute applies; poke the policy spec timestamp
  oc annotate ratelimitpolicy "$RLP_NAME" -n "$NS" "repro.touch=$(date -u +%s)" --overwrite >/dev/null || true
  sleep "$SETTLE_SEC"
  "$ROOT/scripts/measure.sh" || true

  # Detect operator / EnvoyFilter write failures
  if oc get envoyfilter "$EF_NAME" -n "$NS" >/dev/null 2>&1; then
    bytes=$(oc get envoyfilter "$EF_NAME" -n "$NS" -o json | wc -c)
    echo "current_envoyfilter_bytes=$bytes"
    last_ok=$n
  else
    echo "ENVOYFILTER_MISSING after routes=$n (possible size-limit failure)"
    oc logs -n kuadrant-system deploy/kuadrant-operator-controller-manager --tail=80 | grep -Ei 'too large|etcd|ResourceExhausted|limit|wasm|envoyfilter' || true
    break
  fi

  logs=$(oc logs -n kuadrant-system deploy/kuadrant-operator-controller-manager --since=2m 2>/dev/null | grep -Ei 'too large|etcdserver|ResourceExhausted|request is too large|object is too large' || true)
  if [[ -n "$logs" ]]; then
    echo "OPERATOR_SIZE_ERROR:"
    echo "$logs"
    echo "broke around routes=$n rules=$RULES matches=$MATCHES last_ok_routes=$last_ok"
    break
  fi

  n=$((n + STEP))
done

echo "done last_ok_routes=$last_ok"
