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

### Stage D — Velero storage + DLM cross-region

```bash
terraform apply \
  -target=aws_iam_role.velero \
  -target=aws_dlm_lifecycle_policy.cross_region_snapshot_copy
# expect: ~2 min
```

**DLM `interval_unit = MINUTES` — known caveat:** AWS may return
`InvalidParameterValue: interval_unit` if your account is in a region
where DLM does not yet support minute-granularity schedules. Fallback:
edit `dlm-cross-region-snapshot-copy.tf` and change `interval_unit` to
`HOURS`, `interval` to `1`. RPO degrades to ~1h instead of ~5min;
acceptable for the demo. Re-apply.

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
script, watch recovery. Capture screenshots from Grafana
service-availability dashboard.

```bash
# Pre-demo: open Grafana service-availability dashboard, start screen
# recording, note baseline probe_success = 1.0

./scripts/chaos/run-phase-1-az-failure.sh
# this script:
#   1. records start time
#   2. detaches the master AZ subnet route table (simulates AZ partition)
#   3. waits for Prometheus alert + ALB health check + Blackbox probe to fire
#   4. prompts you to run scripts/dr/az-rotation.sh
#   5. measures rotation duration to recovery
```

**Three checkpoints — capture screenshot at each:**

1. **T+0:** baseline traffic, probe_success = 1.0
2. **T+~2 min:** subnet detached, probe_success = 0, alerts firing
3. **T+~25 min:** rotation done, probe_success back to 1.0 (in AZ-B)

**Re-attach + cleanup after Phase 1:**

```bash
./scripts/chaos/run-phase-1-az-failure.sh --restore
# re-attaches the route table; system stays in AZ-B as new master per ADR-04
```

---

## 5. Phase 2 chaos — cross-region drill

Goal: simulate primary region loss, drive Layer-3 DR (Route 53 weighted
flip + Velero restore in eu-west-1).

```bash
./scripts/chaos/run-phase-2-region-drill.sh
# this script:
#   1. shifts Route 53 weighted record from primary to DR (100/0 -> 0/100)
#   2. triggers velero restore in eu-west-1 from latest cross-region snapshot
#   3. measures end-to-end RTO from cutover to first 200 OK
```

**Expected:** ~50 min end-to-end RTO. Capture:
- Route 53 weighted-record change confirmation
- Velero restore log
- First successful curl against DR ALB

---

## 6. Capture evidence

```bash
mkdir -p chaos-evidence
kubectl get events --all-namespaces \
  --sort-by='.lastTimestamp' > chaos-evidence/k8s-events.txt
helm get values aegis-app -n aegis-app > chaos-evidence/values-rendered.yaml
kubectl get pdb,statefulset,deployment,svc,ingress -A -o yaml \
  > chaos-evidence/cluster-snapshot.yaml
# screenshots from Grafana go in chaos-evidence/screenshots/
```

The `chaos-evidence/` directory is the artefact you reference in
Runbook 05's submission email.

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
