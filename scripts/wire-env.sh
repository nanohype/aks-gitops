#!/usr/bin/env bash
#
# Wire landing-zone terraform outputs into aks-gitops/addons/**/values-<env>.yaml.
#
# Every addon that authenticates to Azure (cert-manager, external-secrets,
# external-dns, loki, tempo, opencost, keda, velero, argo-events,
# argo-workflows, grafana-agent) needs its ServiceAccount annotated with the
# client_id of its User-Assigned Managed Identity. The grafana-agent also
# needs the AMW remote-write URL, the dashboards overlay needs the Grafana
# + AMW query URLs, and a few addons need storage account names. All of
# those values are emitted by the landing-zone `cluster-addons` and
# `managed-monitoring` components; this script pulls them and rewrites the
# values-<env>.yaml files in place.
#
# Usage:
#   ./scripts/wire-env.sh <cloud> <account> <region> <env>
# Example:
#   ./scripts/wire-env.sh azure workload-prod westus2 prod
#
# Required tools: terragrunt, jq, sed. Run from the aks-gitops repo root;
# expects landing-zone at ../landing-zone.

set -euo pipefail

CLOUD="${1:?missing CLOUD (e.g. azure)}"
ACCOUNT="${2:?missing ACCOUNT (e.g. workload-prod)}"
REGION="${3:?missing REGION (e.g. westus2)}"
ENV="${4:?missing ENV (e.g. prod)}"

LZ="${LANDING_ZONE_PATH:-../landing-zone}/live/$CLOUD/$ACCOUNT/$REGION/$ENV"
if [[ ! -d "$LZ" ]]; then
  echo "FATAL: landing-zone live tree not found at $LZ" >&2
  exit 2
fi

GITOPS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VALUES_GLOB="$GITOPS_ROOT/addons/**/values-$ENV.yaml"
DASHBOARDS_OVERLAY="$GITOPS_ROOT/dashboards/overlays/$ENV/kustomization.yaml"

color() { case "$1" in g) printf '\033[32m%s\033[0m' "$2";; r) printf '\033[31m%s\033[0m' "$2";; y) printf '\033[33m%s\033[0m' "$2";; *) printf '%s' "$2";; esac; }
say() { printf '%s  %s\n' "$(color y '⚙')" "$1"; }
ok()  { printf '%s  %s\n' "$(color g '✓')" "$1"; }

say "pulling cluster-addons outputs"
ADDONS=$(cd "$LZ/cluster-addons" && terragrunt output -json 2>/dev/null)

say "pulling managed-monitoring outputs"
MON=$(cd "$LZ/managed-monitoring" && terragrunt output -json 2>/dev/null)

# Extract values
declare -A CID
while IFS=$'\t' read -r addon id; do CID[$addon]=$id; done < <(
  jq -r '.workload_identity_client_ids.value | to_entries[] | "\(.key)\t\(.value)"' <<<"$ADDONS"
)
CID[grafana-agent]=$(jq -r '.grafana_agent_client_id.value' <<<"$MON")

declare -A SA
while IFS=$'\t' read -r app name; do SA[$app]=$name; done < <(
  jq -r '.storage_accounts.value | to_entries[] | "\(.key)\t\(.value)"' <<<"$ADDONS"
)

SUB=$(jq -r '.amw_id.value' <<<"$MON" | awk -F/ '{print $3}')
RG=$(jq -r '.amw_id.value' <<<"$MON" | awk -F/ '{print $5}')
AMW_RW=$(jq -r '.amw_remote_write_url.value' <<<"$MON")
AMW_Q=$(jq -r '.amw_query_endpoint.value' <<<"$MON")
GRAFANA=$(jq -r '.grafana_endpoint.value' <<<"$MON")

# In-place yaml patch: replace the value on the FIRST line matching `^<indent><key>: <something>` after a section header.
# Simpler: we control the values-<env>.yaml shape, so swap the obvious tokens.
# Use a placeholder substitution for `azure.workload.identity/client-id:` only — that line lives in every file we care about.
patch_client_id() {
  local file="$1" new_id="$2"
  python3 - "$file" "$new_id" <<'PY'
import re, sys
path, new = sys.argv[1], sys.argv[2]
with open(path) as f: data = f.read()
data2 = re.sub(
    r'(azure\.workload\.identity/client-id:\s*)"[^"]*"',
    f'\\1"{new}"', data, count=1
)
if data != data2:
  open(path, 'w').write(data2)
  print(f"  wrote {path}")
PY
}

say "patching workload-identity client IDs"
for addon in cert-manager external-secrets external-dns loki tempo opencost keda velero argo-events argo-workflows grafana-agent; do
  # Resolve the file path by convention
  case "$addon" in
    cert-manager|external-secrets) f="$GITOPS_ROOT/addons/bootstrap/$addon/values-$ENV.yaml" ;;
    external-dns)                  f="$GITOPS_ROOT/addons/networking/external-dns/values-$ENV.yaml" ;;
    loki|tempo|opencost|grafana-agent) f="$GITOPS_ROOT/addons/observability/$addon/values-$ENV.yaml" ;;
    keda|velero)                   f="$GITOPS_ROOT/addons/operations/$addon/values-$ENV.yaml" ;;
    argo-events|argo-workflows)    f="$GITOPS_ROOT/addons/argo-platform/$addon/values-$ENV.yaml" ;;
  esac
  if [[ -f "$f" && -n "${CID[$addon]:-}" ]]; then
    patch_client_id "$f" "${CID[$addon]}"
  fi
done

say "patching grafana-agent AMW URL + cluster name"
python3 - "$GITOPS_ROOT/addons/observability/grafana-agent/values-$ENV.yaml" "$AMW_RW" "${ACCOUNT/-/}-aks" <<'PY'
import re, sys
path, url, cluster = sys.argv[1], sys.argv[2], sys.argv[3]
# cluster naming: env-aks not account-aks; derive from path basename pattern instead
import os
env = os.path.basename(path).replace("values-","").replace(".yaml","")
cluster = f"{env}-aks"
with open(path) as f: data = f.read()
data = re.sub(r'(- name: AMW_REMOTE_WRITE_URL\s+value: ")[^"]+"', f'\\1{url}"', data)
data = re.sub(r'(- name: CLUSTER_NAME\s+value: ")[^"]+"', f'\\1{cluster}"', data)
open(path, 'w').write(data)
print(f"  wrote {path}")
PY

say "patching velero RG / storage account / subscription"
python3 - "$GITOPS_ROOT/addons/operations/velero/values-$ENV.yaml" "$RG" "${SA[velero]}" "$SUB" <<'PY'
import re, sys
path, rg, sa, sub = sys.argv[1:5]
with open(path) as f: data = f.read()
data = re.sub(r'(resourceGroup:\s*).*', f'\\1{rg}', data, count=1)
data = re.sub(r'(storageAccount:\s*).*', f'\\1{sa}', data, count=1)
data = re.sub(r'(subscriptionId:\s*).*', f'\\1{sub}', data, count=1)
open(path, 'w').write(data)
print(f"  wrote {path}")
PY

say "patching argo-workflows artifact endpoint"
python3 - "$GITOPS_ROOT/addons/argo-platform/argo-workflows/values-$ENV.yaml" "${SA[argo_workflows]}" <<'PY'
import re, sys
path, sa = sys.argv[1], sys.argv[2]
with open(path) as f: data = f.read()
data = re.sub(r'(endpoint:\s*https://)[^.]+(\.blob\.core\.windows\.net)', f'\\1{sa}\\2', data, count=1)
open(path, 'w').write(data)
print(f"  wrote {path}")
PY

say "patching loki / tempo storage account names"
for app in loki tempo; do
  f="$GITOPS_ROOT/addons/observability/$app/values-$ENV.yaml"
  python3 - "$f" "${SA[$app]}" "$app" <<'PY'
import re, sys
path, sa, app = sys.argv[1:4]
key = "accountName" if app == "loki" else "storage_account_name"
with open(path) as f: data = f.read()
data = re.sub(f'({key}:\\s*).*', f'\\1{sa}', data, count=1)
open(path, 'w').write(data)
print(f"  wrote {path}")
PY
done

say "patching dashboards overlay Grafana + AMW URLs"
python3 - "$DASHBOARDS_OVERLAY" "$GRAFANA" "$AMW_Q" <<'PY'
import re, sys
path, grafana, amw_q = sys.argv[1:4]
with open(path) as f: data = f.read()
# Replace the two value: lines under the two patch blocks
lines = data.splitlines(keepends=True)
swapped = []
mode = None
for line in lines:
    if 'kind: Grafana' in line: mode = 'grafana'
    elif 'kind: GrafanaDatasource' in line: mode = 'amw'
    if re.match(r'\s+value:\s*https://', line):
        if mode == 'grafana':
            line = re.sub(r'value:\s*\S+', f'value: {grafana}', line); mode = None
        elif mode == 'amw':
            line = re.sub(r'value:\s*\S+', f'value: {amw_q}', line); mode = None
    swapped.append(line)
open(path, 'w').write(''.join(swapped))
print(f"  wrote {path}")
PY

echo
ok "wire-env complete for $ENV"
echo
echo "next:"
echo "  cd $GITOPS_ROOT"
echo "  git diff --stat"
echo "  git add -u && git commit -m 'wire $ENV workload identities + endpoints' && git push"
echo "  task smoke"
