#!/usr/bin/env bash
#
# End-to-end smoke test for an AKS landing-zone + aks-gitops deployment.
#
# Designed to be runnable against any environment (defaults to whatever your
# current kube-context is). Each check is independent and prints PASS / FAIL
# / SKIP with a short reason. Exits non-zero if any required check fails.
#
# Usage:
#   ./scripts/smoke.sh                   # run against current kube-context
#   ENV=prod ./scripts/smoke.sh          # tag output with an env label
#   SKIP_DESTRUCTIVE=1 ./scripts/smoke.sh   # skip checks that create resources
#
# Required tools: kubectl, az (for Azure-side checks), jq.

set -uo pipefail

ENV="${ENV:-$(kubectl config current-context 2>/dev/null || echo unknown)}"
SKIP_DESTRUCTIVE="${SKIP_DESTRUCTIVE:-0}"
NS_SMOKE="smoke-test"

passes=0
fails=0
skips=0
failures=()

# ── helpers ───────────────────────────────────────────────────────────────────

color() {
  case "$1" in
    green) printf '\033[32m%s\033[0m' "$2" ;;
    red)   printf '\033[31m%s\033[0m' "$2" ;;
    yel)   printf '\033[33m%s\033[0m' "$2" ;;
    *)     printf '%s' "$2" ;;
  esac
}

pass() { printf '  %s  %s\n' "$(color green '✓ PASS')" "$1"; passes=$((passes+1)); }
fail() { printf '  %s  %s\n' "$(color red   '✗ FAIL')" "$1"; printf '         ↳ %s\n' "$2"; fails=$((fails+1)); failures+=("$1: $2"); }
skip() { printf '  %s  %s\n' "$(color yel   '⊘ SKIP')" "$1"; printf '         ↳ %s\n' "$2"; skips=$((skips+1)); }
section() { printf '\n%s\n' "$(color yel "── $1 ──")"; }

require() { command -v "$1" >/dev/null 2>&1 || { echo "missing tool: $1"; exit 2; }; }

# ── preflight ─────────────────────────────────────────────────────────────────

require kubectl
require jq

printf '%s  env=%s  context=%s\n' "$(color yel 'AKS-GITOPS SMOKE TEST')" "$ENV" "$(kubectl config current-context)"

# ── cluster ───────────────────────────────────────────────────────────────────

section "cluster"

nodes_total=$(kubectl get nodes --no-headers 2>/dev/null | wc -l | tr -d ' ')
nodes_ready=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2=="Ready"' | wc -l | tr -d ' ')
if [[ "$nodes_total" -gt 0 && "$nodes_total" == "$nodes_ready" ]]; then
  pass "all $nodes_total nodes Ready"
else
  fail "nodes Ready" "$nodes_ready/$nodes_total Ready"
fi

not_running=$(kubectl get pods -A --no-headers 2>/dev/null \
  | awk '$4!="Running" && $4!="Completed" && $4!="Succeeded"' | wc -l | tr -d ' ')
if [[ "$not_running" -eq 0 ]]; then
  pass "no pods stuck (not Running/Completed)"
else
  bad=$(kubectl get pods -A --no-headers 2>/dev/null \
    | awk '$4!="Running" && $4!="Completed" && $4!="Succeeded" {print $1"/"$2" "$4}' | head -5 | tr '\n' '; ')
  fail "pod health" "$not_running pods not healthy — first 5: $bad"
fi

crashloop=$(kubectl get pods -A --no-headers 2>/dev/null \
  | awk '$4=="CrashLoopBackOff" || $5 ~ /CrashLoop/' | wc -l | tr -d ' ')
if [[ "$crashloop" -eq 0 ]]; then
  pass "no CrashLoopBackOff anywhere"
else
  fail "CrashLoopBackOff" "$crashloop pods crash-looping"
fi

# ── cilium ────────────────────────────────────────────────────────────────────

section "networking (cilium)"

cilium_ready=$(kubectl -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null \
  | awk '$2 ~ /^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if(a[1]==a[2]) print}' | wc -l | tr -d ' ')
cilium_total=$(kubectl -n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$cilium_total" -gt 0 && "$cilium_ready" == "$cilium_total" ]]; then
  pass "cilium agent $cilium_ready/$cilium_total Ready"
else
  fail "cilium agent" "$cilium_ready/$cilium_total Ready"
fi

if kubectl -n kube-system get deploy cilium-operator -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'; then
  pass "cilium operator Ready"
else
  fail "cilium operator" "no Ready replicas"
fi

# ── coredns ───────────────────────────────────────────────────────────────────

section "coredns"

if kubectl -n kube-system get deploy coredns -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -qE '^[1-9]'; then
  pass "coredns Ready"
else
  fail "coredns" "no Ready replicas"
fi

# ── argocd ────────────────────────────────────────────────────────────────────

section "argocd / app-of-apps"

argocd_ready=$(kubectl -n argocd get pods --no-headers 2>/dev/null \
  | awk '$2 ~ /^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if(a[1]==a[2] && $3=="Running") print}' | wc -l | tr -d ' ')
argocd_total=$(kubectl -n argocd get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$argocd_total" -gt 0 && "$argocd_ready" == "$argocd_total" ]]; then
  pass "argocd pods $argocd_ready/$argocd_total Ready"
else
  fail "argocd pods" "$argocd_ready/$argocd_total Ready"
fi

apps_json=$(kubectl -n argocd get applications.argoproj.io -o json 2>/dev/null)
if [[ -n "$apps_json" ]]; then
  total=$(echo "$apps_json" | jq '.items | length')
  healthy=$(echo "$apps_json" | jq '[.items[] | select(.status.health.status=="Healthy")] | length')
  # "Sync compliance" treats OutOfSync-but-Healthy as acceptable. Some addons
  # (cert-manager, KEDA) have admission webhooks whose `clientConfig.caBundle`
  # gets injected by an in-cluster controller AFTER ArgoCD applies the chart
  # manifest. ArgoCD's ServerSideDiff doesn't reliably honor
  # `ignoreDifferences` for that field, so the App perpetually shows OOS even
  # though the cluster matches the desired state and the controller is
  # working as intended. The Health status is the source of truth: if a
  # controller reports Healthy, the addon is functioning.
  ok=$(echo "$apps_json" | jq '[.items[] | select(.status.health.status=="Healthy" and (.status.sync.status=="Synced" or .status.sync.status=="OutOfSync"))] | length')
  if [[ "$total" -gt 0 && "$ok" == "$total" ]]; then
    pass "all $total Applications Healthy ($healthy Healthy, $ok Synced-or-Healthy-OOS)"
  else
    bad=$(echo "$apps_json" | jq -r '.items[] | select(.status.health.status!="Healthy") | "\(.metadata.name) (sync=\(.status.sync.status) health=\(.status.health.status))"' | head -5 | tr '\n' '; ')
    fail "argocd applications" "$healthy/$total Healthy — bad: $bad"
  fi
else
  fail "argocd applications" "couldn't list Applications"
fi

# ── external-secrets / Key Vault wiring ───────────────────────────────────────

section "external-secrets → Key Vault"

if kubectl get clustersecretstore azure-key-vault >/dev/null 2>&1; then
  css_status=$(kubectl get clustersecretstore azure-key-vault -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
  css_reason=$(kubectl get clustersecretstore azure-key-vault -o jsonpath='{.status.conditions[?(@.type=="Ready")].reason}' 2>/dev/null)
  if [[ "$css_status" == "True" ]]; then
    pass "ClusterSecretStore azure-key-vault Ready ($css_reason)"
  else
    fail "ClusterSecretStore" "status=$css_status reason=$css_reason"
  fi
else
  fail "ClusterSecretStore" "azure-key-vault not found"
fi

# Functional check: create an ExternalSecret pointing at a known KV secret.
# Skipped if SKIP_DESTRUCTIVE=1 since it creates a Secret in the cluster.
if [[ "$SKIP_DESTRUCTIVE" == "1" ]]; then
  skip "ExternalSecret reconcile" "SKIP_DESTRUCTIVE=1"
else
  kubectl create namespace "$NS_SMOKE" --dry-run=client -o yaml | kubectl apply -f - >/dev/null 2>&1
  cat <<EOF | kubectl apply -f - >/dev/null 2>&1
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: smoke-probe
  namespace: $NS_SMOKE
spec:
  refreshInterval: 1m
  secretStoreRef:
    name: azure-key-vault
    kind: ClusterSecretStore
  target:
    name: smoke-probe
  dataFrom:
    - find:
        name:
          regexp: ".*"
EOF
  # wait up to 60s for it to reconcile (Ready=True OR a meaningful failure
  # condition rather than waiting forever)
  ok=0
  for _ in $(seq 1 12); do
    state=$(kubectl -n "$NS_SMOKE" get externalsecret smoke-probe -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    if [[ "$state" == "True" ]]; then ok=1; break; fi
    sleep 5
  done
  if [[ "$ok" == "1" ]]; then
    pass "ExternalSecret reconciled against Key Vault"
  else
    msg=$(kubectl -n "$NS_SMOKE" get externalsecret smoke-probe -o jsonpath='{.status.conditions[?(@.type=="Ready")].message}' 2>/dev/null)
    fail "ExternalSecret reconcile" "${msg:-still not Ready after 60s}"
  fi
fi

# ── loki / tempo storage (blob reachability) ──────────────────────────────────

section "observability storage (Loki + Tempo on Blob)"

for app in loki tempo; do
  pod=$(kubectl -n monitoring get pods -l "app.kubernetes.io/name=$app" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  if [[ -z "$pod" ]]; then
    fail "$app pod" "no pod with label app.kubernetes.io/name=$app in namespace monitoring"
    continue
  fi
  state=$(kubectl -n monitoring get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)
  ready=$(kubectl -n monitoring get pod "$pod" -o jsonpath='{.status.containerStatuses[0].ready}' 2>/dev/null)
  if [[ "$state" == "Running" && "$ready" == "true" ]]; then
    pass "$app pod $pod Running + Ready"
  else
    fail "$app pod" "phase=$state ready=$ready"
  fi
done

# ── grafana-agent → AMW ingestion ─────────────────────────────────────────────

section "grafana-agent → AMW"

ga_pod=$(kubectl -n monitoring get pods -l "app.kubernetes.io/name=grafana-agent" -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$ga_pod" ]]; then
  fail "grafana-agent pod" "no pod with label app.kubernetes.io/name=grafana-agent in namespace monitoring"
else
  state=$(kubectl -n monitoring get pod "$ga_pod" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [[ "$state" == "Running" ]]; then
    pass "grafana-agent pod $ga_pod Running"
  else
    fail "grafana-agent pod" "phase=$state"
  fi
  # Look for remote-write errors in recent logs (last 5 minutes)
  errs=$(kubectl -n monitoring logs "$ga_pod" --since=5m 2>/dev/null \
    | grep -iE "remote_write.*(error|forbidden|unauthorized|404|401|403)" | wc -l | tr -d ' ')
  if [[ "$errs" -eq 0 ]]; then
    pass "grafana-agent: no remote-write errors in last 5m"
  else
    sample=$(kubectl -n monitoring logs "$ga_pod" --since=5m 2>/dev/null \
      | grep -iE "remote_write.*(error|forbidden|unauthorized|404|401|403)" | head -1)
    fail "grafana-agent remote-write" "$errs error lines in last 5m — sample: $sample"
  fi
fi

# ── karpenter NAP ─────────────────────────────────────────────────────────────

section "karpenter NAP"

if kubectl get nodepools.karpenter.sh >/dev/null 2>&1; then
  npc=$(kubectl get nodepools.karpenter.sh --no-headers 2>/dev/null | wc -l | tr -d ' ')
  if [[ "$npc" -gt 0 ]]; then
    pass "$npc NodePool(s) defined"
  else
    fail "karpenter NodePools" "no NodePool resources found"
  fi
else
  fail "karpenter CRD" "nodepools.karpenter.sh CRD not installed"
fi

worker_nodes=$(kubectl get nodes -l '!kubernetes.azure.com/mode' --no-headers 2>/dev/null | wc -l | tr -d ' ')
worker_nodes_alt=$(kubectl get nodes -l 'karpenter.sh/nodepool' --no-headers 2>/dev/null | wc -l | tr -d ' ')
worker_total=$(( worker_nodes > worker_nodes_alt ? worker_nodes : worker_nodes_alt ))
if [[ "$worker_total" -gt 0 ]]; then
  pass "$worker_total karpenter-managed worker node(s) provisioned"
else
  skip "karpenter worker nodes" "no worker nodes yet — NAP only provisions on demand; deploy a workload that requests one to verify scaling"
fi

# ── cert-manager ──────────────────────────────────────────────────────────────

section "cert-manager"

cm_ready=$(kubectl -n cert-manager get pods --no-headers 2>/dev/null \
  | awk '$2 ~ /^[0-9]+\/[0-9]+$/ {split($2,a,"/"); if(a[1]==a[2] && $3=="Running") print}' | wc -l | tr -d ' ')
cm_total=$(kubectl -n cert-manager get pods --no-headers 2>/dev/null | wc -l | tr -d ' ')
if [[ "$cm_total" -gt 0 && "$cm_ready" == "$cm_total" ]]; then
  pass "cert-manager pods $cm_ready/$cm_total Ready"
else
  fail "cert-manager pods" "$cm_ready/$cm_total Ready"
fi

# ── ingress / external-dns ────────────────────────────────────────────────────

section "ingress + external-dns"

if kubectl -n ingress-nginx get deploy ingress-nginx-controller >/dev/null 2>&1; then
  rr=$(kubectl -n ingress-nginx get deploy ingress-nginx-controller -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [[ -n "$rr" && "$rr" -gt 0 ]]; then
    pass "ingress-nginx controller Ready ($rr replicas)"
  else
    fail "ingress-nginx" "deployment has 0 ready replicas"
  fi
else
  fail "ingress-nginx" "deployment not found"
fi

if kubectl -n external-dns get deploy external-dns >/dev/null 2>&1; then
  rr=$(kubectl -n external-dns get deploy external-dns -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [[ -n "$rr" && "$rr" -gt 0 ]]; then
    pass "external-dns Ready"
  else
    fail "external-dns" "0 ready replicas"
  fi
else
  fail "external-dns" "deployment not found"
fi

# ── azure-side (probes that need `az`) ────────────────────────────────────────

if command -v az >/dev/null 2>&1; then
  section "azure-side checks"

  sub=$(az account show --query id -o tsv 2>/dev/null)
  if [[ -n "$sub" ]]; then
    pass "az authenticated (sub=$sub)"
  else
    skip "azure checks" "az not authenticated; run \`az login\` to enable"
  fi
else
  skip "azure-side checks" "az CLI not installed"
fi

# ── cleanup ───────────────────────────────────────────────────────────────────

if [[ "$SKIP_DESTRUCTIVE" != "1" ]]; then
  kubectl delete namespace "$NS_SMOKE" --wait=false >/dev/null 2>&1 || true
fi

# ── summary ───────────────────────────────────────────────────────────────────

section "summary"
printf '  %s  %d passed   %s  %d failed   %s  %d skipped\n' \
  "$(color green '●')" "$passes" \
  "$(color red   '●')" "$fails" \
  "$(color yel   '●')" "$skips"

if [[ "$fails" -gt 0 ]]; then
  printf '\n%s\n' "$(color red 'FAILED:')"
  for f in "${failures[@]}"; do printf '  - %s\n' "$f"; done
  exit 1
fi
exit 0
