# Demo evidence

Artefacts captured during the staging-environment deploy + chaos demo.
Each file pairs with a documented architectural claim somewhere in the
repo; the table below maps evidence → claim → reproduction path.

## Files in this directory

| File | What it shows | Claim it backs |
|---|---|---|
| `chaos-stateful-pod-kill.log` | End-to-end log of `scripts/chaos/demo-stateful-pod-kill.sh` — six stages from baseline through pod kill to PV-identity verification. Includes timestamps, pod UIDs, PV names, node placement, and a `PASSED` summary. | ADR-04 (backup, DR & HA) — stateful-tier resilience to pod-level chaos; EBS volumes re-attach to the recreated pod within ~65 s. |
| `grafana-1-stack.png` | Grafana Cloud Free-tier stack landing page (`aegis.grafana.net`), EU realm (`prod-eu-west-4`). | ADR-06 (observability) — observability backend provisioned via Terraform (`grafana_cloud_stack.main`, see `infrastructure/terraform/grafana-cloud.tf`). |
| `grafana-2-dashboards-list.png` | Dashboards landing page listing the eight default dashboards. | ADR-06 — dashboards-as-code pipeline (`gitops/grafana/dashboards/` → `grafana_dashboard.default[*]`). |
| `grafana-3-service-availability-nodata.png` | The `service-availability` dashboard opened — panel grid for RED-method golden signals visible, every panel reports "No data". | ADR-06 + Known Limitations — panel structure + PromQL queries ship via IaC; live metric flow into Mimir/Loki/Tempo deferred (the in-cluster `kube-prometheus-stack` failed install during the staging deploy; root cause logged in the apply log). |
| `cloudwatch/` (directory) | AWS-native observability slice — EBS volume IO, EKS audit log events, DynamoDB placement table metrics, EKS control-plane metrics list. Captured via `scripts/chaos/capture-cloudwatch-evidence.sh`. | Two-tier observability story: the in-cluster Prometheus stack is deferred (Grafana panels "No data"), but the AWS-infra layer is observable today via CloudWatch. See `cloudwatch/` highlights below. |
| `cloudwatch-1-audit-pod-delete.png` | CloudWatch Logs Insights tabular view of pod-delete API events in the chaos window — two rows, both `responseStatus.code = 200`: the operator delete and the kubelet follow-up cleanup. Human-readable counterpart to `cloudwatch/eks-audit-pod-delete.json`. | Same as the JSON — but rendered in the AWS console so a non-engineering reviewer can confirm the events exist without parsing JSON. |
| `cloudwatch-2-ebs-volume-io.png` | CloudWatch Metrics time-series graph for both PVs (`vol-0042e05180ed3d8e2` data + `vol-08d398a8f06c8e7a0` wal) over the chaos window — VolumeAvgIOPS / VolumeAvgWriteLatency. The trough/spike around the pod-kill timestamp visualises the EBS detach → re-attach cycle. | Counterpart to the per-volume EBS JSON files in `cloudwatch/`. |

### CloudWatch highlights (`cloudwatch/`)

| File | What it shows |
|---|---|
| `eks-audit-pod-delete.json` | The two pod-delete API events bracketing the chaos demo, both `response 200`: (1) **13:44:27 UTC** — operator `AWSControlTowerExecution/aegis-thu-demo` issuing `kubectl delete pod` (the chaos trigger), (2) **13:45:28 UTC** — kubelet on `ip-10-0-26-109` finalising the pod cleanup. 61 s gap matches the chaos log's 65 s end-to-end recovery, providing AWS-side corroboration of the in-cluster timeline. |
| `ebs-{data,wal}-{...}-Volume*.json` | Per-volume EBS metrics (`VolumeWriteBytes` / `ReadBytes` / `WriteOps` / `ReadOps` / `QueueLength` / `IdleTime`) over the chaos window. 27 datapoints per metric × 6 metrics × 2 volumes — enough granularity to see the attach/detach trough around the pod kill. |
| `dynamodb-...-Consumed{Read,Write}CapacityUnits.json` | DynamoDB placement table activity. Capacity = 0 for the window — proves the table is provisioned but the chaos demo does not exercise the routing-path (ADR-03 placement-table lookup), as expected for a pod-level chaos test. |
| `eks-control-plane-list-AWS-EKS.json` | Names of all 30+ `AWS/EKS` metrics being emitted for the cluster — control-plane health, request counts, request error rate, etc. Captures the "shape" of what's available without bulk-pulling every metric. |
| `00-caller-identity.json` | The IAM principal that captured this evidence (SSO `AWSReservedSSO_PlatformAdmin` in account 251774439261), proving the capture was done with read-only access from a separate principal than the chaos-trigger — the standard separation of operator vs. evidence-collector. |

## Reproducing the chaos log

Prerequisite: cluster running, helm chart installed (per `docs/operations/runbooks/02-aws-bootstrap-and-chaos-demo.md`).

```bash
# Default targets the helm release in this repo
scripts/chaos/demo-stateful-pod-kill.sh

# Override the StatefulSet / pod under test
NAMESPACE=aegis-app \
STS_NAME=aegis-aegis-statefulset-primary \
POD_INDEX=0 \
scripts/chaos/demo-stateful-pod-kill.sh
```

Exit codes: `0` on PASS, non-zero with diagnostic output on FAIL.
Each run writes a fresh timestamped log to `/tmp/`; this file is the
copy from the run cited in `SUBMISSION.md`.

## Key metric from the chaos log

| Metric | Value | Why it matters |
|---|---|---|
| Pod-recreation time (delete → Ready) | **~65 s** (15:44:27 → 15:45:32 UTC+2 wallclock) | Within the AZ-failure RTO budget noted in ADR-04 (~25 min target with LevelDB warm-up; pod-level chaos is much faster because the volume re-attach skips the warm-up). |
| Data PV identity | `pvc-9eb95bc8-…` (preserved) | EBS volume re-attached, not re-provisioned — state intact at the CSI layer. |
| WAL PV identity | `pvc-d6639882-…` (preserved) | Same as above for the write-ahead-log volume. |
| Pod UID transition | `e1589dc3-…` → `c46af96f-…` | The pod object was genuinely destroyed and a fresh replica was created by the StatefulSet controller — not a container restart in place. |
| Node placement | `ip-10-0-26-109` → `ip-10-0-26-109` (same node) | Master-AZ scheduling preserved (the standby-AZ node groups stay at `desired=0` per ADR-01); the new pod landed where the existing PV is already attachable. |

## Note on Grafana "No data" framing

The three Grafana screenshots intentionally show "No data" panels.
This documents the deployed state honestly:

- `grafana_cloud_stack.main` provisions the stack.
- `grafana_dashboard.default[*]` pushes eight dashboards from
  `gitops/grafana/dashboards/`.
- The chart's `kube-prometheus-stack` helm release failed install
  during the staging deploy (LB Controller webhook race + Bitnami
  `kubectl` image-tag schema change in Velero's CRD upgrade hook).
- Without an in-cluster Prometheus, no `remote_write` flows into
  Grafana Cloud Mimir/Loki/Tempo — hence panels render with no data.

The dashboards-as-code pipeline is end-to-end verified; the missing
piece is the agent install on the cluster side, which is a documented
follow-up rather than an architectural gap.
