# CLAUDE.md — aks-gitops

## Overview

AKS-specific GitOps configuration for ArgoCD addon lifecycle management. Part of a multi-cloud strategy (`eks-gitops`, `gke-gitops`, `aks-gitops`). Companion to [azure-aks](https://github.com/stxkxs/azure-aks) (Bicep/Terraform infrastructure).

## Directory Structure

```
applicationsets/       → ArgoCD ApplicationSets (App-of-Apps pattern, 10 total)
addons/                → Addon configurations
  <category>/<addon>/
    # Helm addons (majority):
    values.yaml            → Base Helm values (all environments)
    values-dev.yaml        → Dev delta overrides
    values-staging.yaml    → Staging delta overrides
    values-production.yaml → Production delta overrides
    # Kustomize addons (storage-classes, priority-classes, karpenter-resources):
    base/                  → Kustomization + resource manifests
    overlays/{dev,staging,production}/
                           → Environment-specific kustomization.yaml
policies/              → Kyverno ClusterPolicy manifests (pure Kustomize, base/overlays)
environments/          → Cluster-config ConfigMaps per environment (includes provider field)
catalog/               → Platform-specific workloads (Druid)
```

## Key Conventions

### Sync Waves
Components deploy in order: bootstrap (0, 2) → networking (1) → karpenter (5) → security (10-12) → policies (20-21) → observability (30-33) → operations (40-44) → argo-platform (50-52).

### Helm Values Pattern
Helm addons use a flat directory with ArgoCD multi-source. Each addon has `values.yaml` (base) plus `values-{env}.yaml` (delta only). ApplicationSets reference them via:
```yaml
helm:
  valueFiles:
    - $values/{{ .path }}/values.yaml
    - $values/{{ .path }}/values-{{ index .metadata.labels "environment" }}.yaml
```
Environment-specific values files contain ONLY differences from base — not a full copy.

### Kustomize Addons
Three addons use pure Kustomize (no Helm): storage-classes, priority-classes, karpenter-resources. These use the `base/overlays` pattern with `kustomization.yaml` in each overlay directory. Kyverno policies also use pure Kustomize (resources + JSON patches for enforcement mode).

### ApplicationSet Generator
All 10 ApplicationSets use `matrix` generator combining `clusters` selector with a `list` of addons. Two template styles: Helm multi-source (for Helm addons with `$values` ref) and single-source with Kustomize path (for Kustomize addons and policies). Environment is read from cluster secret labels: `{{ index .metadata.labels "environment" }}`.

## Azure-Specific Notes

- **Workload Identity:** Service accounts use `azure.workload.identity/client-id` annotations to map to Azure AD identities (analogous to IRSA on EKS).
- **Karpenter:** Runs as AKS Node Auto Provisioning (NAP) — Microsoft manages the operator in the AKS control plane. This repo only authors `AKSNodeClass` (group `karpenter.azure.com`) and `NodePool` (group `karpenter.sh`) CRs via `addons/operations/karpenter-resources/`. The cluster must be created with `node_provisioning_profile.mode = "Auto"` and BYO CNI (`network_plugin = "none"`).
- **Storage:** `managed-csi` (default) and `managed-csi-premium` StorageClasses use `disk.csi.azure.com`. Velero uses Azure Blob Storage.
- **Ingress:** `ingress-nginx` is the default ingress controller (cloud-agnostic). For AKS-native ingress, swap in Application Gateway Ingress Controller (AGIC).
- **External DNS:** Provider `azure` reading from a managed `Microsoft.Network/dnszones`.
- **Secrets:** External Secrets uses `AzureKeyVaultProvider` (ClusterSecretStore named `azure-key-vault`).
- **Region naming:** `westus2`, `eastus`, etc. (no AWS-style `us-west-2`).

## Making Changes

### Modifying addon values
**Helm addons:** Edit `values.yaml` for base changes, `values-{env}.yaml` for environment-specific deltas.
**Kustomize addons:** Edit resources in `base/` for base changes, overlay `kustomization.yaml` for environment-specific patches.
Run `task validate` to verify.

### Adding a new addon
**Helm:** Create `addons/<category>/<name>/` with `values.yaml` + three `values-{env}.yaml` files. Add to the appropriate Helm ApplicationSet.
**Kustomize:** Create `addons/<category>/<name>/base/` + three overlay directories. Add to the appropriate Kustomize ApplicationSet.
Categories: `bootstrap`, `networking`, `security`, `observability`, `operations`, `argo-platform`.
See `docs/configuration/adding-addons.md` for full guide.

### Adding a new policy
1. Create policy YAML in `policies/kyverno/<group>/base/`
2. Add to base kustomization.yaml resources list
3. Overlay patches control enforcement mode per environment

## Validation Commands

```bash
task lint:yaml              # YAML lint all files
task kustomize:build        # Build all overlays (all environments)
task kustomize:build:env    # Build overlays for ENVIRONMENT (default: dev)
task validate               # Lint + build combined
task render                 # Render manifests to rendered/ directory
```

## Relationship to Parent Repo

- This is the AKS variant of a multi-cloud GitOps strategy
- `azure-aks` (Bicep/Terraform) deploys ArgoCD and creates the App-of-Apps Application pointing to this repo
- Bootstrap addons (cert-manager, external-secrets, etc.) are managed by this repo at wave 0
- Cluster secret labels (set by IaC) drive environment selection in ApplicationSets

## CI

- PR and push to main trigger `.github/workflows/ci.yml` (lint → validate per environment → PR summary)
- Manual diff rendering available via `.github/workflows/diff.yml`

## Claude Code Tooling

### Commands
- `/validate` — Run `task validate` (lint + kustomize build all environments), diagnose failures
- `/add-addon` — Scaffold a new addon (Helm flat values or Kustomize base/overlays)
- `/add-policy` — Scaffold a new Kyverno ClusterPolicy (base + 3 overlays + ApplicationSet entry)
- `/render` — Render manifests for an environment via `task render`
- `/diff-envs` — Compare rendered output between two environments
- `/chart-versions` — Audit Helm chart versions across all ApplicationSets, flag drift
- `/check-overlay` — Verify environment values files contain only deltas from base

### Agents
- **validator** — Runs 8 structural checks: YAML lint, kustomize build, chart version consistency, overlay delta compliance, structural completeness, ApplicationSet integrity, sync wave ordering, policy enforcement modes

### Guarded Operations
- **Allowed**: `task`, `yamllint`, `kustomize`, `helm search/repo`, `diff`, file rendering
- **Denied**: `kubectl`, `argocd`, `helm install/upgrade/uninstall/delete`, `az` — this is a config repo, no cluster mutation
- **Hooks**: YAML files are auto-linted on save; edits to `rendered/` are blocked (generated output)
