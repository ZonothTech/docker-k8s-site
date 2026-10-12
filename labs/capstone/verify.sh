#!/usr/bin/env bash
#
# Capstone scorecard — Containers & Kubernetes Fundamentals, Lab 10.
#
#   bash ~/docker-kubernetes-training/labs/capstone/verify.sh [namespace]
#
# Default namespace: pinboard-prod. Every check is read-only; the script never
# creates, patches or deletes anything. Exit code 0 when everything passes.
#
set -uo pipefail

NS="${1:-pinboard-prod}"
INGRESS_HOST="pinboard.localtest.me"
INGRESS_URL="http://localhost/api/info"

PASSED=0
FAILED=0

if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_NO=$'\033[31m'; C_HD=$'\033[1m'; C_DIM=$'\033[2m'; C_RS=$'\033[0m'
else
  C_OK=''; C_NO=''; C_HD=''; C_DIM=''; C_RS=''
fi

section() { printf '\n%s%s%s\n' "$C_HD" "$1" "$C_RS"; }

pass() {
  PASSED=$((PASSED + 1))
  printf '  %sPASS%s  %s\n' "$C_OK" "$C_RS" "$1"
}

fail() {
  FAILED=$((FAILED + 1))
  printf '  %sFAIL%s  %s\n' "$C_NO" "$C_RS" "$1"
  if [ "$#" -gt 1 ] && [ -n "$2" ]; then
    printf '        %shint: %s%s\n' "$C_DIM" "$2" "$C_RS"
  fi
}

# check <description> <expected-substring|-> <hint> -- <kubectl args...>
# Runs kubectl, passes when the output is non-empty and (when given) contains
# the expected substring.
check() {
  local desc="$1" want="$2" hint="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  local out
  out="$(kubectl "$@" 2>/dev/null)"
  if [ -z "$out" ]; then
    fail "$desc" "$hint"
    return 1
  fi
  if [ "$want" != "-" ] && [ "${out#*"$want"}" = "$out" ]; then
    fail "$desc (got: ${out:0:60})" "$hint"
    return 1
  fi
  pass "$desc"
  return 0
}

is_num() { case "${1:-}" in '' | *[!0-9]*) return 1 ;; *) return 0 ;; esac; }

# check_min <description> <minimum> <hint> -- <kubectl args...>
check_min() {
  local desc="$1" min="$2" hint="$3"; shift 3
  [ "${1:-}" = "--" ] && shift
  local out
  out="$(kubectl "$@" 2>/dev/null)"
  if is_num "$out" && [ "$out" -ge "$min" ]; then
    pass "$desc (${out})"
    return 0
  fi
  fail "$desc (got: '${out}', need >= ${min})" "$hint"
  return 1
}

printf '%s================================================================%s\n' "$C_HD" "$C_RS"
printf '%s Pinboard capstone verification — namespace: %s%s\n' "$C_HD" "$NS" "$C_RS"
printf '%s================================================================%s\n' "$C_HD" "$C_RS"

if ! command -v kubectl >/dev/null 2>&1; then
  printf '\n  kubectl not found in PATH — nothing to verify.\n\n'
  exit 2
fi
if ! kubectl version -o yaml >/dev/null 2>&1 && ! kubectl get --raw /version >/dev/null 2>&1; then
  printf '\n  Cannot reach a cluster. Is the kind cluster running?\n'
  printf '    kind get clusters && kubectl config use-context kind-pinboard\n\n'
  exit 2
fi

# ---------------------------------------------------------------- namespace --
section '1. Namespace, quota and limits'

check "Namespace ${NS} exists" "$NS" \
  "kubectl apply -f 00-namespace.yaml" \
  -- get ns "$NS" -o jsonpath='{.metadata.name}'

check "Namespace enforces the restricted Pod Security Standard" "restricted" \
  "add label pod-security.kubernetes.io/enforce=restricted to the Namespace" \
  -- get ns "$NS" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}'

check "ResourceQuota present" "-" \
  "kubectl -n ${NS} create quota ... or write a ResourceQuota manifest" \
  -- -n "$NS" get resourcequota -o jsonpath='{.items[*].metadata.name}'

check "LimitRange present" "-" \
  "a LimitRange gives containers default requests/limits" \
  -- -n "$NS" get limitrange -o jsonpath='{.items[*].metadata.name}'

# ------------------------------------------------------------------- config --
section '2. Configuration and credentials'

check "Secret pinboard-db has POSTGRES_PASSWORD" "-" \
  "kubectl create secret generic pinboard-db --from-literal=... --dry-run=client -o yaml" \
  -- -n "$NS" get secret pinboard-db -o jsonpath='{.data.POSTGRES_PASSWORD}'

check "Secret pinboard-db has DATABASE_URL" "-" \
  "the API reads DATABASE_URL from the Secret via secretKeyRef" \
  -- -n "$NS" get secret pinboard-db -o jsonpath='{.data.DATABASE_URL}'

check "ConfigMap pinboard-api-config present" "-" \
  "APP_GREETING / APP_THEME / LOG_FORMAT belong in a ConfigMap" \
  -- -n "$NS" get configmap pinboard-api-config -o jsonpath='{.metadata.name}'

# ------------------------------------------------------------------ database --
section '3. Database tier'

check_min "StatefulSet pinboard-db is ready" 1 \
  "kubectl -n ${NS} describe sts pinboard-db and check the Pod events" \
  -- -n "$NS" get statefulset pinboard-db -o jsonpath='{.status.readyReplicas}'

check "Headless Service pinboard-db (clusterIP: None)" "None" \
  "a StatefulSet needs a headless Service named in spec.serviceName" \
  -- -n "$NS" get service pinboard-db -o jsonpath='{.spec.clusterIP}'

check "A PersistentVolumeClaim is Bound" "Bound" \
  "use volumeClaimTemplates; check 'kubectl -n ${NS} describe pvc'" \
  -- -n "$NS" get pvc -o jsonpath='{.items[*].status.phase}'

# ----------------------------------------------------------------------- api --
section '4. API tier'

check_min "Deployment pinboard-api has >= 2 available replicas" 2 \
  "kubectl -n ${NS} rollout status deploy/pinboard-api" \
  -- -n "$NS" get deployment pinboard-api -o jsonpath='{.status.availableReplicas}'

check "pinboard-api declares a readiness probe" "readyz" \
  "readinessProbe.httpGet.path: /readyz" \
  -- -n "$NS" get deployment pinboard-api \
  -o jsonpath='{.spec.template.spec.containers[*].readinessProbe.httpGet.path}'

check "pinboard-api declares a liveness probe" "healthz" \
  "livenessProbe.httpGet.path: /healthz" \
  -- -n "$NS" get deployment pinboard-api \
  -o jsonpath='{.spec.template.spec.containers[*].livenessProbe.httpGet.path}'

check "pinboard-api sets resources.limits.memory" "-" \
  "kubectl explain deployment.spec.template.spec.containers.resources" \
  -- -n "$NS" get deployment pinboard-api \
  -o jsonpath='{.spec.template.spec.containers[*].resources.limits.memory}'

check "pinboard-api sets resources.requests.cpu (needed by the HPA)" "-" \
  "without a CPU request the HPA reports <unknown>/50%" \
  -- -n "$NS" get deployment pinboard-api \
  -o jsonpath='{.spec.template.spec.containers[*].resources.requests.cpu}'

check "pinboard-api runs as non-root" "true" \
  "securityContext.runAsNonRoot: true on the Pod or the container" \
  -- -n "$NS" get deployment pinboard-api \
  -o jsonpath='{.spec.template.spec.securityContext.runAsNonRoot}{.spec.template.spec.containers[*].securityContext.runAsNonRoot}'

check "Service pinboard-api has ready endpoints" "-" \
  "the Service selector must match the Pod labels" \
  -- -n "$NS" get endpointslices -l "kubernetes.io/service-name=pinboard-api" \
  -o jsonpath='{.items[*].endpoints[*].addresses[0]}'

check "PodDisruptionBudget present" "-" \
  "policy/v1 PodDisruptionBudget with minAvailable: 2" \
  -- -n "$NS" get poddisruptionbudget -o jsonpath='{.items[*].metadata.name}'

check "HorizontalPodAutoscaler present" "-" \
  "autoscaling/v2 HPA targeting Deployment pinboard-api" \
  -- -n "$NS" get horizontalpodautoscaler -o jsonpath='{.items[*].metadata.name}'

# ----------------------------------------------------------------- web/edge --
section '5. Web tier and ingress'

check_min "Deployment pinboard-web has >= 1 available replica" 1 \
  "kubectl -n ${NS} rollout status deploy/pinboard-web" \
  -- -n "$NS" get deployment pinboard-web -o jsonpath='{.status.availableReplicas}'

check "Service pinboard-web has ready endpoints" "-" \
  "the Service selector must match the Pod labels" \
  -- -n "$NS" get endpointslices -l "kubernetes.io/service-name=pinboard-web" \
  -o jsonpath='{.items[*].endpoints[*].addresses[0]}'

check "Ingress is served on host ${INGRESS_HOST}" "$INGRESS_HOST" \
  "add 'host: ${INGRESS_HOST}' to the rule in your Ingress" \
  -- -n "$NS" get ingress -o jsonpath='{.items[*].spec.rules[*].host}'

# --------------------------------------------------------------- end-to-end --
section '6. End to end'

if command -v curl >/dev/null 2>&1; then
  BODY="$(curl -fsS --max-time 10 -H "Host: ${INGRESS_HOST}" "$INGRESS_URL" 2>/dev/null)"
  if [ -z "$BODY" ]; then
    fail "GET ${INGRESS_URL} through the ingress" \
      "is ingress-nginx running? kubectl -n ingress-nginx get pods"
    fail "API reports store=postgres" "fix the ingress first"
  else
    pass "GET ${INGRESS_URL} through the ingress"
    if [ "${BODY#*\"store\":\"postgres\"}" != "$BODY" ]; then
      pass "API reports store=postgres"
    else
      fail "API reports store=postgres (got: ${BODY:0:80})" \
        "DATABASE_URL must reach the pinboard-db Service"
    fi
  fi
else
  fail "curl not installed — skipped the end-to-end check" "install curl"
  fail "API reports store=postgres — skipped" "install curl"
fi

check_min "Job pinboard-smoke completed successfully" 1 \
  "kubectl -n ${NS} logs job/pinboard-smoke" \
  -- -n "$NS" get job pinboard-smoke -o jsonpath='{.status.succeeded}'

# ------------------------------------------------------------------- score ---
TOTAL=$((PASSED + FAILED))
printf '\n%s================================================================%s\n' "$C_HD" "$C_RS"
if [ "$FAILED" -eq 0 ]; then
  printf '%s SCORE: %d/%d — all checks passed. Pinboard is production-shaped.%s\n' \
    "$C_OK" "$PASSED" "$TOTAL" "$C_RS"
else
  printf '%s SCORE: %d/%d — %d check(s) still to fix.%s\n' \
    "$C_NO" "$PASSED" "$TOTAL" "$FAILED" "$C_RS"
  printf ' Method: kubectl get -> describe -> logs -> get events --sort-by=.lastTimestamp\n'
fi
printf '%s================================================================%s\n\n' "$C_HD" "$C_RS"

[ "$FAILED" -eq 0 ]
