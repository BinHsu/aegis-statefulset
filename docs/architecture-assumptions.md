# Architecture assumptions

> Explicit list of assumptions the submission makes about the customer
> environment and application. Each assumption is paired with the Stage 3
> question that would either confirm or reshape it.

The point is not to pretend the POC has answers. The point is to be honest
about which decisions were forced by the spec, which were defaulted by the
platform, and which are the operator's call.

---

## A1. LDB layout — Pattern 1 vs Pattern 2

**Assumption (POC default):** Pattern 2 — one LevelDB per tenant. The mock
application in `app/main.go` writes one file per key under `/data`, which is
the trivial-Pattern-2 shape.

**Why it matters:** Per-tenant relocation under Pattern 1 (one shared DB)
requires extraction code in the application — a roughly one-month effort
to add tenant-aware iterator + dump/load primitives. Under Pattern 2 the
relocation is filesystem-grained and requires no app changes. (See
`docs/operations/per-tenant-relocation.md` and ADR-04.)

**Stage 3 question (#11):** Which layout does the production application
actually use? Pattern 1 places us at Tier A/B/C of the relocation matrix;
Pattern 2 places us at Tier D-by-default and unlocks the cleanest
relocation story.

---

## A2. Application code changeability

**Assumption (POC default):** The application container is a black box. We
add no source-level changes; everything happens at the infrastructure
layer (Strangler Fig at the infra layer per ADR-05).

**Why it matters:** A small added emit — say, "rows or files written per
tenant per minute" — would dramatically simplify hot-tenant detection
(input to ADR-01 relocation triggers). Without it we fall back to a
sidecar with `du` per tenant directory, or to a coarser pod-level signal.

**Stage 3 question (#13):** Is a tiny telemetry metric (one counter, no
new endpoint) acceptable, or is the container immutable for the migration?

---

## A3. Migration window availability

**Assumption (POC default):** A scheduled migration window exists for the
Strangler-Fig per-shard cutover. No live, no-window migration was
designed in.

**Why it matters:** The `scripts/migration/per-shard-cutover.sh` flow
includes brief read-only windows per shard. Live no-window migration is
possible (route-mirror + cut at quiesce point) but is not in the POC
scope; it would shift complexity into the routing tier.

**Stage 3 question (#14):** Are operational windows available, or must the
migration be fully invisible to customers?

---

## A4. Customer's existing tenant→cluster routing storage

**Assumption (POC default):** The customer either has a Postgres-backed
or Aurora-backed mapping store today, or none at all (in which case we
introduce a ConfigMap-based override delta layered on a hash function;
ADR-03).

**Why it matters:** The 6-property routing contract (CAS / strongly
consistent reads / multi-AZ durable / low read latency / CDC capability /
audit log) constrains what backends qualify. Aurora qualifies. Redis
alone does not. An internal service might or might not — depends on its
own substrate.

**Stage 3 question (#12):** What's the existing tenant→cluster mapping
backend? Does it satisfy the 6-property contract?

---

## A5. Customer's existing GitOps tooling

**Assumption (POC default):** ArgoCD is the deployment vehicle for
Layer-1 application namespaces (aegis-app, api-tier, envoy). For
Layer-2 controllers (kube-system, monitoring, kyverno, ESO), we use
Terraform `helm_release`. (Two layers, two tools — see
`docs/operations/scope-boundaries.md` and ADR-08.)

**Why it matters:** If the customer already uses Flux, the application
of ADR-08 + ADR-08 is a port, not a rewrite. The split between
"Terraform manages controllers, GitOps manages apps" is the load-bearing
piece, and is GitOps-tool-agnostic.

**Stage 3 question (#15):** ArgoCD or Flux? Pre-existing control plane
or greenfield?

---

## A6. Customer's existing DR tooling

**Assumption (POC default):** Velero + EBS snapshot copy is the DR
substrate. The customer either has Velero already, or accepts the
~$100/month additional baseline cost.

**Why it matters:** Velero is the canonical K8s-native cold-DR tool. The
alternative — bespoke `kubectl get all -A -o yaml | git push` plus EBS
snapshot scripts — is achievable but has the well-known incomplete-
manifest pitfalls (CRD fidelity, dependency ordering). Velero buys us
those edge cases for free.

**Stage 3 question:** Velero already in flight? Or DR backed by some
other K8s-aware backup product (Kasten K10, Portworx, etc.)?

---

## A7. Single master AZ at any moment

**Assumption (LOCKED, not Stage-3 negotiable):** All workloads run in a
single master AZ at any moment. Standby AZs exist (with `desiredSize=0`
node groups) but do not serve traffic until rotation. (ADR-01 modified.)

**Why it matters:** LevelDB is single-writer. Multi-AZ active-active for
the stateful tier is wasted latency and double-cost; multi-AZ for the
stateless tier without the corresponding stateful tier is half a story.
The honest design picks one AZ at a time.

**Not a Stage 3 question** — this is a Layer 1 (platform-owns) decision
forced by application physics.

---

## A8. RPO upper bound is 6 hours

**Assumption (from spec):** RPO must not exceed 6 hours. The default
cadence is 5 minutes (typical RPO ~30 sec), well below the budget.
Sub-30-sec RPO (WAL shipping) is out of POC scope.

**Why it matters:** This is what unlocks the cold DR design (ADR-04)
without LevelDB replication — LevelDB has zero native sync APIs, so
hot replication is structurally impossible. The spec gives us a budget;
we spend it carefully via 5-min EBS Snapshot cadence.

**Not a Stage 3 question on the upper bound** — it is the contract. But
the *typical* RPO target (30 min vs 5 min vs 6 h) is a knob.

---

## A9. Backup integrity is verified by restore, not by checksum alone

**Assumption (POC default):** Velero + EBS Snapshot tracks completion
status; periodic restore-and-mount verification is left as future work
(see SUBMISSION.md § 9 item #8).

**Why it matters:** Untested backups are not backups. The POC has the
machinery (Velero schedule, DLM cross-region copy to Glacier IR) but
does not yet have the verification schedule. Operationally, the customer
should expect to add this.

**Stage 3 question (implicit):** What is the customer's backup-verification
cadence today, if any?

---

## A10. Cost target ~$2,700/month is correct for Mittelstand POC scale

**Assumption (POC default):** The cost ceiling is ~$2.7K/month for the
default configuration (cold DR, 5-min cadence, `cells.count=1`). Scales
linearly with cell count for production scale. Full breakdown in
SUBMISSION.md § 7.

**Why it matters:** Architecture is FAANG-shaped at FAANG cost is wrong
for Mittelstand. Each knob in `values.yaml` exposes a cost trade-off
(see ADR-10 — FinOps as Architecture Discipline).

**Stage 3 question (implicit):** Is the budget wider, narrower, or
shaped differently (e.g., per-tenant cost ceiling)?

---

## How to use this document

1. Before submission discussion, read this file end-to-end.
2. During Stage 3, treat each assumption as a question waiting to be
   asked. If the team confirms an assumption, mark it in the meeting
   notes as "L2 → L1" (demoted from operator-decision to platform-locked).
3. After Stage 3, update `_context/STATE.md` § 7 with the resolved set;
   the architecture variant for each open question is in the
   corresponding ADR.

The submission earns its bones by being explicit about what it does and
does not know — not by claiming completeness.
