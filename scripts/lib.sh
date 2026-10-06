#!/usr/bin/env bash
# Shared defaults for the gateway RLP × backendRef size reproducer.
set -euo pipefail

NS="${NS:-rlp-size-repro}"
GW_NAME="${GW_NAME:-rlp-size-repro}"
RLP_NAME="${RLP_NAME:-gateway-one-rule}"
APPS_DOMAIN="${APPS_DOMAIN:-$(oc get ingresses.config.openshift.io cluster -o jsonpath='{.spec.domain}')}"
GW_HOSTNAME="${GW_HOSTNAME:-${GW_NAME}.${APPS_DOMAIN}}"
GATEWAY_CLASS="${GATEWAY_CLASS:-openshift-default}"

EF_NAME="kuadrant-${GW_NAME}"
LIMITADOR_CM_NS="${LIMITADOR_CM_NS:-kuadrant-system}"
