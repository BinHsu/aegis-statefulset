# Disaster Recovery Report

> **Template usage:** this file is the source of `DR_report.pdf`. Run
> `scripts/dr-report/generate-dr-report.sh` after the chaos demo finishes
> — it substitutes the `{{PLACEHOLDER}}` values from the `chaos-evidence/`
> directory (where automatable) and renders to PDF via Chrome headless.
> Hand-edit the remaining `[fill in]` markers before generating the PDF.
> See [`docs/operations/runbooks/02-aws-bootstrap-and-chaos-demo.md`](runbooks/02-aws-bootstrap-and-chaos-demo.md) § 4–6 for the chaos demo flow.

---

## 0. Identity

| Field | Value |
|---|---|
| Architecture | aegis-statefulset (reference architecture for LevelDB-backed stateful K8s workloads) |
| Submission scope | Take-home POC — single-master-AZ topology, cold DR via Velero, dual-cadence backup |
| Execution date | {{EXECUTION_DATE}} |
| Cluster | {{CLUSTER_NAME}} (region {{AWS_REGION}}) |
| DR region | {{DR_REGION}} |
| Architecture git SHA | {{GIT_SHA}} |
| Operator | {{OPERATOR}} |

---

## 1. Executive summary

| Dimension | Target | Observed | Verdict |
|---|---|---|---|
| Phase 1 AZ-failure RTO | ~25 min | {{P1_RTO_OBSERVED}} | [fill in: PASS / OVER / UNDER] |
| Phase 2 region-failure RTO | ~50 min | {{P2_RTO_OBSERVED}} | [fill in] |
| RPO observed (both phases) | ~30 sec at 5-min cadence | {{RPO_OBSERVED}} | [fill in] |
| Data integrity (sample verification) | 100% match | {{DATA_INTEGRITY_PCT}} | [fill in] |
| Total cost | $50–100 expected | $`{{TOTAL_COST_USD}}` | [fill in] |
| Production readiness | — | — | [fill in: READY / READY-WITH-NOTES / NEEDS-WORK] |

**One-paragraph verdict** *(operator-written, ~80 words)*:

[Fill in: did the architecture deliver on its RTO/RPO/cost promise? Any surprises? What would change before production?]

---

## 2. Architecture under test

<img src="diagrams/d1-high-level.svg" alt="High-level architecture" width="100%" />

The architecture under test is the Wave 4 topology:

- **Single master AZ** ({{MASTER_AZ}}) for all stateful workloads
- **Warm-standby AZs** ({{STANDBY_AZS}}) with node groups at `desired=0`
- **Cold DR via Velero + EBS Snapshot** — no active-passive replication
- **Dual-cadence backup** — 5-min operational (source region only) + 4-h DR (cross-region)
- **Three-Layer DR** — Terraform infra / Helm via terraform `helm_release` for cluster controllers / Velero for application + data

Full architectural reasoning: [`docs/adr/ADR-04-backup-dr-and-ha.md`](adr/ADR-04-backup-dr-and-ha.md) and [`docs/operations/why-cold-dr.md`](operations/why-cold-dr.md).

---

## 3. Phase 1 — AZ failure simulation

### 3.1. Pre-flight baseline (T+0)

| Check | Expected | Observed |
|---|---|---|
| Probe success (Blackbox external) | 1.0 | {{P1_BASELINE_PROBE}} |
| Pods Running in {{MASTER_AZ}} | {{EXPECTED_POD_COUNT}} | {{P1_BASELINE_PODS}} |
| Last successful operational snapshot | within 5 min | {{P1_LAST_BACKUP_AGE}} |
| Velero operational schedule healthy | yes | {{P1_VELERO_HEALTHY}} |

Evidence: `chaos-evidence/{{BASELINE_DIR}}/`

### 3.2. Failure injection

- **Action:** `aws ec2 delete-subnet --subnet-id {{MASTER_SUBNET_ID}}` (after draining the stateful node group to `desired=0` per the helper script `scripts/chaos/run-phase-1-az-failure.sh`)
- **Timestamp (UTC):** {{P1_INJECTION_TIME}}
- **Why subnet delete:** hard, atomic blast — different from "drain nodes" or "shut down instances"; subnet deletion forces ENIs to detach and prevents new pods from scheduling, mirroring the network-partition component of a real AZ outage

### 3.3. Detection (T+~30s to T+2min)

| Detector | Expected fire time | Observed fire time | Source |
|---|---|---|---|
| ALB target unhealthy | within 30 s | {{P1_ALB_DETECT}} | ALB target group state in `aws-eks-*` evidence |
| Blackbox external probe | within 30 s | {{P1_BLACKBOX_DETECT}} | Prometheus rule output |
| Prometheus 50%/2min alert | within 2 min | {{P1_PROMETHEUS_ALERT}} | `alerts-firing.json` |

Evidence: `chaos-evidence/{{P1_INJECTED_DIR}}/`

### 3.4. Recovery

| Step | Expected | Observed |
|---|---|---|
| Operator decision (T+5–10 min window) | manual rotation call | {{P1_DECISION_TIME}} |
| `./scripts/dr/az-rotation.sh` initiated | — | {{P1_ROTATION_START}} |
| Standby AZ node group scaled to `desired=1` | within 2 min of start | {{P1_NODE_SCALE}} |
| Velero restore initiated | within 5 min of start | {{P1_RESTORE_START}} |
| Velero restore complete (`Phase: Completed`) | ~15 min after start | {{P1_RESTORE_END}} |
| First pod `Ready` in new master AZ | ~20 min after start | {{P1_POD_READY}} |
| First successful curl against new master AZ | ~25 min after start | {{P1_FIRST_200_OK}} |

**Observed RTO (T+0 injection → first 200 OK):** **{{P1_RTO_OBSERVED}}**

Evidence: `chaos-evidence/{{P1_RECOVERY_DIR}}/`

### 3.5. Data integrity verification (Phase 1)

- **Pre-failure:** wrote {{P1_TEST_KEYS}} test keys with known values via `scripts/chaos/seed-test-data.sh ${N}` (manifest at `chaos-evidence/<timestamp>-seed-pre-phase-1/manifest.json`)
- **Post-recovery:** ran `scripts/chaos/verify-test-data.sh phase-1-recovery` — reads each key back via the app's HTTP GET and compares to manifest
- **Match rate:** {{P1_DATA_MATCH_PCT}} ({{P1_DATA_MATCH_N}} of {{P1_TEST_KEYS}}; raw report at `chaos-evidence/<timestamp>-phase-1-recovery-verify/verify-report.json`)
- **Data lost during {{RPO_OBSERVED}}-second window before snapshot:** {{P1_DATA_LOST}}

### 3.6. Grafana screenshots — Phase 1

Capture from the `service-availability` dashboard at three checkpoints:

| Checkpoint | Filename | What to verify |
|---|---|---|
| T+0 baseline | `chaos-evidence/{{BASELINE_DIR}}/screenshot-service-availability.png` | probe_success = 1.0, all pods Running |
| T+2 min (subnet deleted) | `chaos-evidence/{{P1_INJECTED_DIR}}/screenshot-service-availability.png` | probe_success = 0, alerts firing |
| T+~25 min (recovery complete) | `chaos-evidence/{{P1_RECOVERY_DIR}}/screenshot-service-availability.png` | probe_success = 1.0 in {{STANDBY_AZ}} |

---

## 4. Phase 2 — Region failure simulation

### 4.1. Pre-flight (post Phase 1)

The cluster is now serving from {{STANDBY_AZ}} (the new master AZ after Phase 1 rotation). Phase 2 simulates losing the entire source region.

| Check | Expected | Observed |
|---|---|---|
| Probe success | 1.0 | {{P2_BASELINE_PROBE}} |
| Last successful DR-tier snapshot in DR region | within 4 h | {{P2_LAST_DR_BACKUP_AGE}} |
| Route 53 weighted record (primary/DR) | 100/0 | {{P2_R53_BEFORE}} |

Evidence: `chaos-evidence/{{P2_BASELINE_DIR}}/`

### 4.2. Failure injection

- **Action:** `./scripts/chaos/run-phase-2-region-drill.sh` — shifts Route 53 weighted record primary→DR (100/0 → 0/100) and triggers Velero restore in DR region from latest cross-region snapshot
- **Timestamp (UTC):** {{P2_INJECTION_TIME}}

### 4.3. Recovery

| Step | Expected | Observed |
|---|---|---|
| Route 53 weighted-record flipped | within 1 min | {{P2_R53_FLIP}} |
| DNS propagation (Route 53 60s TTL) | within 1 min | {{P2_DNS_PROP}} |
| Velero restore in DR region initiated | within 5 min | {{P2_DR_RESTORE_START}} |
| Velero restore complete | ~30 min | {{P2_DR_RESTORE_END}} |
| First pod Ready in DR region | ~40 min | {{P2_DR_POD_READY}} |
| First successful curl against DR ALB | ~50 min | {{P2_FIRST_200_OK}} |

**Observed RTO (Route 53 flip → first 200 OK in DR region):** **{{P2_RTO_OBSERVED}}**

Evidence: `chaos-evidence/{{P2_RECOVERY_DIR}}/`

### 4.4. Data integrity verification (Phase 2)

- **Pre-failure:** {{P2_TEST_KEYS}} test keys verified at end of Phase 1
- **Post-recovery in DR region:** ran `scripts/chaos/verify-test-data.sh phase-2-recovery` against the same manifest (DR-region app served via Route 53 cutover)
- **Match rate:** {{P2_DATA_MATCH_PCT}} (raw report at `chaos-evidence/<timestamp>-phase-2-recovery-verify/verify-report.json`)
- **Data lost during DR-tier cadence window ({{DR_CADENCE_HOURS}}h cadence):** {{P2_DATA_LOST}}

---

## 5. Post-demo verification

### 5.1. Velero restore log review

The restored cluster's Velero server logs the restore choreography end-to-end. Key lines to confirm:

```
{{VELERO_RESTORE_LOG_HIGHLIGHTS}}
```

Full log: `chaos-evidence/{{P1_RECOVERY_DIR}}/velero-server.log`

### 5.2. EBS-tag-driven DR rebuild (Path A) — secondary verification

Even after Velero restore, the EBS-tag-based DR rebuild (per ADR-04) should be able to reconstruct PV manifests independently from the EBS volume tags alone. This is the third-layer DR safety net.

- Ran `./scripts/dr/rebuild-from-ebs-tags.sh` against the restored cluster: {{EBS_TAG_REBUILD_RESULT}}

### 5.3. Routing override delta after recovery

- Override entries needed (per ADR-03): {{OVERRIDE_COUNT}}
- Percentage of tenants matching consistent hash directly (no override): {{HASH_MATCH_PCT}}%
- Verifies the ~95% claim in ADR-03 § Override delta

---

## 6. Cost analysis (actual spend)

Raw data: `chaos-evidence/cost-summary.json` (AWS Cost Explorer)
Source script: `scripts/finops/capture-demo-cost.sh`
Window: {{COST_WINDOW_START}} → {{COST_WINDOW_END}} (UTC; end exclusive)

{{COST_LINE_BY_LINE_TABLE}}

### Observed vs target

| | Observed | Target (SUBMISSION § 7) | Notes |
|---|---|---|---|
| Total chaos-demo cost | $`{{TOTAL_COST_USD}}` | $50–100 | 3-hour run including chaos phases + teardown |
| Largest line | {{LARGEST_LINE_ITEM}}: $`{{LARGEST_LINE_COST}}` | EKS control plane usually dominates per-hour | |
| EBS Snapshot cost | $`{{EBS_SNAPSHOT_COST}}` | small at POC (`cells.count=1`) | scales linearly with `cells.count`; see future/README.md § 3 |

### Caveats

- **Cost Explorer 24h lag:** if the demo ran today, totals above are
  partial. Re-run `capture-demo-cost.sh` tomorrow with the same
  `START_DATE`/`END_DATE` for the final number.
- **Tag activation requirement:** `Project=aegis-statefulset` must have
  been activated as a cost allocation tag at least 24 h before the
  demo for Cost Explorer to honour the filter; resources tagged
  before activation are not retroactively attributed.
- **KMS keys carry into the 7-day deletion window** at ~$1/key/month;
  this is post-teardown cost, not chaos-demo cost.

---

## 7. Lessons learned

*(Operator-written after the demo. Highlight any surprises — anything that took longer than expected, any tooling friction, any architectural detail that wasn't obvious until live operation.)*

- [Fill in: surprises]
- [Fill in: tooling friction]
- [Fill in: architectural insights from running it live]

---

## 8. Production readiness verdict

The architecture is [READY / READY-WITH-NOTES / NEEDS-WORK] for production deployment at Mittelstand-scale B2B SaaS, conditional on:

- [ ] RTO target validated against actual customer operational tolerance (Stage 3 conversation)
- [ ] EBS Fast Snapshot Restore (FSR) enabled for production (per ADR-04 trade-off)
- [ ] Snapshot quota increase requested for production `cells.count > 12` (per ADR-04 caveat)
- [ ] Backup-verification automation enabled (currently "out of POC" per ADR-04)
- [ ] Production tagging policy enforced via `terraform-aws-defaultTags` *before* enabling Cost Explorer attribution

**Notes from chaos demo execution:** [fill in: anything specific that emerged from the run]

---

## 9. Appendix — full evidence index

```
chaos-evidence/
├── {{BASELINE_DIR}}/                 # T+0 baseline before Phase 1
├── {{P1_INJECTED_DIR}}/              # T+2 min subnet deleted
├── {{P1_RECOVERY_DIR}}/              # T+25 min recovery complete in {{STANDBY_AZ}}
├── {{P2_BASELINE_DIR}}/              # Post-Phase 1, before Phase 2
├── {{P2_RECOVERY_DIR}}/              # T+50 min recovery in DR region
├── cost-summary.json                  # AWS Cost Explorer raw response
└── cost-summary.md                    # Rendered cost table (also in § 6 above)
```

Each subdirectory has its own `README.md` summarising what was captured at that checkpoint — see `scripts/chaos/capture-evidence.sh` for the canonical layout.

---

## 10. Cross-references

- [`docs/SUBMISSION.md`](SUBMISSION.md) — submission cover + § 0 grounding + § 6 DR three paths + § 7 cost
- [`docs/adr/ADR-04-backup-dr-and-ha.md`](adr/ADR-04-backup-dr-and-ha.md) — architectural decisions tested in this demo
- [`docs/operations/why-cold-dr.md`](operations/why-cold-dr.md) — full reasoning for the cold-DR posture
- [`docs/operations/region-failure-recovery.md`](operations/region-failure-recovery.md) — operator runbook for the region cutover path
- [`docs/future/README.md`](future/README.md) — what happens to this architecture across T+1y / T+3y / T+5y / T+10y horizons

---

*Generated from `docs/operations/dr-report-template.md` by `scripts/dr-report/generate-dr-report.sh` on {{GENERATION_TIMESTAMP}}.*
