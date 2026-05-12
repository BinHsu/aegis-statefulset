# Architecture assumptions

> Explicit list of assumptions the submission makes about the customer
> environment and application. Each assumption is paired with the Stage 3
> question that would either confirm or reshape it.

The point is not to pretend the POC has answers. The point is to be
honest about which decisions were forced by the spec, which were
defaulted by the platform, and which are the operator's call.

**Status legend:**
- 🔒 **Locked** — forced by spec or platform physics; not Stage-3 negotiable
- 🛠 **POC default** — defaulted by platform; Stage-3 confirmable
- 📋 **Open question** — explicit Stage-3 question with assigned number

---

## A1 – A10 — at-a-glance

| # | Assumption | Status — POC value | Why it matters | Stage 3 question |
|---|---|---|---|---|
| **A1** | LDB layout — Pattern 1 (shared per pod) vs Pattern 2 (one per tenant) | 🛠 Pattern 2; mock app at `app/main.go` writes file-per-key under `/data` | Pattern 1 per-tenant relocation needs ~1 month of app-side extraction code; Pattern 2 is filesystem-grained, zero app changes | 📋 **#11** Which layout does the production app actually use? Pattern 1 → Tier A/B/C of the relocation matrix; Pattern 2 → Tier D unlocks cleanest relocation. (See [`per-tenant-relocation.md`](operations/per-tenant-relocation.md)) |
| **A2** | Application code changeability | 🛠 Black box; zero source changes; Strangler-Fig at infra layer per ADR-05 | A small per-tenant counter would unlock hot-tenant detection cleanly; without it, fallback to sidecar `du` per dir or coarser pod-level signal | 📋 **#13** Is a tiny telemetry metric (one counter, no new endpoint) acceptable, or is the container immutable? |
| **A3** | Migration window availability | 🛠 Scheduled window exists; per-shard cutover includes brief read-only window | Live no-window migration is possible (route-mirror + cut at quiesce) but shifts complexity into routing tier; not in POC scope | 📋 **#14** Are operational windows available, or must migration be fully invisible to customers? |
| **A4** | Tenant→cluster routing storage backend | 🛠 Postgres / Aurora-backed assumed; falls back to ConfigMap override layered on hash (ADR-03) | 6-property routing contract (atomic CAS / strong reads / multi-AZ durable / low read latency / CDC capability / audit log) gates backend choice — Aurora ✓ Redis ✗ | 📋 **#12** What's the existing tenant→cluster mapping backend? Does it satisfy the 6-property contract? |
| **A5** | Existing GitOps tooling | 🛠 ArgoCD for Layer-1 app namespaces (aegis-app, api-tier, envoy); Terraform `helm_release` for Layer-2 controllers (kube-system, monitoring, kyverno, ESO) per ADR-08 | Flux instead of ArgoCD is a port, not a rewrite; the load-bearing split is "Terraform owns controllers, GitOps owns apps" — tool-agnostic | 📋 **#15** ArgoCD or Flux? Greenfield, or pre-existing control plane to integrate with? |
| **A6** | Existing DR tooling | 🛠 Velero + EBS Snapshot copy (~$100/mo additional baseline) | Bespoke `kubectl get all -A \| git push` plus EBS snapshot scripts works but has CRD-fidelity + dependency-ordering pitfalls; Velero solves both | 📋 Velero already in flight, or DR backed by some other K8s-aware product (Kasten K10, Portworx)? |
| **A7** | Single master AZ at any moment | 🔒 **LOCKED** — all workloads in single master AZ; standby AZs exist with node groups at `desiredSize=0` until rotation (ADR-01) | LDB is single-writer; multi-AZ active-active for stateful tier is wasted latency + double cost without native replication. Honest design picks one AZ at a time | 🔒 Not Stage-3 negotiable — Layer-1 platform decision forced by application physics |
| **A8** | RPO upper bound | 🔒 **6 h from spec** (upper bound locked); default cadence 5 min → typical RPO ~30 sec | Unlocks cold DR (ADR-04) without LDB replication — LDB has zero native sync APIs. Spec gives us a budget; we spend it carefully via 5-min EBS Snapshot cadence | 🔒 Upper bound is contract. *Typical* RPO target (30 min / 5 min / 6 h) is a knob — operator chooses cost / RPO point |
| **A9** | Backup integrity verification | 🛠 Velero tracks completion status; periodic restore-and-mount verification deferred (see SUBMISSION § 9 item #8) | Untested backups are not backups. POC has the machinery (Velero schedule, cross-region copy to Glacier IR) but no verification schedule yet | 📋 (Implicit) What is the customer's backup-verification cadence today, if any? |
| **A10** | Cost ceiling ~$2,700/month | 🛠 POC default at `cells.count=1`; scales linearly with cell count for production (SUBMISSION § 7) | FAANG-shaped architecture at FAANG cost is wrong for Mittelstand; every knob in `values.yaml` exposes a cost trade-off (ADR-10 FinOps as Architecture Discipline) | 📋 (Implicit) Is the budget wider, narrower, or shaped differently (e.g. per-tenant cost ceiling)? |

---

## Status breakdown

| Status | Count | A-refs | What it means |
|---|---|---|---|
| 🔒 Locked | 2 | A7, A8 (upper bound only) | Forced by spec or platform physics; not negotiable |
| 🛠 POC default | 8 | A1, A2, A3, A4, A5, A6, A9, A10 | Defaulted by platform; Stage-3 conversation can reshape |
| 📋 With assigned Stage-3 # | 5 | A1 (#11), A2 (#13), A3 (#14), A4 (#12), A5 (#15) | Numbered in the Stage-3 question pile (SUBMISSION § 8) |
| 📋 Implicit Stage-3 | 3 | A6, A9, A10 | Real questions to ask but not numbered; convert to numbered if customer raises |

---

## How to use this document

| When | Action |
|---|---|
| Before Stage-3 discussion | Read end-to-end; flag any row where the POC default doesn't match what you know about the customer |
| During Stage-3 | Treat each row as a question waiting to be asked; if customer confirms an assumption, mark it `L2 → L1` (demoted from operator-decision to platform-locked) in meeting notes |
| After Stage-3 | Mark each row's resolution in the tracking system; the architecture variant for each resolved question lives in the corresponding ADR |

The submission earns its bones by being **explicit about what it does
and does not know** — not by claiming completeness.
