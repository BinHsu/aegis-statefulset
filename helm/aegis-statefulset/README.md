# aegis-statefulset Helm Chart

Helm chart for stateful Kubernetes workload management on AWS EKS:
multi-AZ active-passive HA, configurable RPO via backup cadence,
Strangler-Fig migration support at the infrastructure layer.

## Architectural Anchors

- **ADR-01**: Per-tenant pod model (one pod per workspace)
- **ADR-01**: Cell-based architecture (cells across AZs)
- **ADR-02**: EBS sizing + LVM online expand
- **ADR-03**: Consistent hash with override delta routing
- **ADR-04**: Backup cadence configurable (default 1h)
- **ADR-04**: Active-passive periodic refresh HA
- **ADR-07**: Network policies (zero trust default-deny)
- **ADR-07**: Pod security via Kyverno
- **ADR-09**: SHA-pinned images via Renovate updates

## Install

```bash
# Validate chart syntax
helm lint helm/aegis-statefulset/

# Render templates without applying
helm template aegis helm/aegis-statefulset/ -f helm/aegis-statefulset/values-dev.yaml

# Install (dev)
helm upgrade --install aegis helm/aegis-statefulset/ \
  -n aegis --create-namespace \
  -f helm/aegis-statefulset/values-dev.yaml

# Install (prod)
helm upgrade --install aegis helm/aegis-statefulset/ \
  -n aegis --create-namespace \
  -f helm/aegis-statefulset/values-prod.yaml \
  --set backup.bucket_source=$(terraform output -raw backup_bucket) \
  --set backup.bucket_dr=$(terraform output -raw backup_dr_bucket)
```

## Customisation

The `values.yaml` exposes the cost matrix knobs from the architecture
consensus document. Three principal trade-off axes:

1. **Backup cadence** (`backup.cadence_minutes`): 5m (default) / 1h / 6h
2. **HA model** (`ha.model`): `cold_dr` (single mode in current architecture; active-passive retired per ADR-04)
3. **DR region** (`dr_region`): cross-region target for EBS Snapshot copy via DLM

Cost tiers (approximate, EUR/month at POC `cells.count=1` scale):

| Configuration | Cost |
|---|---|
| Cold DR + 5-min cadence (default) | ~€2,700 |
| Cold DR + 1-hour cadence | ~€2,500 |
| Cold DR + 6-hour cadence | ~€2,400 |
| (rejected) active-passive multi-region | ~€8,500 |

## Validation

```bash
# Helm lint
helm lint helm/aegis-statefulset/

# Kubeconform per ADR-08
helm template aegis helm/aegis-statefulset/ \
  | kubeconform -strict -summary -kubernetes-version 1.29.0

# Anonymisation gate per ADR-08 — CI runs the canonical check from
# .github/workflows/anonymisation.yml. The pattern lives there, not here,
# so this README itself stays brand-clean.
make anonymisation-check  # or: bash scripts/ci/anonymisation-check.sh
```

## Operational Notes

- The application image is the **POC mock binary** (`aegis-stateful-mock`).
  Replace with the real application image SHA before production rollout
  per ADR-09 supply-chain discipline.
- Backups are orchestrated by the Velero `Schedule` CRDs
  (`templates/velero-schedule-operational.yaml` and
  `templates/velero-schedule-dr.yaml`), not by per-pod CronJobs —
  see ADR-04 dual-cadence pattern.
- HA model is **cold DR via Velero + EBS Snapshot** — no standby
  StatefulSet pods. AZ rotation runs via
  `aws eks update-nodegroup-config` + Velero restore (see
  `docs/adr/ADR-04-backup-dr-and-ha.md`).
