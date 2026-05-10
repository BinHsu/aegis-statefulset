# DR During Relocation — Path D

What to do when an AZ failure or pod loss happens while one or more
tenants are in the relocation soak window. Specifically: the placement
table has entries in `SOAK_PENDING_*` state pointing at a now-failed
target.

This is **Path D** in the DR taxonomy (Path A = EBS survives + cluster
gone; Path B = pod-loss + replica-from-EBS; Path C = full region
failure + restore-from-cross-region; Path D = AZ failure during
relocation soak).

---

## 1. Symptom

One or more of:

- AZ-failure alert fires (e.g. `aws-az-eu-central-1a-down`).
- Pod readiness probes flip red on every pod scheduled in that AZ.
- Placement service `/cells` endpoint reports failed pods.
- Customer-visible 5xx spike correlated to tenants whose `primary_pod`
  lives in the affected AZ.

The pages that come with this scenario will look like a normal AZ
failure. The thing you notice second — and the thing this runbook is
about — is the placement table query.

---

## 2. Critical first action — query placement table

Run this BEFORE doing any other DR action:

```
aws dynamodb scan \
  --table-name aegis-statefulset-placement-prod \
  --filter-expression "begins_with(#s, :soak)" \
  --expression-attribute-names '{"#s":"state"}' \
  --expression-attribute-values '{":soak":{"S":"SOAK_PENDING"}}' \
  --output json | jq '.Items[] | {tenant_id, primary_pod, pending_source_pod, state, flip_at}'
```

For each result, check if `primary_pod` is in the failed AZ.

If yes → **this tenant's source data is intact** (key insight from
ADR-01: source pod is preserved through the entire soak). The
recovery is a routing reversion, not a data restore.

If no → standard DR Path A or Path B applies; this tenant's primary
is fine.

Make a list of `(tenant_id, pending_source_pod)` pairs. This is your
revert set.

---

## 3. Recovery procedure — bulk routing reversion

For each tenant in the revert set, write the placement entry back to
`pending_source_pod`:

```
for tenant_id in $(cat /tmp/revert-set.txt); do
  aws dynamodb update-item \
    --table-name aegis-statefulset-placement-prod \
    --key "{\"tenant_id\":{\"S\":\"${tenant_id}\"}}" \
    --update-expression "SET primary_pod = pending_source_pod, #s = :state REMOVE pending_source_pod, flip_at, cleanup_eligible_at" \
    --expression-attribute-names '{"#s":"state"}' \
    --expression-attribute-values '{":state":{"S":"NORMAL"}}'
done

./scripts/cache/flush-all.sh \
  --reason "dr-path-d-az-failure" \
  --no-confirm
```

What this does:

1. For each affected tenant, restore `primary_pod` to the still-alive
   source pod (in a different AZ from the failed one).
2. Reset state to `NORMAL` and remove relocation metadata.
3. Bulk flush Envoy caches so all replicas pick up the new routing
   on next request.

Why this is safe: source data was preserved through the soak window
on purpose, exactly for this scenario. Source pod has accepted writes
all along (no quiesce in Step 6); the only writes you lose are those
that hit the (now-dead) target during soak — typically a small
fraction since target was also active during soak.

---

## 4. Why Path D is faster than Path A / B / C

| Path | What's lost | Recovery action | RTO |
|---|---|---|---|
| A — EBS survives, cluster gone | nothing (volumes intact) | regenerate PV manifests, helm install | ~30 min |
| B — pod loss, EBS intact | nothing (data on EBS) | reschedule pod, wait for replica resync | ~10 min |
| C — full region failure | up to RPO window (cross-region) | restore from S3 cross-region replica | hours |
| **D — AZ fail during soak** | **writes that landed on dead target during soak** | **DynamoDB write + cache flush** | **< 5 min** |

Path D is nearly free because relocation **deliberately preserves
source data** (ADR-01 key invariant). The dead target is unfortunate
but not catastrophic — the source is still serving the tenant in a
different AZ.

This is the architectural payoff of "no source quiesce + cleanup gate
+ 24 h floor": the system has a working alternative copy of every
in-flight tenant's data for the entire soak window.

---

## 5. Verification

After running the reversion:

1. **Customer 5xx rate drops** — within 2-3 minutes (cache flush
   propagation + client retry).
2. **Affected tenants serving from source pods** — verify a few
   manually:
   ```
   aws dynamodb get-item --table-name aegis-statefulset-placement-prod \
     --key '{"tenant_id":{"S":"<sample-tenant>"}}'
   ```
   `primary_pod` should be the original source, `state` should be
   `NORMAL`.
3. **Source pods healthy** — they should not be in the failed AZ.
   ```
   kubectl get pod aegis-statefulset-primary-<source-ord> -n aegis-app \
     -o jsonpath='{.spec.nodeName}'
   ```
   Resolve nodeName → AZ via `kubectl get node <name> -o jsonpath='{.metadata.labels.topology\.kubernetes\.io/zone}'`.
4. **Envoy cache hit rate recovers** — Grafana
   `capacity-headroom` panel; expect a brief dip (full flush) then
   normal hit rate within 5 minutes.

---

## 6. Post-recovery — replan, then restart relocation

After the AZ comes back (or the failed pods are rescheduled to
healthy AZs), the previously-in-flight relocations need to be replanned:

1. **Don't auto-resume.** The targets that failed are likely now in a
   different state than when the relocation started; capacity, pod
   identity, and recent writes have all changed.
2. **Pick new targets.** Run pre-flight checks against current cluster
   state, possibly choosing different target ordinals than before.
3. **Restart from Step 4 (initial Restic backup).** Source data has
   diverged from the previous Restic snapshots by however many writes
   happened during the AZ outage.
4. **Skip emergency-tier escalation.** Pods that hit 90 % during the
   outage may auto-trigger automation; manually flag the affected
   pods to suppress automation until you've replanned.

For a postmortem, capture in the incident report:

- which AZ failed and for how long
- how many tenants were in soak at the time
- how long Path D recovery took (compare to Path A/B baseline)
- whether automation needed manual override

ADR-01 anticipates Path D as a first-class DR scenario; if recovery
took longer than 10 minutes, file an ADR amendment with the
specific bottleneck.
