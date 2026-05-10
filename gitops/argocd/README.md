# GitOps with ArgoCD

This directory holds ArgoCD `AppProject` and `Application` manifests that drive every cluster change through git. The pattern is intentionally minimal — three Applications and one AppProject — so the model stays legible and the production sync gate stays explicit.

## Bootstrap

One-time setup per cluster:

```bash
# 1. Install ArgoCD itself (chart pinned per ADR-09).
helm repo add argo https://argoproj.github.io/argo-helm
helm install argocd argo/argo-cd \
  --version 6.7.18 \
  --namespace argocd \
  --create-namespace

# 2. Apply the AppProject (RBAC + scope boundaries).
kubectl apply -n argocd -f gitops/argocd/projects/aegis-statefulset.yaml

# 3. Apply Applications (observability first; it's the canary for the GitOps loop).
kubectl apply -n argocd -f gitops/argocd/applications/observability-stack.yaml
kubectl apply -n argocd -f gitops/argocd/applications/aegis-statefulset-dev.yaml

# 4. Production application — apply the manifest, but DO NOT trigger sync until
# the cluster is fully provisioned and a maintenance window is open.
kubectl apply -n argocd -f gitops/argocd/applications/aegis-statefulset-prod.yaml
```

After step 3, the dev environment self-syncs on every commit to `main`. After step 4, the prod manifest exists in ArgoCD as `OutOfSync` until an operator runs `argocd app sync aegis-statefulset-prod` deliberately.

## Sync policy at a glance

| Application | Sync mode | Self-heal | Why |
|---|---|---|---|
| `aegis-statefulset-dev` | automated | on | Dev is a disposable integration target. Drift recovery is desired. |
| `aegis-statefulset-prod` | manual | off | Stateful tier — data on EBS is the only irreplaceable asset (P1). Operator approves every change. |
| `observability-stack` | automated | on | Stateless. Prometheus PVCs are disposable telemetry, not customer state. |

The asymmetric policy is the point. ArgoCD self-heal on a stateful tier creates a controller-driven path to stomp on a running database during a transient drift signal. For prod the cost of one accidental restart of a primary pod outweighs the convenience of auto-reconciliation. We trade that convenience for a human-in-the-loop checkpoint on every production change.

## Drift detection workflow

ArgoCD continuously compares cluster state to git. Drift on prod surfaces as `OutOfSync` in the Argo UI but does not auto-correct.

```bash
# Show all applications and their sync status.
argocd app list

# Inspect prod drift in detail.
argocd app diff aegis-statefulset-prod

# Resource-by-resource breakdown.
argocd app get aegis-statefulset-prod --show-params
```

Drift on prod is one of three things:
1. **Legitimate emergency hotfix applied directly to the cluster** — must be back-ported to git within the same on-call shift, then sync'd.
2. **HPA-managed replica count or PVC online expansion** — already filtered via `ignoreDifferences` in the prod Application manifest.
3. **Unauthorised change** — investigate via Kubernetes audit log + GuardDuty (per ADR-07); do not paper over with `--force`.

## Manual sync procedure for prod

```bash
# 1. Check what will change.
argocd app diff aegis-statefulset-prod

# 2. If the diff is expected, dry-run the sync.
argocd app sync aegis-statefulset-prod --dry-run

# 3. Run the sync. Use `--prune` only when explicitly intended.
argocd app sync aegis-statefulset-prod

# 4. Watch the sync to completion (timeout 10 min).
argocd app wait aegis-statefulset-prod --timeout 600
```

For a stateful change (StatefulSet template update, PVC schema change, storage class), the human-in-the-loop step also verifies:

- A backup completed successfully within the last `backup.cadence_minutes` window.
- The change is rolling out to one cell at a time (`maxUnavailable: 1` in the chart).
- An on-call engineer is at a keyboard.

## Rollback procedure

```bash
# List recent revisions.
argocd app history aegis-statefulset-prod

# Roll back to a specific revision (`<id>` from the history command above).
argocd app rollback aegis-statefulset-prod <id>
```

For dev, rollback is rarely needed — a forward-fix commit auto-syncs in seconds. For prod, rollback is the first option for any anomaly within the first 30 minutes; longer than that, the standard recovery paths in ADR-04 take over (Path A / B / C).

## Adding new environments

Today there are two environments (`dev`, `prod`) and one shared `observability` Application. To add a third (`staging`, `canary`, regional clone, …) the recommended pattern is `ApplicationSet` with a list generator — one source of truth for environment-shaped applications.

```yaml
# Future work — see https://argo-cd.readthedocs.io/en/stable/operator-manual/applicationset/
apiVersion: argoproj.io/v1alpha1
kind: ApplicationSet
metadata:
  name: aegis-statefulset-envs
  namespace: argocd
spec:
  generators:
    - list:
        elements:
          - env: dev
            namespace: aegis-app-dev
            valuesFile: values-dev.yaml
            autoSync: true
          - env: prod
            namespace: aegis-app
            valuesFile: values-prod.yaml
            autoSync: false
  template:
    metadata:
      name: 'aegis-statefulset-{{env}}'
    spec:
      # … same shape as the per-environment Application manifests …
```

This is deliberately deferred for the POC — three flat Application manifests are easier to read and audit than one templated ApplicationSet. The pattern unlocks once a third environment makes the duplication burdensome.

## Why ArgoCD over Flux

Documented in full in ADR-08. Short version:

- **UI surface** — ArgoCD's web UI is invaluable for the manual-sync prod gate. Operators can review diffs, sync history, and rollout state without dropping into kubectl.
- **AppProject RBAC model** — granular per-project, per-action policies (see `projects/aegis-statefulset.yaml` `roles:` block). Maps cleanly to "dev engineers can sync dev, only the platform team can sync prod."
- **Health checks for stateful workloads** — built-in resource health phases (`Healthy`, `Degraded`, `Progressing`, `Suspended`) align with how StatefulSet rollouts actually behave. Custom Lua health checks available where needed.
- **Sync hooks** — pre-sync / sync / post-sync / post-delete phases let us run database migrations, Restic checkpoints, or DR drills in lockstep with the application rollout.
- **Notifications** — first-class Argo Notifications controller lands directly in Slack / OpsGenie / PagerDuty (per ADR-06).

Flux is competent and arguably more "GitOps-native" in a strict reading, but the operator-facing UI gap and the RBAC model are the reasons we land on ArgoCD here. Both are CNCF graduated; this is not a religious choice.

## Honest scope statement

ArgoCD experience in this repository is portfolio-level — installed, configured, manifests authored, sync flows documented. Production-scale operational experience (multi-tenant ArgoCD with hundreds of Applications, ApplicationSet generators driving regional rollouts, custom resource health Lua plugins, Argo Rollouts blue/green orchestration) is not claimed. The patterns here are correct for the scale of this submission; they would be rebuilt or deepened during the first quarter of a real production deployment.
