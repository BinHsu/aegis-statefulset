# Architecture Decision Records — Index

Ten thematic ADRs covering every architectural decision in this repo.
Each one synthesises a coherent topic of the architecture into a single
narrative — written to function as both a senior's quick-skim memo (read
the headers) and a junior's deep-study textbook (read the reasoning).

## The ten ADRs

| # | Title | What you'll find |
|---|---|---|
| [ADR-01](ADR-01-architecture-and-topology.md) | Architecture & topology | Per-tenant pod identity; single master AZ + warm-standby; cells; 3-tier request flow; microservices over multi-container pods |
| [ADR-02](ADR-02-storage-and-pv-mapping.md) | Storage & PV mapping | EBS gp3 + LVM with online expansion; StatefulSet ordinal + Retain reclaim; 1:1 pod-to-node for stateful tier |
| [ADR-03](ADR-03-routing-and-ingress.md) | Routing & ingress | Placement table six-property contract (DynamoDB Global Tables as POC reference); Envoy Lua filter; ALB single-layer multi-AZ |
| [ADR-04](ADR-04-backup-dr-and-ha.md) | Backup, DR & HA | Cold DR via Velero + EBS Snapshot; 5-min cadence default; Three-Layer DR; manual operator-gated rotation; LDB layout capability matrix |
| [ADR-05](ADR-05-migration-strangler-fig.md) | Migration — Strangler Fig | Cell-by-cell cutover via placement-table flip; application untouched; same shape as legacy-to-K8s migrations |
| [ADR-06](ADR-06-observability.md) | Observability | OpenTelemetry first-day; Grafana Cloud default; tiered alerting hysteresis; 8 dashboards including Blackbox availability |
| [ADR-07](ADR-07-security-and-runtime.md) | Security & runtime | Defense-in-depth from edge to audit; default-deny NetworkPolicy; PSS restricted; per-tier KMS; eBPF runtime; tamper-protected audit |
| [ADR-08](ADR-08-cicd-and-gitops.md) | CI/CD & GitOps | GitHub Actions; 4-workflow split; ArgoCD with manual prod sync; Helm + kubeconform + tflint + tfsec |
| [ADR-09](ADR-09-supply-chain.md) | Supply chain — SHA pin / SLSA L3 / SBOM | Every external image as `repo@sha256:digest`; Cosign keyless OIDC; CycloneDX SBOM; Renovate auto-merge for patches |
| [ADR-10](ADR-10-finops.md) | FinOps as architecture discipline | Tagging + budgets + Cost Anomaly Detector + per-tenant CUR + Athena attribution; cost-as-architecture, not afterthought |

## Reading order by audience

### "I want the architecture in 10 minutes"

Read [`docs/architecture-overview.md`](../architecture-overview.md) first
(one page + diagram), then dive into whichever ADR your specific
question lands on.

### Senior platform reviewer

The order that builds the argument cleanly:

1. **ADR-01 Architecture & topology** — frames the constraints LevelDB physics impose on everything below
2. **ADR-04 Backup, DR & HA** — the most consequential consequence of those constraints (cold DR vs active-passive)
3. **ADR-03 Routing & ingress** — the contract that lets DR work the way it does
4. **ADR-02 Storage & PV mapping** — the substrate that makes the per-pod identity model concrete
5. **ADR-05 Migration** — the operational consequence that closes the design loop
6. Pick whichever of ADR-06/07/08/09/10 lands closest to the reviewer's specialism

### Engineering manager / cost-conscious reviewer

1. **ADR-10 FinOps** — the cost discipline that constrains every other decision
2. **ADR-04 Backup, DR & HA** — where cost is decided alongside availability
3. **ADR-01 Architecture & topology** — the topology shape that bounds the cost ceiling
4. **ADR-08 CI/CD & GitOps** — where cost is gated at PR-review time

### Security / compliance reviewer

1. **ADR-07 Security & runtime** — defense-in-depth narrative with ISO 27001 / CIS / MITRE / NIST mappings
2. **ADR-09 Supply chain** — chain of custody from source to running container
3. **ADR-08 CI/CD & GitOps** — where the security gates fire
4. **ADR-04 Backup, DR & HA** — KMS isolation + audit log durability under the worst case

### Platform engineer joining the team (textbook function)

Read top-to-bottom in numerical order. Each ADR builds on the previous
ones. Skip nothing; the cross-references between ADRs are the joins.

## Provenance

Each public ADR consolidates several private predecessor ADRs, kept in
`_context/adr/` as the source of truth and history record (50 files
covering granular per-decision reasoning). The mapping:

| Public ADR | Predecessor private ADRs |
|---|---|
| ADR-01 | ADR-001 / ADR-002 / ADR-003 / ADR-004 / ADR-005 / ADR-006 / ADR-045 / ADR-046 |
| ADR-02 | ADR-007 / ADR-008 / ADR-017 / ADR-018 |
| ADR-03 | ADR-009-routing-placement-table / ADR-009-consistent-hash-override-delta / ADR-010 |
| ADR-04 | ADR-011 / ADR-012 / ADR-013 / ADR-014 / ADR-015 / ADR-047 / ADR-048 / ADR-049 / ADR-050 |
| ADR-05 | ADR-016 |
| ADR-06 | ADR-019 / ADR-020 / ADR-021 / ADR-022 / ADR-023 / ADR-024 / ADR-025 |
| ADR-07 | ADR-026 / ADR-027 / ADR-028 / ADR-029 / ADR-030 / ADR-031 / ADR-032 / ADR-043 / ADR-044 |
| ADR-08 | ADR-033 / ADR-034 / ADR-035 / ADR-036 / ADR-037 / ADR-038 / ADR-041 |
| ADR-09 | ADR-039 / ADR-042 |
| ADR-10 | ADR-040 |

The private predecessors are not published. They contain the customer's
name and richer per-decision reasoning that doesn't help an external
reviewer. The public ten are anonymised, narratively unified, and
finalised at the current topology — paths that were considered and
retired earlier in the design (e.g. active-passive multi-region HA;
consistent-hash + override-delta routing) live in the private history
and are absent from the public documents.

## ADR shape

Each ADR follows the same nine-section template — clear headers for
senior skim, substantive content for junior study:

```
## Status                       — Accepted / Proposed
## Thesis or Decision           — what we landed on (3-7 numbered items)
## Context                      — the problem framing this topic addresses
## Why                          — the load-bearing reasoning per decision
## Trade-offs accepted          — the cost we are paying with eyes open
## Alternatives considered      — what else was on the table; why-not
## Out of POC scope             — what's deferred and the upgrade trigger
## Stage 3 questions            — open conversations with the customer
## Cross-references             — predecessor ADRs + related public ones
```

Length range: 100–400 lines. The narrowest topics (migration, supply
chain) are in the lower end; the broadest (security, CI/CD,
observability, FinOps) are in the upper end. Length is calibrated to
the topic's actual surface, not padded for symmetry.
