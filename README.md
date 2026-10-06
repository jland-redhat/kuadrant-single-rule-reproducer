# Reproducer: one gateway RateLimitPolicy copied onto every HTTPRoute rule

Shows that **one** Kuadrant `RateLimitPolicy` on a **Gateway** is expanded into the per-gateway wasm `EnvoyFilter` once per HTTPRoute **rule/match**. Enough routes make that object approach the Kubernetes/etcd ~1.5 MiB cap — the user-facing policy never grew.

Related: [Kuadrant/kuadrant-operator#2051](https://github.com/Kuadrant/kuadrant-operator/issues/2051) (WasmPlugin / EnvoyFilter size). This cluster (RHCL 1.4.3) stores wasm in `EnvoyFilter` `kuadrant-<gateway>`.

## What it proves

| Input | Wasm `actionSets` | EnvoyFilter | Limitador ConfigMap |
| --- | ---: | ---: | ---: |
| 1 gateway limit, 12 HTTPRoutes × 1 rule × 12 `backendRefs` | **12** (backends do **not** multiply) | ~9 KiB | ~8 KiB |
| 1 gateway limit, 12 HTTPRoutes × 12 rules | **144** | 77 KiB | ~8 KiB |
| 1 gateway limit, 20 HTTPRoutes × 16 rules × 7 matches | **2240** copies of the same limit | **1173 KiB (76% of 1.5 MiB)** | **10 KiB** |

Linear fit ≈ 536 bytes/actionSet including JSON envelope. ~2940 actionSets ≈ 1.5 MiB.

On this cluster, scaling from 20 → 28 routes (3136 expected actionSets, ~1.68 MiB) **OOMKilled** `kuadrant-operator` (memory limit 300Mi) before the apiserver/etcd write failed. Same class of bug: gateway policy cost tracks **attached HTTPRoute topology**, not the size of the policy CR.

`scope` in each copy is `rlp-size-repro/<httproute>`, `sources` is always `ratelimitpolicy.kuadrant.io:rlp-size-repro/gateway-one-rule`.

### BackendRefs vs rules

Multiple `backendRefs` on the **same** HTTPRoute rule did **not** create extra wasm actionSets. Fan-out is per **HTTPRoute rule match** (path/header). MaaS model routes often have one backend per rule, so it looks like “per backendRef.”

HTTPRoute CRD: ≤16 rules, ≤16 `backendRefs`/rule, **total matches across a route must be &lt; 128**.

## Cluster notes

- Isolated namespace `rlp-size-repro` (does **not** attach to `maas-default-gateway`).
- Creating the Gateway provisions an AWS NLB.
- After a large grid, **teardown** so the operator can recover (300Mi limit).

## Usage

```bash
# Control: 12 routes × 12 backends on one rule → expect 12 actionSets
./scripts/apply.sh --routes 12 --rules 1 --matches 1 --backends 12
./scripts/measure.sh

# Fan-out: 12 routes × 12 rules
./scripts/apply.sh --routes 12 --rules 12 --matches 1 --backends 1
# HTTPRoute updates can lag; apply.sh annotates the RLP. Re-measure after ~30–90s.

# Size: 20 routes × 16 rules × 7 matches → ~2240 copies, ~1.17 MiB
./scripts/apply.sh --routes 20 --rules 16 --matches 7 --backends 1
./scripts/measure.sh

# Grow until operator OOM or etcd reject (watch kuadrant-operator)
./scripts/scale-until-break.sh --start-routes 12 --rules 16 --matches 7 --backends 1 --step 4 --max-routes 32 --settle-sec 40

./scripts/teardown.sh
```
