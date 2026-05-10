# Drift Detection and Remediation

This runbook covers how the platform notices when the cluster has diverged from git and how operators put it back. Drift is the central feature ArgoCD provides over push-based deployment; this file is the operator's manual for the alert that says "your prod is OutOfSync."

## What is drift

Drift is any divergence between **declared state in git** (Helm values + ApplicationSet template render) and **observed state on the cluster** (live resource manifests as the API server reports them).

Three classes:

1. **Unauthorised drift.** Someone ran `kubectl edit deployment ...` or `helm install` outside ArgoCD. The live state changed; git did not.
2. **Controller-managed drift.** A legitimate Kubernetes controller mutated a field after Helm rendered it — HPA touched `spec.replicas`, the storage controller resized a PVC after online expansion, an admission webhook injected sidecars. Git renders one value; the controller persists another.
3. **Sync-in-flight drift.** ArgoCD started a sync but hasn't finished. Status shows `Progressing`; transient.

The first class is the security-relevant one. The second class is expected and filtered via `ignoreDifferences`. The third resolves itself.

## How ArgoCD detects drift

ArgoCD reconciles every Application every 3 minutes by default (configurable per Application). Each reconcile:

1. Fetches the manifest from `repoURL` at `targetRevision`.
2. Renders Helm / Kustomize / plain manifests.
3. Diffs the rendered manifests against live cluster state via the K8s API.
4. Sets `Application.status.sync.status` to `Synced` or `OutOfSync`.
5. Sets `Application.status.health.status` to `Healthy` / `Degraded` / `Progressing` / `Suspended` / `Missing`.

`OutOfSync` + `Healthy` is the most common drift signal — the cluster is running, but not running the manifest from git.

## Auto-heal vs manual sync (per environment)

Per ADR-08, the sync posture is split:

| Env | Auto-sync | Self-heal | Drift response |
|---|---|---|---|
| dev | yes | yes | ArgoCD reverts the drift on the next reconcile (≤3 min). Operators rarely see drift here. |
| staging | yes | yes | Same as dev. Drift is a transient signal at most. |
| prod | no | no | Drift surfaces in the UI as `OutOfSync` and STAYS there until an operator manually syncs (or back-ports the change to git, then syncs). |
| observability | yes | yes | Stateless telemetry; drift recovery is desired. |
| platform policies | yes | yes | Drift on a security policy is itself a security event — auto-recovery is the right posture (see `policies.yaml`). |

The asymmetry is the design point: aggressive recovery on stateless tiers, human checkpoint on stateful prod. ADR-08's "Trade-offs accepted" walks through why.

## Investigating drift

Standard sequence for "prod shows OutOfSync, why?":

```bash
# 1. List affected resources at a glance.
argocd app get aegis-statefulset-prod

# 2. Resource-level diff (rendered manifest vs live).
argocd app diff aegis-statefulset-prod

# 3. Per-resource detail.
argocd app get aegis-statefulset-prod --show-params --refresh

# 4. Cross-reference the K8s audit log for who/what mutated the resource.
#    Audit log lookup is per-cluster — see `docs/runbooks/audit-log-query.md`
#    (out of POC; runbook stub).
kubectl logs -n kube-system --tail=200 -l component=audit | \
  grep '<resource-name>' | jq .

# 5. If the change is on a managed field, check the managedFields metadata
#    on the live resource — Server-Side Apply records who owns each field.
kubectl get <resource> <name> -n <ns> -o json | jq '.metadata.managedFields'
```

The `managedFields` query is the one that resolves "the controller did it" vs "a human did it." If `manager: argocd-controller`, the field is ArgoCD-owned and the drift is internal (and weird — file an issue). If `manager: kube-controller-manager` or another known controller, the drift is class 2 (controller-managed). If `manager: kubectl-edit` or similar, the drift is class 1 (unauthorised).

## Common drift causes and remediation

### Cause 1: kubectl edit by a human

Symptom: `argocd app diff` shows a config field changed; `managedFields.manager: kubectl-edit`.

**Remediation (dev/staging — auto-sync env):** None needed. Auto-sync reverts within 3 min. The edit was reverted; the human has been "talked back to" by the controller.

**Remediation (prod — manual sync):**
1. Identify the engineer (audit log + chat the team).
2. Decide: was the change legitimate (emergency fix) or accidental?
3. **Legitimate:** back-port to git as a PR within the same on-call shift. After PR merge, run the manual sync to make git the source of truth again.
4. **Accidental:** run `argocd app sync aegis-statefulset-prod` to revert the cluster to the git-declared state. File a follow-up ticket if the engineer needs RBAC adjustment (ArgoCD AppProject roles per `projects/aegis-statefulset.yaml`).

### Cause 2: Helm release outside ArgoCD

Symptom: `helm list -A` shows a release that doesn't appear in any ArgoCD Application.

This is class 1 drift on a larger surface — someone ran `helm install` directly. ArgoCD diffs against the cluster, so the orphan release shows up as resources that don't appear in any Application but exist on the cluster.

**Remediation:**
1. Confirm the orphan release: `helm list -A | grep -v argocd`.
2. Decide if the orphan should become a managed Application (back-port the values to git, add a new Application manifest) or be removed.
3. If removing: `helm uninstall <release> -n <namespace>` after confirming it's not load-bearing.
4. File a ticket: how did the orphan land? Audit log + RBAC review.

### Cause 3: HPA-managed replica count

Symptom: `argocd app diff` shows `spec.replicas` differs between git and live.

This is expected. HPA is the desired-state controller for replica count; Helm declares an *initial* replica count, but HPA's recommendation supersedes it within the configured range.

**Remediation:** Already handled. The prod Application's `ignoreDifferences` block (see `gitops/argocd/applications/aegis-statefulset-prod.yaml`) tells ArgoCD to ignore `/spec/replicas` on StatefulSet — so HPA management does not surface as drift.

```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    jsonPointers:
      - /spec/replicas
```

If a new resource type is added that HPA also manages (e.g., a Deployment in the stateless tier), extend `ignoreDifferences` accordingly. Not extending it leads to spurious drift alerts that operators learn to ignore — which then masks real drift.

### Cause 4: PVC online expansion

Symptom: `argocd app diff` shows `spec.resources.requests.storage` differs between git and live (live is larger).

LVM-backed online expansion (per ADR-02) increases PVC size on the live cluster. Git's Helm values still declare the original size.

**Remediation:** Already handled. The `ignoreDifferences` block ignores `/spec/resources/requests/storage` on PVC for the same reason.

```yaml
ignoreDifferences:
  - group: ""
    kind: PersistentVolumeClaim
    jsonPointers:
      - /spec/resources/requests/storage
```

The principle generalises: when a controller is the source of truth for a field at runtime, `ignoreDifferences` declares that ArgoCD is *not* the source of truth for that field. The split must be explicit; silence creates ambiguity.

### Cause 5: Admission webhook injection

Symptom: `argocd app diff` shows fields that Helm didn't render but exist on the live resource — sidecar containers, init containers, security-context defaults, label injections.

Common injectors: Istio sidecar injector, Linkerd, Datadog Cluster Agent, OPA Gatekeeper mutation policies, Kyverno mutate rules.

**Remediation options:**
1. **Render the injected fields explicitly in Helm.** Most legible; eliminates the drift entirely. Cost: Helm template grows.
2. **Use Server-Side Apply with field manager handoff.** SSA respects `managedFields` ownership, so the webhook's manager retains its fields without ArgoCD overwriting them. Already enabled via `ServerSideApply=true` in `syncOptions`.
3. **Add `ignoreDifferences` for the injected fields.** Right answer when the injection is contractually outside the application's scope (mesh sidecars).

### Cause 6: ArgoCD UI edit

Symptom: A field changed on the cluster; `managedFields.manager: argocd-server` (UI), not `argocd-application-controller` (controller).

Someone edited a resource via the ArgoCD UI's resource action menu. Per ADR-08's trade-offs, this is a real foot-gun — the edit lives on the cluster but not in git.

**Remediation:**
1. The AppProject's `read-only` role (`gitops/argocd/projects/aegis-statefulset.yaml`) prevents this for most users, but `argocd-admin` retains write capability.
2. If the edit happened: same as Cause 1 — back-port to git or revert to git.
3. Periodic audit: `kubectl get applications.argoproj.io -A -o json | jq '.items[].status.history'` shows sync history including UI-initiated syncs.

## Allowed drift via `ignoreDifferences`

The current allowlist (from `aegis-statefulset-prod.yaml`):

```yaml
ignoreDifferences:
  - group: apps
    kind: StatefulSet
    jsonPointers:
      - /spec/replicas              # HPA owns this
  - group: ""
    kind: PersistentVolumeClaim
    jsonPointers:
      - /spec/resources/requests/storage   # online expansion (ADR-02)
```

Every entry MUST have a comment explaining why ArgoCD shouldn't reconcile the field. "We see drift here sometimes, just ignore it" is not a valid reason — the comment must name the controller or system that owns the field.

## Escalation criteria

Open a ticket and page the on-call engineer if:

- Prod drift on the StatefulSet template (not `/spec/replicas`) — the stateful tier is data-affecting.
- Prod drift on a SecurityContext, NetworkPolicy, RBAC, or PSS field — security boundary may have been weakened.
- Prod drift older than 24 hours without a remediation plan — ADR-08's alert threshold.
- Repeated drift on the same resource within 24 hours — points to a misconfigured controller or a webhook fight.

The ADR-06 alerting stack already includes a rule for "stateful Application OutOfSync > 24h" — this runbook is the playbook the alert links to.

## Related

- ADR-02 (LVM + online PVC expansion — explains the PVC-size drift exception)
- ADR-04 (Recovery paths — when drift remediation reveals data damage, escalate to ADR-04)
- ADR-06 (Alerting — the OutOfSync > 24h alert points here)
- ADR-07 (NetworkPolicy — drift on policy fields is escalation-worthy)
- ADR-07 (PSS + Kyverno — drift on security-context fields is escalation-worthy)
- ADR-08 (GitOps via ArgoCD — sync policy split that motivates per-env drift posture)
- `gitops/argocd/README.md` (manual sync procedure for prod)
- `docs/gitops/promotion-model.md` (promotion PR model; rollback via revert)
