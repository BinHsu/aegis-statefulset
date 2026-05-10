# Capacity Expansion Runbook

Operator runbook for `scripts/capacity/expand-cell.sh` per ADR-01.

Capacity expansion is the response to **aggregate cluster pressure** —
the cluster as a whole is approaching its onboarding ceiling, even if
individual pods have headroom. It does NOT migrate existing tenants;
new tenants land on the newest cell, existing tenants stay where they
are.

If your problem is a single hot pod, you want **relocation**, not
expansion. See `tenant-relocation.md`.

---

## 1. When to expand

Expand when ANY of:

| Trigger | Source | Lead time |
|---|---|---|
| aggregate cluster used ≥ 70 % | placement service metric | open PR within 14 days |
| forecast: cluster will hit 80 % within 30 days | `predict_linear` 7d → 30d | open PR within 7 days |
| onboarding pipeline expects ≥ N new tenants this quarter | product / CS roadmap | size for end-of-quarter |
| at least two of {pod_75pct_alerts ≥ 50 % of pods} | placement service metric | expand and rebalance |

The 70 % aggregate trigger is intentionally lower than the 75 % per-pod
trigger — capacity expansion is a 1-2 hour operation with multi-week
billing impact, so we plan it ahead. Per-pod relocation is ~30 min and
cheap to trigger.

**Never expand reactively at 90 %+ aggregate.** That late, you're racing
ASG provisioning vs onboarding traffic, and a partial expansion can
land more pods than the existing routing layer is configured to handle.

---

## 2. Cost implication — coordinate with FinOps

Every cell expansion adds a fixed monthly cost **forever**:

- 3 new EC2 instances (one per AZ) at the stateful instance type
- 3 new EBS volumes at the StorageClass-defined size
- proportional NAT / inter-AZ traffic
- proportional backup S3 storage cost

For typical sizing, this is on the order of `3 × per-pod monthly
cost` — exact figures live in the FinOps dashboard
(`gitops/grafana/dashboards/finops-overview.json`). Capacity
reductions are operationally destructive (ADR-01 §5) so any
expansion is effectively permanent.

**Coordinate with FinOps per ADR-10 before expanding:**

- forecast onboarding rate to confirm new cell will be filled within
  N months (otherwise we're paying for empty pods)
- check if the existing cells are actually full or if hot-pod
  relocation would suffice (relocation is free; cells aren't)
- update the per-tenant cost allocation model to reflect the new
  cell — see `docs/finops/cost-allocation.md`

---

## 3. Two-step sequence — Terraform first, Helm second

The order is non-negotiable. Reversing it produces Pending pods
(no nodes to schedule onto) and visible service degradation.

```
+----------+      +------+
| Terraform | ---> | Helm |
+----------+      +------+
   nodes           pods
   first           second
```

The script enforces this. Do not run them out-of-band.

If Terraform fails (quota, IAM, EC2 capacity in AZ), STOP. Do not
proceed to Helm. Diagnose, retry Terraform, then resume.

---

## 4. Pre-flight checklist

1. **EC2 quota** — confirm the account has headroom for `3 × delta` new
   instances of the stateful instance type in the cluster's region.
   ```
   aws service-quotas get-service-quota --service-code ec2 \
     --quota-code L-1216C47A
   ```

2. **EBS quota** — same check for gp3 GiB and gp3 volume count.

3. **AZ capacity** — request ICE check via Trusted Advisor or just
   try the apply and watch for `InsufficientInstanceCapacity`. Rare
   in eu-central-1 for our instance class, but possible.

4. **IRSA / IAM** — terraform plan shouldn't introduce new IAM
   resources for an expansion (just scaling existing ASGs); if plan
   shows IAM changes, escalate before applying.

5. **Backup S3 bucket lifecycle** — a new cell adds 3 new pods, each
   with daily backups. Check that the lifecycle rule applies to the
   new pod prefix (it does by default — pattern is `pod=*`, but
   verify after first backup cycle).

6. **No active relocations** — running expansion mid-relocation makes
   debugging harder. Wait for in-flight relocations to enter
   `SOAK_PENDING_*` state before expanding.

---

## 5. Running the script

```
export NAMESPACE="aegis-app"
export HELM_RELEASE="aegis-statefulset"
export TF_DIR="infrastructure/terraform"

# Was 3 per AZ (9 pods total), going to 4 per AZ (12 pods total).
./scripts/capacity/expand-cell.sh 4
```

The script:

1. Runs `terraform apply` with `stateful_pool_per_az_size=<NEW_PER_AZ>`.
2. Waits for new nodes to become Ready (TODO operator-supplied poll).
3. Runs `helm upgrade` with `cells.per_az=<NEW_PER_AZ>` and `--wait`.
4. Verifies the expected pod count is present.

Expected runtime: 10-15 minutes for ASG provisioning + image pull +
StatefulSet rolling reconcile.

---

## 6. Verification

After the script returns 0:

1. **Pod count match** — `3 × cells.per_az` primary pods Running.
   ```
   kubectl get pods -n aegis-app -l aegis.io/role=primary --no-headers | wc -l
   ```

2. **Headless Service DNS resolves new pods**.
   ```
   kubectl exec -n aegis-app deploy/dns-debug -- \
     dig +short aegis-statefulset-primary-headless | sort
   ```
   Should return all `3 × cells.per_az` pod IPs.

3. **Backup CronJob auto-created for each new pod**.
   ```
   kubectl get cronjobs -n aegis-app -l aegis.io/component=backup
   ```
   Helm reconciles these via `templates/backup-cronjob.yaml`. First
   run lands on the next scheduled tick (usually within 24 h).

4. **Placement service sees the new pods**.
   ```
   curl -sf http://placement-service:8080/cells | jq '.cells | length'
   ```
   New tenants will route here on next onboarding.

5. **Grafana dashboard** `capacity-headroom` panel "Cell capacity"
   shows `cells.per_az_count = NEW_PER_AZ` and the new pods at
   ~0 % occupancy.

---

## 7. Tenant onboarding behavior post-expansion

The placement service routes **new** tenants to the cell with the
most headroom. After expansion, the new cell is the emptiest, so it
will absorb new tenants until it catches up to the average.

**Existing tenants are not migrated.** If you specifically want to
move a tenant onto a new cell — for example, to dedicate the new
cell to a large customer — run `per-tenant-relocate.sh` AFTER
expansion completes.

The two scripts are intentionally orthogonal:

- `expand-cell.sh` — adds capacity, no data motion.
- `per-tenant-relocate.sh` — moves data, no capacity change.

Composing them gives "expand and rebalance" without coupling the
implementation of either operation to the other.

---

## 8. Non-goals — what expansion does NOT do

- Does NOT redistribute existing tenants (use relocation).
- Does NOT change instance type / size of existing pods (use a
  separate node group migration).
- Does NOT shrink the cluster (capacity reduction is destructive
  and out-of-scope; see §9).
- Does NOT auto-scale based on per-pod metrics (cluster-level only;
  per-pod problems are handled by relocation triggers).

---

## 9. Rollback / capacity reduction

Capacity reduction is **not supported by this script** and is not
recommended in production. Reasons:

- Removing a node removes the pods on that node; their PVs are
  retained but require manual reattachment to a different node.
- Tenants currently routed to those pods will see read errors until
  the placement service updates and Envoy caches catch up.
- The headless Service DNS records change, which can trigger client
  reconnect storms.

If reduction is necessary (e.g., post-customer-offboarding cost
reclaim), the procedure is:

1. Drain tenants off the to-be-removed pods via `per-tenant-relocate.sh`.
2. Scale Helm replicas down (this stops the pods but keeps PVs).
3. Verify no PVCs are bound to the removed pod ordinals.
4. Run terraform with the lower per-AZ size.
5. Manually clean up orphaned EBS volumes.

This procedure is operator-supervised, multi-day, and not
automated. Document scope changes via ADR before attempting.

---

## 10. Failure modes & responses

| Failure | Likely cause | Response |
|---|---|---|
| terraform apply hangs | EC2 ICE in one AZ | wait 5 min, retry; if persistent, escalate to AWS support |
| nodes Ready but pods Pending | StorageClass / IRSA misconfig in new AZ | check pod events; verify IAM role for EBS CSI in new AZ |
| pod count mismatch at verification | Helm timed out before all pods rolled | re-run helm upgrade; do NOT re-run terraform |
| backup CronJobs not created | Helm chart template gap | check `templates/backup-cronjob.yaml` for hardcoded ordinals |
| placement service still showing old cell count | service caches cell list | restart placement service pods; check ConfigMap reload |
