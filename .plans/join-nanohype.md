# Join nanohype org

Tactical plan for moving `stxkxs/aks-gitops` → `nanohype/aks-gitops`.

Master plan: `/Users/bs/.claude/plans/so-i-want-to-snazzy-sun.md` Phase 1.3.

## Transfer

```sh
gh repo transfer stxkxs/aks-gitops nanohype
git remote set-url origin git@github.com:nanohype/aks-gitops.git
```

## Cross-references to fix

```sh
grep -rn "stxkxs" --include="*.md" --include="*.yaml" --include="*.json"
```

Known references:

- `CLAUDE.md:5` — `azure-aks` is the Bicep/Terraform companion (analogue of `aws-eks` for AKS). Determine whether this lives as a distinct repo or as the AKS path inside `landing-zone`. If distinct, transfer; if landing-zone-resident, update the reference to point at landing-zone's Azure components
- `CLAUDE.md:87` — "Relationship to Parent Repo" section references the same

## App-of-Apps pointer

The AKS infrastructure (Bicep/Terraform) creates the ArgoCD Application pointing here. After transfer, that pointer updates to `https://github.com/nanohype/aks-gitops`.

## Azure-specific OIDC

If CI workflows use Azure Federated Identity Credential, the `subject` field references org/repo (`repo:stxkxs/aks-gitops:ref:refs/heads/main`). Same pattern as landing-zone — update both old and new for a window, then transfer.

## Verification

```sh
gh repo view nanohype/aks-gitops                                       # 200
task validate                                                          # still passes
grep -rn "stxkxs" --include="*.md" --include="*.yaml"                  # zero or intentional only
```

## Notes

- Mirrors eks-gitops structure exactly; transfer should be near-identical mechanics
- Karpenter is AKS Node Auto Provisioning here; that's an Azure concern, no transfer impact
- External Secrets uses `AzureKeyVaultProvider` — no org coupling
