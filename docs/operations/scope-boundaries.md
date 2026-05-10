# Scope boundaries — what each tool owns

> Explicit ownership boundaries for the deployment substrate.
> Aligned with ADR-08 (ArgoCD over Flux), ADR-04 (cold DR via Velero),
> ADR-04 (Three-Layer DR).

The submission uses three tools that, naively, overlap in capability:
Terraform, ArgoCD, and Velero. Each is doing a different job. This
document makes the boundary explicit so the reviewer can see that we
considered the question "why don't these step on each other?"

---

## Boundary at a glance

| Tool | Owns | Cadence | Lifecycle |
|---|---|---|---|
| Terraform `helm_release` | Layer-2 controllers (kube-system, monitoring, kyverno, ESO, ArgoCD itself) | At cluster create + on chart bump | Tied to cluster |
| Velero | Layer-1 application namespaces (aegis-app, api-tier, envoy) including PVs | Every 1–60 min (configurable) | Tied to data |
| ArgoCD | Layer-1 application manifests (post-deployment, optional) | Continuous reconcile | Tied to git |

Each layer has one writer. None of the three tools writes a manifest the
other tool also writes. That is the load-bearing rule; everything else
is detail.

---

## Terraform `helm_release` — the controller plane

### What it owns

| Namespace | Controllers |
|---|---|
| `kube-system` | EBS CSI driver, AWS Load Balancer Controller, CoreDNS, kube-proxy add-ons |
| `monitoring` | Prometheus / Grafana agent (or Grafana Cloud agent), node-exporter |
| `kyverno` | Pod Security policies, image-signature policies, cost-tag policies |
| `external-secrets` | ESO operator + the SecretStore CRDs |
| `argocd` | ArgoCD itself (the GitOps controller) — yes, Terraform installs ArgoCD |
| `velero` | Velero itself (the backup controller) — yes, Terraform installs Velero |

### Why Terraform, not GitOps

Two reasons:

1. **Bootstrap problem.** ArgoCD cannot install ArgoCD; Velero cannot
   restore Velero. The control plane has to come from somewhere outside
   the cluster. That somewhere is Terraform.
2. **Release cadence.** Controllers update on a quarterly chart-bump
   cadence. They do not need GitOps' continuous-reconcile loop. A flat
   `terraform apply` aligned with chart upgrades is cleaner.

### What Terraform does NOT manage

- Application Deployment / StatefulSet manifests (those are Helm, but
  released via ArgoCD or `helm upgrade`, not `terraform apply`).
- PV / PVC content (Velero owns data-plane state).
- Routing override delta ConfigMap (live operational state, owned by
  `scripts/dr/warm-routing-table.sh` runs).

---

## Velero — the data-plane backup

### What it owns

| Namespace | Resource types |
|---|---|
| `aegis-app` | StatefulSet, Service, ConfigMap, Secret, PV, PVC (with volume restore) |
| `api-tier` | Deployment, Service, ConfigMap, Secret |
| `envoy` | Deployment, Service, ConfigMap |

Velero takes scheduled snapshots that include both the K8s manifests and
the underlying EBS volume snapshots (cross-region replicated to the DR
region per ADR-04).

### Why Velero, not bespoke

The bespoke alternative is `kubectl get all -A -o yaml | git push` plus
`aws ec2 create-snapshot` scripts. That works until you hit:
- CRD fidelity (Velero handles cluster-scoped CRDs; bespoke doesn't).
- Restore ordering (Velero respects dependency graph; bespoke needs
  hand-coded order).
- PV reattachment (Velero handles claimRef + storage class translation;
  bespoke is fragile).

Velero is the canonical answer; it costs a baseline ~$0/month
(operator only — uses customer's S3 + EBS snapshot quotas).

### What Velero does NOT manage

- Layer-2 controllers (kube-system, monitoring, etc.) — those are
  reconstructed by Terraform `helm_release` in DR.
- ArgoCD applications themselves — restored from Git, not from Velero
  (Velero would back them up, but the source of truth is the Git repo,
  so we exclude them to avoid confusion).
- Live metric history — that lives in Grafana Cloud / Mimir; out of
  scope for backup.

---

## ArgoCD — the live deployment vehicle (optional)

### What it owns

| Path | What |
|---|---|
| `gitops/argocd/applications/aegis-statefulset-dev.yaml` | Dev environment app manifest |
| `gitops/argocd/applications/aegis-statefulset-prod.yaml` | Prod environment app manifest |
| `gitops/argocd/applicationsets/` | Multi-env generator (ADR-08) |

ArgoCD runs the continuous-reconcile loop against the Git repository.
For application namespaces (Layer 1), it is the deployment vehicle.

### Why ArgoCD is optional

Some customers won't have it; some will have Flux instead. The
architecture is GitOps-tool-agnostic — the load-bearing piece is the
*split* between "Terraform manages controllers, GitOps manages apps,"
not the choice of GitOps tool.

If ArgoCD is not adopted, the operator runs `helm upgrade` directly
during deployment. Velero still owns DR; Terraform still owns
controllers. The shape doesn't change.

### What ArgoCD does NOT manage

- Layer-2 controllers (those are Terraform).
- Live data state (that is Velero's domain via PVs).
- Bootstrapping itself (Terraform installs ArgoCD).

---

## Why no double management

The risk we were avoiding: "Terraform writes the StatefulSet, then
ArgoCD reconciles the same StatefulSet from Git, and the two diverge."
The boundary above prevents this:

1. Terraform never writes Layer-1 application manifests.
2. ArgoCD never writes Layer-2 controllers.
3. Velero is read-only for K8s manifests outside the restore path; on
   restore, ArgoCD is paused (ApplicationSet `syncPolicy.automated:
   prune: false` plus an explicit pause annotation per ADR-08).

The decision tree at restore time:

```
Is this a Layer-2 controller? → Terraform reapplies it (or it survives in
                                  the warm DR region).
Is this Layer-1 application?  → Velero restores it (with PV).
Is this Layer-1 + ArgoCD-managed? → Velero restores the runtime state;
                                     ArgoCD takes over reconciliation
                                     after restore completes.
```

There is exactly one writer per resource at any moment.

---

## Cross-reference

- ADR-08 — GitOps tool choice (ArgoCD over Flux)
- ADR-08 — ApplicationSet environment promotion
- ADR-04 — Cold DR via Velero + EBS snapshot
- ADR-04 — Three-Layer DR
- `docs/operations/region-failure-recovery.md` — runbook applying these boundaries
- `docs/operations/why-cold-dr.md` — architectural rationale
