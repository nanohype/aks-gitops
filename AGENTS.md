# aks-gitops — agent entry point

You're an AI client (or the author of one) about to add a cluster-level addon for Azure Kubernetes Service, register a workload as an ApplicationSet entry, or land a Grafana dashboard. This file gets you running in five minutes. For the wider picture — how this repo fits into the nanohype stack — read the [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md).

## What this repo gives you

ArgoCD App-of-Apps catalog for AKS clusters. The Azure-specific cousin of [`eks-gitops`](../eks-gitops/) — same App-of-Apps pattern, same ApplicationSet generators, AKS-specific addon set.

Categories under `addons/`:

- **`argo-platform/`** — Argo CD, Argo Workflows, Argo Rollouts, Argo Events (same as EKS)
- **`bootstrap/`** — cluster bootstrap: cert-manager, external-secrets-operator, metrics-server, azure-workload-identity (instead of IRSA), azure-disk-csi-driver, cluster-autoscaler with AKS-specific config
- **`networking/`** — ingress-nginx, cilium (where supported by Azure CNI), network-policies
- **`observability/`** — kube-prometheus-stack, loki, tempo, azure-monitor-opentelemetry-collector
- **`operations/`** — keda (native AKS integration), descheduler, reloader, vpa
- **`security/`** — kyverno, falco, trivy-operator, gatekeeper

Plus:

- **`applicationsets/`** — ApplicationSet generators that fan addons + tenant workloads out across clusters by label
- **`catalog/`** — per-addon catalog metadata
- **`environments/`** — per-cluster overlays
- **`dashboards/`** — Grafana dashboard JSON
- **`policies/`** — Kyverno + Gatekeeper policies enforced cluster-wide

## Contract surface

Identical to `eks-gitops` — same addon shape, same ApplicationSet pattern, same sync-wave ordering, same per-env values structure. Differences:

- **Identity**: Azure Workload Identity (federated credentials) instead of AWS IRSA. Components in `landing-zone/components/azure/` provision the federated credentials; tenant ServiceAccounts annotate with `azure.workload.identity/client-id`.
- **Storage classes**: AKS uses `managed-csi-premium` / `azure-disk` by default. EKS uses `gp3` / `ebs-csi`.
- **Ingress**: usually ingress-nginx (same as EKS). Application Gateway Ingress Controller is also supported via `addons/networking/agic/` when an AppGW is provisioned by landing-zone.
- **Observability collector**: `azure-monitor-opentelemetry-collector` ships logs to Azure Monitor in addition to Grafana Cloud.

## Add a new addon

Same process as `eks-gitops/AGENTS.md` — see that file for the canonical recipe. Substitute `aks-gitops` paths and Azure-specific defaults where they differ.

## Register a tenant workload

Identical to EKS — the workload's source repo owns its `<app>/gitops/applicationset-entry.yaml`. From this repo's side, register the workload in `applicationsets/apps-tenants.yaml`.

## Conventions

Identical to `eks-gitops/AGENTS.md` (Helm values: 2-space indent, all three env deltas required, sync-wave ordering, Kyverno policies cluster-wide).

## Pointers

- [`README.md`](README.md) — repo overview
- [`docs/`](docs/) — Azure-specific addon notes, AKS bootstrap process
- [`CLAUDE.md`](CLAUDE.md) — Claude Code session instructions
- [Platform Reference](https://github.com/nanohype/nanohype/blob/main/docs/platform-reference.md) — the stack-wide view
- [`eks-gitops/AGENTS.md`](../eks-gitops/AGENTS.md) — the EKS cousin
- [`landing-zone/AGENTS.md`](../landing-zone/AGENTS.md) — `components/azure/*` provisions the substrate this catalog targets
