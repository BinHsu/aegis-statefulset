# Runbook 02 — AWS bootstrap + chaos demo

**Goal:** Stand up the full Wave 4 architecture on a real AWS account,
run two chaos demo phases (AZ failure + cross-region drill), capture
evidence (Grafana screenshots + dashboard JSON), and tear down.

**Time:** ~3 hours (45 min apply + 45 min Phase 1 demo + 30 min Phase 2 + 30 min teardown + buffer)  
**Cost:** ~$50–100 USD for the live window  
**Trust boundary:** Bin executes; Claude does not hold AWS credentials.

---

## 0. Prerequisites

```bash
aws sts get-caller-identity                       # confirm right account
aws --version                                     # ≥ 2.13
terraform --version                               # ≥ 1.6
kubectl version --client                          # ≥ 1.28
helm version                                      # ≥ 3.13
```

Required IAM permissions for the bootstrap principal:
- VPC, EC2, EKS full
- IAM PassRole + role/policy create
- S3 create + replication config
- KMS key create + alias
- Secrets Manager read/write
- DynamoDB Global Tables create
- DLM lifecycle policy create
- Route 53 hosted-zone read/write
- Budgets + Cost Anomaly Detector (FinOps)
- CloudTrail (already region-scoped)

For POC, an **admin SSO role in a personal/sandbox account** is acceptable.
Production deployment would scope these down per IAM Access Analyzer
findings.

**Cost guard before you start:**

```bash
aws budgets create-budget --account-id $(aws sts get-caller-identity \
  --query Account --output text) --budget '{
  "BudgetName": "aegis-poc-window",
  "BudgetType": "COST",
  "TimeUnit": "MONTHLY",
  "BudgetLimit": {"Amount": "150", "Unit": "USD"}
}'
```

---

## 1. Variables file

Copy and fill `infrastructure/terraform/terraform.tfvars` (gitignored):

```hcl
aws_region          = "eu-central-1"
master_az           = "eu-central-1a"
dr_region           = "eu-west-1"
cluster_name        = "aegis-poc"
domain_name         = ""        # empty for ALB-only; fill if you own a Route 53 zone
grafana_cloud_token = "..."     # from Runbook 04
ecr_account_id      = "...."    # your AWS account ID, for image pull
```

Sensitive values (`grafana_cloud_token`) — store in your shell, not in
the file:

```bash
export TF_VAR_grafana_cloud_token="grl_..."
```

---

## 2. Terraform apply — staged order

Wave 4 introduces ordering constraints that are easy to miss. Apply in
**five stages** to avoid circular dependencies on first run.

### Stage A — VPC, IAM, KMS (no compute)

```bash
cd infrastructure/terraform
terraform init
terraform apply \
  -target=module.vpc \
  -target=aws_iam_role.eks_cluster \
  -target=aws_iam_role.node_group \
  -target=aws_kms_key.stateful \
  -target=aws_kms_key.backup \
  -target=aws_kms_key.observability \
  -target=aws_s3_bucket.velero_backup \
  -target=aws_s3_bucket.velero_backup_dr
# expect: ~5 min
```

### Stage B — EKS control plane + node groups

```bash
terraform apply \
  -target=aws_eks_cluster.main \
  -target=module.node_group_stateful_master \
  -target=module.node_group_stateful_standby_b \
  -target=module.node_group_stateful_standby_c \
  -target=module.node_group_stateless
# expect: ~15 min (cluster create is the long pole)
```

**Verify:** `kubectl get nodes` shows the master AZ nodes Ready and the
two standby AZ node groups at `desired=0` (zero nodes, only the ASG
exists).

```bash
aws eks update-kubeconfig --name aegis-poc --region eu-central-1
kubectl get nodes -L topology.kubernetes.io/zone
# expect: 1-3 nodes labelled eu-central-1a; nothing in -1b or -1c
```

### Stage C — Cluster controllers (Helm releases via terraform)

```bash
terraform apply \
  -target=helm_release.aws_load_balancer_controller \
  -target=helm_release.cluster_autoscaler \
  -target=helm_release.karpenter \
  -target=helm_release.external_secrets \
  -target=helm_release.kyverno \
  -target=helm_release.cert_manager \
  -target=helm_release.velero
# expect: ~10 min
```

**Verify each controller is Running:**

```bash
kubectl get pods -A | grep -E "(aws-load-balancer|kyverno|velero|external-secrets|karpenter|cert-manager)"
# expect: each controller has 1-3 pods, all Running
```

### Stage D — Velero storage IAM

```bash
terraform apply \
  -target=aws_iam_role.velero
# expect: ~2 min
```

Cross-region snapshot copy is handled by Velero's `snapshotMoveData: true` on
the DR-tier `Schedule` CRD (per ADR-04 § dual-cadence pattern) — no AWS DLM
lifecycle policy involved. The cross-region replicated BSL bucket and the
DR-region VolumeSnapshotLocation are provisioned alongside the rest of the
S3 + IAM in Stage E.

### Stage E — Everything else

```bash
terraform apply
# expect: ~5 min for ALB, Route 53, FinOps budgets, CloudTrail
```

---

## 3. Application deploy via Helm

```bash
helm upgrade --install aegis-app helm/aegis-statefulset/ \
  --namespace aegis-app --create-namespace \
  --set master_az=eu-central-1a \
  --set dr_region=eu-west-1 \
  --set stateful.cells.count=1 \
  --wait --timeout 10m
```

**Verify the 3-tier flow:**

```bash
kubectl get pods -n aegis-app -L topology.kubernetes.io/zone
kubectl get pods -n api-tier -L topology.kubernetes.io/zone
kubectl get pods -n envoy   -L topology.kubernetes.io/zone
# expect: every pod's zone label = eu-central-1a (master AZ)
# expect: stateful pod with PVC bound, Velero schedule object created
```

```bash
ALB_HOST=$(kubectl get svc -n api-tier api -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')
curl -X POST "http://${ALB_HOST}/data" -H 'X-Tenant: t1' -d 'k=foo&v=bar'
curl       "http://${ALB_HOST}/data?key=foo" -H 'X-Tenant: t1'
# expect: bar
```

---

## 4. Phase 1 chaos — master AZ failure

Goal: kill the master AZ subnet, watch detection fire, run rotation
script, watch recovery. Capture evidence at three checkpoints — the
`capture-evidence.sh` helper snapshots K8s + Velero + AWS state into
a timestamped directory at each call so the DR report can reference
exact evidence per checkpoint.

```bash
# Pre-demo: open Grafana service-availability dashboard, start screen
# recording, note baseline probe_success = 1.0

# SEED data BEFORE chaos so we can verify integrity after recovery.
# 100 keys is fine for the demo; more is OK too. The manifest lands in
# chaos-evidence/<timestamp>-seed-pre-phase-1/manifest.json and is read
# by every subsequent verify-test-data call.
APP_URL=https://aegis-app.<your-domain> \
  ./scripts/chaos/seed-test-data.sh 100

# Checkpoint 1 of 3 — T+0 baseline
./scripts/chaos/capture-evidence.sh baseline

# Inject the failure (drains node group + deletes subnet)
./scripts/chaos/run-phase-1-az-failure.sh
#   1. records start time
#   2. drains the master AZ stateful node group (desired=0)
#   3. waits for instances + ENIs to clear
#   4. deletes the master AZ subnet (the actual blast)

# Checkpoint 2 of 3 — T+~2 min, subnet deleted
./scripts/chaos/capture-evidence.sh phase-1-subnet-deleted

# Drive recovery (rotation to standby AZ + Velero restore)
./scripts/dr/az-rotation.sh \
  SOURCE_AZ=eu-central-1a \
  TARGET_AZ=eu-central-1b

# Checkpoint 3 of 3 — T+~25 min, recovery complete in new master AZ
./scripts/chaos/capture-evidence.sh phase-1-recovery

# Verify data integrity — reads back each test key, reports match rate
APP_URL=https://aegis-app.<your-domain> \
  ./scripts/chaos/verify-test-data.sh phase-1-recovery
# match rate goes into DR report § 3.5 ({{P1_DATA_MATCH_N}} / {{P1_TEST_KEYS}})
```

**Three Grafana screenshots — capture at each checkpoint** and save into the matching `chaos-evidence/<timestamp>-<label>/` directory as `screenshot-service-availability.png`:

1. **baseline:** probe_success = 1.0, all pods Running
2. **phase-1-subnet-deleted:** probe_success = 0, alerts firing
3. **phase-1-recovery:** probe_success back to 1.0 (now serving from AZ-B)

The `capture-evidence.sh` README inside each checkpoint directory explains
what fields go where in the DR report's Phase 1 section.

---

## 5. Phase 2 chaos — cross-region drill

Goal: simulate primary region loss, drive Layer-3 DR (Route 53 weighted
flip + Velero restore in eu-west-1).

```bash
# Checkpoint 4 of 5 — pre-Phase-2 baseline (post-Phase-1 state)
./scripts/chaos/capture-evidence.sh phase-2-baseline

# Inject the region failure (Route 53 flip + DR-region Velero restore)
./scripts/chaos/run-phase-2-region-drill.sh
#   1. shifts Route 53 weighted record from primary to DR (100/0 -> 0/100)
#   2. triggers velero restore in eu-west-1 from latest cross-region snapshot
#   3. measures end-to-end RTO from cutover to first 200 OK

# Checkpoint 5 of 5 — Phase 2 recovery complete
./scripts/chaos/capture-evidence.sh phase-2-recovery

# Verify data integrity in the DR region (same manifest as Phase 1)
APP_URL=https://aegis-app-dr.<your-domain> \
  ./scripts/chaos/verify-test-data.sh phase-2-recovery
# match rate goes into DR report § 4.4 ({{P2_DATA_MATCH_N}} / {{P2_TEST_KEYS}})
# Note: Phase 2 RPO is the DR-tier cadence (4h default per ADR-04 dual-cadence),
# so some keys written within the last 4h may not have replicated to DR — those
# show up as "missing" in the verify report, NOT mismatches.
```

**Expected:** ~50 min end-to-end RTO. The `phase-2-recovery` checkpoint
captures the DR-region cluster state — verify the resorted pods are in
`eu-west-1` AZs in `k8s-nodes.txt`.

---

## 6. Capture cost + assemble DR report

After teardown completes (see § 7), pull AWS Cost Explorer for the
demo window and assemble the DR report. **Cost Explorer lags ~24 h**
on the current day — for a same-day demo, the cost numbers are
partial; re-run the cost capture the next day for final totals.

```bash
# Cost capture — tagged Project=aegis-statefulset, broken down by service
./scripts/finops/capture-demo-cost.sh
# outputs:
#   chaos-evidence/cost-summary.json (raw Cost Explorer response)
#   chaos-evidence/cost-summary.md   (line-by-line markdown table)

# Hand-fill the operator-specific sections of the DR report:
#   - timing values from capture-evidence/ checkpoint README files
#   - data-integrity verification results
#   - lessons-learned narrative
#   - production-readiness verdict
#
# The template documents which evidence file feeds which placeholder.
$EDITOR chaos-evidence/DR_report.md   # generated by the script below

# Assemble the PDF (auto-fills date/region/git-sha/cost-table; the
# operator-fillable bits are marked [fill in] for you to complete
# in the markdown before re-running this step)
./scripts/dr-report/generate-dr-report.sh
# outputs:
#   chaos-evidence/DR_report.md  (filled-in markdown ready for hand-edit)
#   docs/DR_report.pdf           (rendered PDF, ship-ready)
```

The DR report template is at [`docs/operations/dr-report-template.md`](../dr-report-template.md). It enumerates which evidence file feeds which placeholder, so the hand-fill step is a mechanical walk through the template.

After the demo, the artefacts you reference from any external write-up are:

- `chaos-evidence/<timestamp>-<label>/` — five checkpoint directories with K8s + Velero + AWS state
- `chaos-evidence/cost-summary.{json,md}` — actual spend
- `chaos-evidence/DR_report.md` — filled-in markdown
- `docs/DR_report.pdf` — the rendered report

---

## 7. Teardown — IMPORTANT

EKS clusters are billed by the hour. After demo:

```bash
helm uninstall aegis-app -n aegis-app
# wait for finalizers to release PVCs (Velero finalizer can stick — kubectl patch if so)
kubectl get pvc -n aegis-app
kubectl get pv

terraform destroy
# expect: ~15 min; some resources (KMS keys with deletion window) take longer
```

**Verify nothing orphaned:**

```bash
aws eks list-clusters --region eu-central-1
aws ec2 describe-volumes --filters "Name=tag:Project,Values=aegis-statefulset" \
  --query 'Volumes[].VolumeId'
aws s3 ls | grep aegis    # the velero buckets may take a day for lifecycle to clear
```

KMS keys go into the 7-day deletion window. They continue to incur $1/month
each until that closes — non-zero but bounded.

---

## 8. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `terraform apply` fails on stage A with `OptInRequired` | EKS not enabled in the AWS account | AWS Console → EKS → enable; re-apply |
| Stage B EKS create stuck > 30 min | Subnet routes mis-configured | Check VPC NAT — `kubectl get nodes` failing because nodes can't pull images |
| Velero pods CrashLoopBackOff | IRSA role not attached | Check `aws_iam_role.velero` trust policy includes the EKS OIDC issuer URL |
| `curl ALB` returns 503 | TGB not registering targets | `kubectl get tgb -A`; verify ALB controller logs; common cause = wrong target group ARN in values.yaml |
| Phase 1 rotation script hangs at "waiting for AZ-B node group" | Node group desired=0 didn't scale | Check Karpenter logs; manually `aws eks update-nodegroup-config --desired=N` |
| DLM cross-region copy not happening | Region pair not supported | Check `aws dlm get-lifecycle-policy`; falling back to `interval_unit=HOURS` is fine for POC |
| Cost spiking past $100 | Forgot to teardown previous run | `terraform destroy` immediately; check `aws ec2 describe-volumes` for orphaned EBS |

---

## 9. Tie-back to architecture

This runbook exercises:
- ADR-01 single master AZ topology
- ADR-02 pod-to-PV mapping discipline
- ADR-04 master AZ rotation policy (Wave 4 simplified)
- ADR-04 Velero cold DR
- ADR-04 EBS Snapshot fast restore
- ADR-04 Three-Layer DR

The screenshots from Phases 1 and 2 are the **evidence** the SUBMISSION
references. Architecture without demo evidence is paper-grade; with
evidence is receipt-grade.

---

## 10. Done criteria

- [ ] All Stage A–E terraform apply succeeded
- [ ] 3-tier flow returns 200 OK end-to-end
- [ ] Phase 1 — AZ failure detected within ~2 min, rotated within ~25 min
- [ ] Phase 2 — region cutover completes within ~50 min
- [ ] `chaos-evidence/` populated (screenshots + logs)
- [ ] `terraform destroy` succeeded; no orphaned resources
- [ ] AWS cost report for window < $100
