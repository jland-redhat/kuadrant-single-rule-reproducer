#!/usr/bin/env bash
# Measure wasm EnvoyFilter fan-out for the gateway RateLimitPolicy.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=lib.sh
source "$ROOT/scripts/lib.sh"

python3 - "$NS" "$GW_NAME" "$EF_NAME" "$RLP_NAME" "$LIMITADOR_CM_NS" << 'PY'
import json, subprocess, sys, collections

ns, gw, ef_name, rlp, lim_ns = sys.argv[1:]

def oc_json(*args):
    p = subprocess.run(["oc", *args, "-o", "json"], capture_output=True, text=True)
    if p.returncode != 0:
        print(p.stderr.strip() or p.stdout.strip())
        return None
    return json.loads(p.stdout)

print(f"namespace={ns} gateway={gw} envoyfilter={ef_name}")

routes = oc_json("get", "httproute", "-n", ns)
rlp_obj = oc_json("get", "ratelimitpolicy", rlp, "-n", ns)
ef = oc_json("get", "envoyfilter", ef_name, "-n", ns)

n_routes = len(routes["items"]) if routes else 0
n_rules = n_backends = n_matches = 0
if routes:
    for i in routes["items"]:
        for rule in i.get("spec", {}).get("rules", []):
            n_rules += 1
            n_backends += len(rule.get("backendRefs", []))
            n_matches += max(len(rule.get("matches") or []), 1)
print(f"httproutes={n_routes} rules={n_rules} matches={n_matches} backendRefs={n_backends}")
print(f"expected_actionSets_if_per_match={n_matches} expected_if_per_rule={n_rules} expected_if_per_backend={n_backends}")

if rlp_obj:
    spec = rlp_obj.get("spec", {})
    limits = (spec.get("defaults") or spec.get("overrides") or spec).get("limits", {})
    print(f"gateway_rlp_limits={list(limits)}")
    conds = rlp_obj.get("status", {}).get("conditions", [])
    for c in conds:
        if c.get("type") in ("Accepted", "Enforced"):
            print(f"rlp.{c['type']}={c.get('status')} reason={c.get('reason')} msg={c.get('message','')[:160]}")

if not ef:
    print("envoyfilter=MISSING")
    sys.exit(0)

raw = json.dumps(ef, separators=(",", ":"))
print(f"envoyfilter_json_bytes={len(raw)}")
print(f"envoyfilter_json_kib={len(raw)/1024:.1f}")

action_sets = []
try:
    val = ef["spec"]["configPatches"][0]["patch"]["value"]["typed_config"]["value"]["config"]["configuration"]["value"]
    cfg = json.loads(val)
    action_sets = cfg.get("actionSets", [])
except Exception as e:
    print(f"failed_to_parse_plugin_config: {e}")

print(f"actionSets={len(action_sets)}")
src_counts = collections.Counter()
pred_key = collections.Counter()
for s in action_sets:
    preds = tuple(s.get("routeRuleConditions", {}).get("predicates") or [])
    pred_key[preds] += 1
    for a in s.get("actions", []):
        for src in a.get("sources", []):
            src_counts[src] += 1

print("action_sources:")
for k, v in src_counts.most_common():
    print(f"  {v:6d}  {k}")

unique_preds = len(pred_key)
print(f"unique_routeRuleCondition_predicates={unique_preds}")
if action_sets:
    dup_ratio = len(action_sets) / max(unique_preds, 1)
    print(f"actionSets_per_unique_predicate={dup_ratio:.2f}")
    print(f"avg_actionSet_bytes={sum(len(json.dumps(s, separators=(',', ':'))) for s in action_sets)//len(action_sets)}")
    print("sample_actionSet:")
    print(json.dumps(action_sets[0], indent=2)[:1800])

# Limitador
cms = subprocess.run(
    ["oc", "get", "cm", "-n", lim_ns, "-o", "json"],
    capture_output=True, text=True,
)
if cms.returncode == 0:
    items = json.loads(cms.stdout).get("items", [])
    for cm in items:
        name = cm["metadata"]["name"]
        if "limitador" in name:
            data = cm.get("data") or {}
            blob = "".join(data.values())
            print(f"limitador_cm={lim_ns}/{name} bytes={len(blob)} keys={list(data)}")

print(f"etcd_soft_limit_bytes=1572864  # typical apiserver/etcd ~1.5MiB")
if ef:
    frac = len(raw) / 1572864
    print(f"envoyfilter_fraction_of_1.5MiB={frac:.2%}")
PY
