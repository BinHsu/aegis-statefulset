# Region failure recovery — runbook

> Step-by-step procedure for primary-region loss. Aligned with
> ADR-04 (three-path recovery), ADR-04 (cold DR), ADR-04 (Three-Layer DR).
>
> Target RTO: ~50 minutes.
> Target RPO: ≤5 minutes (default cadence) or ≤6 hours (spec ceiling).

This is the runbook for the worst-realistic scenario: the primary region
(eu-central-1, default) is unreachable. The procedure assumes the DR
region (eu-west-1, default) is reachable and that cross-region snapshot
replication is current.

---

## Pre-flight (do once, in advance)

1. Confirm Velero backups are present and recent in the DR region:

   ```bash
   AWS_PROFILE=dr-readonly velero backup get | head
   ```

2. Confirm cross-region snapshot replication lag is within budget:

   ```bash
   aws ec2 describe-snapshots --owner-ids self \
     --region eu-west-1 \
     --filters "Name=tag:aegis.io/role,Values=dr-replica" \
     --query 'Snapshots[?StartTime > `2026-01-01`].[StartTime,SnapshotId]' \
     --output text | head
   ```

3. Confirm the DR Terraform module is committed and applies cleanly in
   plan:

   ```bash
   cd infrastructure/terraform/dr
   terraform init
   terraform plan -var "region=eu-west-1"
   ```

4. Confirm Route 53 hosted zone IDs are recorded in the runbook (this
   document, in Step 6 below).

If any pre-flight item fails, the recovery procedure is degraded — file
a P1 ticket in pre-flight, before the real event.

---

## Step 1 — Declare DR

DR is a *declared* event. The trigger is operator judgment, not a robot.

Criteria for declaration:
- Primary region ALB unreachable for >5 minutes from at least two
  external probe points (internal monitoring + an out-of-region probe).
- AWS Service Health Dashboard reports ongoing primary-region issue,
  OR direct evidence (network partition, IAM region failure).

Action:
- Page the on-call platform engineer + the on-call exec.
- Open an incident ticket with the timeline.
- Begin Step 2.

**Why "declared":** auto-failover at the region level is a footgun. A
brief regional blip can flap traffic; the recovery is non-cheap. The
human keeps the keys.

---

## Step 2 — `terraform apply` in DR region (~25 min)

Bring up the DR-region infrastructure if it is not already standing.

```bash
cd infrastructure/terraform/dr
terraform init -upgrade
terraform plan -out=dr.tfplan -var "region=eu-west-1"
terraform apply dr.tfplan
```

This stands up:
- VPC, subnets, NAT gateways in DR region
- EKS cluster
- IAM roles
- S3 buckets (Velero target, audit log target)
- KMS keys
- ECR replicas (or pull-through to primary; depends on configuration)

Expected duration: ~25 minutes (EKS control plane creation dominates).

If `terraform apply` partial-fails: investigate per error, do *not*
re-apply blindly. EKS partial states are recoverable but require care.

---

## Step 3 — Layer 2 controllers up via Terraform `helm_release` (parallel with Step 2 tail)

Terraform also brings up the Layer-2 controllers via `helm_release`:
- kube-system add-ons
- monitoring (Prometheus + Grafana agent or Grafana Cloud agent)
- kyverno (admission policies)
- ESO (External Secrets Operator)
- ArgoCD (optional — only if customer's ArgoCD is regional)

These come up as part of the same `terraform apply`. Verify:

```bash
aws eks update-kubeconfig --name aegis-statefulset-dr --region eu-west-1
kubectl get pods -A
```

All controllers should be Running before Step 4.

---

## Step 4 — `velero restore` from cross-region snapshots (~15 min)

This is the data plane. Velero restores application namespaces
(aegis-app, api-tier, envoy) with their PVCs, which the EBS CSI driver
reattaches from the cross-region-replicated snapshots.

```bash
LATEST=$(velero backup get -o name | head -n1)
echo "Restoring from: ${LATEST}"

velero restore create "region-recovery-$(date +%s)" \
  --from-backup "${LATEST}" \
  --restore-volumes=true \
  --include-namespaces aegis-app,api-tier,envoy \
  --wait
```

Expected duration: ~15 min (dominated by EBS snapshot rehydrate).

Or, equivalently, run the wrapper script:

```bash
DR_REGION=eu-west-1 \
PRIMARY_REGION=eu-central-1 \
TERRAFORM_DIR=infrastructure/terraform/dr \
scripts/dr/region-failure-recovery.sh --skip-terraform
```

---

## Step 5 — Verify pods Ready

```bash
kubectl get pods -n aegis-app
kubectl get pods -n api-tier
kubectl get pods -n envoy
```

All should be Running with all containers Ready. Pod count must match
the original primary-region count (e.g., 9 stateful pods).

If pods are in CrashLoopBackOff: check pod logs first; the most common
cause is missing secrets (ESO needs to reconcile against the DR-region
backend, which may take a minute or two on first sync).

If PVCs are unbound: check the EBS CSI driver — DR region must have
the same StorageClass with the same KMS key alias. Verify
`kubectl get storageclass`.

---

## Step 6 — Route 53 cutover via `region-cutover.sh`

Cutover is the moment customers see traffic move. By default it runs
in *progressive* mode (100/0 → 75/25 → 25/75 → 0/100 over ~6 minutes).

```bash
HOSTED_ZONE_ID=ZXXXXXXXXXXXXX \
RECORD_NAME=api.aegis.example.com \
PRIMARY_ALB=primary-alb-xxxx.eu-central-1.elb.amazonaws.com \
DR_ALB=dr-alb-xxxx.eu-west-1.elb.amazonaws.com \
PRIMARY_REGION=eu-central-1 \
DR_REGION=eu-west-1 \
MODE=progressive \
scripts/dr/region-cutover.sh
```

For total primary outage (no traffic to keep on primary), use
`MODE=emergency` for an immediate 0/100 step.

---

## Step 7 — Customer comms

| Channel | Action | Owner |
|---|---|---|
| Status page | Update to "service restored in eu-west-1" | on-call exec |
| Customer email | If degraded > 30 min cumulative | customer success lead |
| Internal Slack | Hourly updates until Resolved | on-call platform engineer |
| Post-mortem ticket | File within 24h | on-call platform engineer |

The post-mortem covers what triggered the declaration, what worked,
what didn't, and any cleanup actions for the primary region.

---

## Total RTO ~50 min — breakdown

| Phase | Target | Notes |
|---|---|---|
| Step 1 — Declare | ~5 min | Human decision time |
| Step 2 — Terraform apply | ~25 min | EKS dominates |
| Step 4 — Velero restore | ~15 min | EBS rehydrate dominates |
| Steps 5–6 — Verify + cutover | ~5 min | Usually parallel with tail of Step 4 |
| **Total** | **~50 min** |  |

If any step exceeds 1.5× target, escalate per incident playbook.

---

## Failback (after primary region recovers)

Failback is a *separate* runbook event, not a continuation of recovery.
Asymmetric thresholds (P3 — conservative on recovery) apply:

1. Primary region must be healthy for ≥60 minutes sustained before
   considering failback.
2. Failback requires fresh Velero backup *from DR* to *primary* — DR
   has been the writer; primary is now stale.
3. Failback uses the same `region-cutover.sh` script, with weights
   inverted (100 → primary, 0 → DR).

**Never auto-failback.** A bistable flap is worse than the original
outage.

---

## Cross-reference

- ADR-04 — Three-path recovery
- ADR-04 — Cold DR
- ADR-04 — Three-Layer DR
- `docs/operations/why-cold-dr.md` — architectural reasoning
- `docs/operations/scope-boundaries.md` — what each tool owns
- `scripts/dr/region-failure-recovery.sh` — automated wrapper
- `scripts/dr/region-cutover.sh` — Route 53 cutover
