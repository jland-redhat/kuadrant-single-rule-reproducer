#!/usr/bin/env bash
# Apply isolated Gateway + one RateLimitPolicy + HTTPRoute grid.
# Usage: apply.sh [--routes N] [--rules R] [--backends B]
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

ROUTES=12
RULES=1
BACKENDS=1
MATCHES=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --routes) ROUTES="$2"; shift 2 ;;
    --rules) RULES="$2"; shift 2 ;;
    --backends) BACKENDS="$2"; shift 2 ;;
    --matches) MATCHES="$2"; shift 2 ;;
    --ns) NS="$2"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if (( RULES > 16 || BACKENDS > 16 )); then
  echo "HTTPRoute CRD caps rules and backendRefs at 16 each" >&2
  exit 2
fi
if (( MATCHES > 64 )); then
  echo "HTTPRoute CRD caps matches at 64 per rule" >&2
  exit 2
fi
if (( RULES * MATCHES >= 128 )); then
  echo "HTTPRoute CRD requires rules*matches < 128 (got $((RULES * MATCHES)))" >&2
  exit 2
fi

echo "Applying ns=$NS gateway=$GW_NAME routes=$ROUTES rules/route=$RULES matches/rule=$MATCHES backends/rule=$BACKENDS hostname=$GW_HOSTNAME"

oc get ns "$NS" >/dev/null 2>&1 || oc create ns "$NS"

python3 - "$NS" "$GW_NAME" "$GW_HOSTNAME" "$GATEWAY_CLASS" "$RLP_NAME" "$ROUTES" "$RULES" "$BACKENDS" "$MATCHES" << 'PY' | oc apply -f -
import sys

ns, gw, hostname, gwclass, rlp, routes, rules, backends, matches_n = sys.argv[1:10]
routes, rules, backends, matches_n = int(routes), int(rules), int(backends), int(matches_n)

docs = []

docs.append(f"""apiVersion: v1
kind: Namespace
metadata:
  name: {ns}
  labels:
    repro: rlp-etcd-size
""")

docs.append(f"""apiVersion: apps/v1
kind: Deployment
metadata:
  name: echo
  namespace: {ns}
  labels:
    app: echo
    repro: rlp-etcd-size
spec:
  replicas: 1
  selector:
    matchLabels:
      app: echo
  template:
    metadata:
      labels:
        app: echo
    spec:
      containers:
      - name: echo
        image: registry.access.redhat.com/ubi9/python-312:latest
        ports:
        - containerPort: 8080
        command:
        - python3
        - -c
        - |
          from http.server import BaseHTTPRequestHandler, HTTPServer
          class H(BaseHTTPRequestHandler):
              def do_GET(self):
                  self.send_response(200); self.end_headers(); self.wfile.write(b"ok")
              def do_POST(self):
                  self.do_GET()
              def log_message(self, *args):
                  pass
          HTTPServer(("0.0.0.0", 8080), H).serve_forever()
""")

for i in range(backends):
    name = f"backend-{i:03d}"
    docs.append(f"""apiVersion: v1
kind: Service
metadata:
  name: {name}
  namespace: {ns}
  labels:
    repro: rlp-etcd-size
spec:
  selector:
    app: echo
  ports:
  - name: http
    port: 80
    targetPort: 8080
""")

docs.append(f"""apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: {gw}
  namespace: {ns}
  labels:
    repro: rlp-etcd-size
spec:
  gatewayClassName: {gwclass}
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: {hostname}
    allowedRoutes:
      namespaces:
        from: Same
""")

docs.append(f"""apiVersion: kuadrant.io/v1
kind: RateLimitPolicy
metadata:
  name: {rlp}
  namespace: {ns}
  labels:
    repro: rlp-etcd-size
spec:
  targetRef:
    group: gateway.networking.k8s.io
    kind: Gateway
    name: {gw}
  defaults:
    limits:
      gateway-one-rule:
        rates:
        - limit: 10000
          window: 1m
""")

for r in range(routes):
    route_name = f"route-{r:03d}"
    rule_yaml = []
    for rule in range(rules):
        match_lines = ["        matches:"]
        for m in range(matches_n):
            match_lines.append(f"""        - path:
            type: PathPrefix
            value: /r{r:03d}/u{rule:02d}/m{m:02d}""")
        matches = "\n".join(match_lines)
        bref_lines = ["        backendRefs:"]
        for b in range(backends):
            weight = 1
            bref_lines.append(f"""        - name: backend-{b:03d}
          port: 80
          weight: {weight}""")
        rule_yaml.append("      - \n" + matches + "\n" + "\n".join(bref_lines))
    docs.append(f"""apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: {route_name}
  namespace: {ns}
  labels:
    repro: rlp-etcd-size
spec:
  parentRefs:
  - name: {gw}
    kind: Gateway
    group: gateway.networking.k8s.io
  hostnames:
  - {hostname}
  rules:
{chr(10).join(rule_yaml)}
""")

print("---\n".join(docs))
PY

# Nudge the policy controller: HTTPRoute updates can lag in the wasm EnvoyFilter.
oc annotate ratelimitpolicy "$RLP_NAME" -n "$NS" "repro.touch=$(date -u +%s)" --overwrite >/dev/null
