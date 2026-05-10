# ADR-06: Observability — vendor-neutral telemetry, tiered alerting, dashboards as a product

## Status
Proposed (POC submission scope; subject to confirmation in Stage 3 conversation).

## Thesis
Observability is a product the engineering team consumes, not a stack the platform team ships. The architectural commitments — OpenTelemetry as a vendor-neutral wire format, a hybrid managed backend with a clean fallback, asymmetric alerting that mirrors the platform's failover discipline, and a small number of opinionated dashboards driven by a 90-second debug workflow — exist to make a single property true: an engineer at 02:30 with a customer ticket can move from "tenant is unhappy" to "I see the bad span on this pod" without help from the original architect.

## Context (why these decisions belong together)
The challenge spec asks three things under "Monitoring & Observability": (a) outline and integrate monitoring and logging, (b) detect or be alerted to system failures, node issues, and backup errors, and (c) enable developers to diagnose application issues. Treating those as three independent decisions produces a stack that "covers all signals" but fails the developer-diagnosis test, because the signals don't link to each other and the dashboards weren't designed for the customer-ticket workflow.

The architectural shape this ADR argues for is therefore an integrated one. The backend choice (managed LGTM) only works if the wire format (OpenTelemetry) keeps it reversible. The wire format only delivers if the logs (ADR-022 schema) carry the same `tenant_id` and `trace_id` vocabulary the traces use. The traces only catch rare events if the sampling policy (tail sampling) prefers errors and slow requests over uniform random keep. The alerts only avoid fatigue if they tier by severity and use multi-vantage detection that mirrors the active-passive HA model in ADR-04. And the dashboards only get used if they're version-controlled, opinionated about hierarchy, and built around a stated incident-response path. The seven dashboards, the 90-second target, the IaC discipline, and the linkage between log line → trace span → metric panel are the thing the spec is actually asking for. The rest is plumbing.

A second axis runs through every decision: the customer is a Mittelstand-scale SaaS with a small SRE team. Self-hosted LGTM stacks are technically defensible and operationally expensive. Vendor APM agents are ergonomic and structurally locking. The shape we converge on — managed backend by default with an AWS-native fallback for data-residency demands, OTel as the universal instrumentation, IaC for everything Grafana — is calibrated to that team-size constraint and to the request flow this platform actually runs (ALB → API tier → Envoy router → StatefulSet, with Blackbox Exporter probing the external surface).

## Decisions

### 1. Backend — Grafana Cloud default, AMP+AMG fallback, OTel makes it reversible

The default is **Grafana Cloud** (LGTM-as-a-service, EU region) — Mimir for metrics, Loki for logs, Tempo for traces, Grafana for dashboards and alerting, all in one billing surface and one query interface. The fallback is **AMP (Amazon Managed Prometheus) + AMG (Amazon Managed Grafana) + CloudWatch Logs + AWS X-Ray** — chosen if the customer's compliance posture requires telemetry to stay inside the AWS trust boundary.

Both options are within the "managed, multi-signal, Grafana-rendered" envelope. Both keep ops burden low for a small SRE team. The choice between them is a Stage 3 conversation about data residency, not a technical re-architecture: the OpenTelemetry Collector's exporter config is a Terraform variable, and switching backends is a ~2-engineer-day migration of dashboard JSON and alert-rule expressions.

We rejected three obvious alternatives. **Pure CloudWatch native** is the lowest-friction AWS-only path, but its Logs Insights query language is weaker than LogQL and its Metrics service is expensive at the cardinality this platform produces (per-tenant, per-pod, per-AZ dimensions stack quickly). **Self-hosted LGTM inside the cluster** is the most flexible answer and the wrong one for a small team — monitoring-the-cluster-from-inside-the-cluster has a chicken-and-egg failure mode during incidents, and the ~10-15 engineer-hours per month of LGTM ops is unaffordable on the actual headcount. **Datadog or New Relic** are best-in-class and structurally locking, with a price tag (~$1500/month at this scale) that is an order of magnitude over the managed-OSS path for marginal gain.

### 2. Instrumentation — OpenTelemetry Operator, auto-instrumentation, central Collector

The application emits **OTLP** via the OpenTelemetry SDK; auto-instrumentation is injected by the **OTel Operator** so existing application code doesn't need to import OTel libraries on day one. Manual spans wrap the operations that auto-instrumentation can't see — LevelDB read/write (custom DB client), tenant routing decisions, backup pipeline stages, failover steps. A central **OTel Collector Deployment** (2 replicas, HPA) receives OTLP, batches, applies the `k8sattributes` and resource-detection processors, runs tail-sampling policies, scrubs PII via `attributes/redact`, and exports to whichever backend ADR-06 §1 picked. **W3C `traceparent` / `tracestate`** propagates end-to-end: ALB target group → API tier → Envoy router → StatefulSet pod → LevelDB query span. Every layer participates.

The Collector's pipeline shape is intentionally boring:

```
Application pods (per-tenant + stateless tier)
  └─ OTel auto-instrumentation (injected by OTel Operator)
        ├─ HTTP/gRPC client + server spans
        ├─ DB client spans (LevelDB wrapper instrumented manually)
        ├─ Runtime metrics (Node.js / Python / Go / JVM as applicable)
        └─ Application logs (auto-correlated with trace_id)

  ↓ OTLP/gRPC

OTel Collector (Deployment, 2 replicas, HPA)
  ├─ Receivers:    OTLP, Prometheus scrape (K8s system metrics),
  │                Filelog (kubelet logs), Blackbox Exporter scrape
  ├─ Processors:   batch, memory_limiter, k8sattributes,
  │                resource detection, attributes/redact (PII),
  │                tail_sampling (ADR-06 §4)
  └─ Exporters:    Grafana Cloud OTLP / AMP remote-write /
                   Loki / Tempo / X-Ray
                   (chosen exporters depend on §1 backend choice;
                    switching = exporter config change)
```

The argument for this shape over alternatives is the reversibility argument from §1, restated. A vendor-specific agent (X-Ray SDK, Datadog APM) would lock the application to one backend and undercut the whole "switchable" promise. DIY instrumentation (Prometheus client + structured logs + custom trace headers) re-implements ~70% of OTel poorly. Per-pod sidecar collectors multiply memory overhead at the 18+ pod count this platform runs (primary + standby per cell). A central Collector with OTel auto-instrumentation is the cheapest path to coverage that keeps the backend reversible.

The Collector also centralises the operational concerns that would otherwise sprawl across every service: auth tokens, retry / buffer policies, sampling logic, attribute scrubbing all live in the Collector config, not in 9+ application pods. Single place to add a PII filter, single place to rotate credentials, single place to tune cardinality drops when a high-cardinality attribute (HTTP path with `tenant_id` in the URL, for example) breaks the metrics budget.

The honest cost: the Collector becomes a critical-path component for telemetry. If it's down, telemetry is dropped. We mitigate with two replicas, the `memory_limiter` processor, and a retry queue — worst case is a 5-minute telemetry gap with no application impact. Auto-instrumentation also has gaps (LevelDB is not in the upstream catalogue; WebSocket message-level tracing requires manual spans), and initial cardinality is hard to predict — addressed by the Collector's redact processor and per-attribute drop rules.

### 3. Logging — structured JSON, mandatory tenant scope, hashed session, trace correlation

Every log record is **JSON-structured** with a fixed schema:

```json
{
  "timestamp":  "2026-05-08T14:32:15.123Z",
  "level":      "INFO|WARN|ERROR|FATAL",
  "message":    "human-readable summary",
  "tenant_id":  "tnt_abc123",
  "pod_name":   "app-stateful-az1-3",
  "trace_id":   "0af7651916cd43dd8448eb211c80319c",
  "span_id":    "b7ad6b7169203331",
  "session_id": "sha256:abc...",
  "request_id": "req_xyz789",
  "service":    "stateful-api|backup|migration|control-plane",
  "version":    "git_sha_or_tag",
  ...event_specific_fields
}
```

The mandatory fields are `timestamp` (ISO 8601 UTC, ms precision), `level`, `message`, `tenant_id` (mandatory on every request-bound log line; `null` only for cluster-level logs from CronJobs and controllers), `pod_name`, `trace_id` (auto-injected by OTel for correlation), `span_id`, `session_id` (always SHA-256 hashed at the boundary — never raw; correlation across log lines is the point, recoverability is not), `request_id`, `service`, and `version`. Event-specific fields layer on top. **No PII in logs** — no email, no plaintext customer name, no payload bodies, no JWTs, no API keys — enforced by an application-side lint rule, the Collector's `attributes/redact` processor, and log-store-side regex masking. Defence in depth: a bug in one layer doesn't leak data.

The pipeline is K8s-idiomatic: application writes JSON to stdout, kubelet routes to `/var/log/pods`, **Promtail DaemonSet** (Grafana Cloud path) or **Fluent Bit DaemonSet** (AMP+AMG path) parses JSON, attaches K8s metadata, and ships to Loki or CloudWatch Logs. Retention is 30 days hot in the queryable store, 90 days cold in S3. Compliance retention beyond 90 days is a Stage 3 question — different jurisdictions force different answers.

The reason for this shape is operational. "Show me all ERROR-level logs for `tenant_id=tnt_abc123` in the last six hours" is the customer-support workflow; it must be a single LogQL or CloudWatch Insights query, not `grep | awk` against an unstructured stream. The 90-second debug workflow in §6 starts with a `tenant_id` filter — a logging schema that doesn't make this trivial fails the "diagnose application issues" requirement. `trace_id` correlation closes the loop with §4's tracing: engineers pivot from a log line to the full distributed trace in one click. Without that, traces and logs are two parallel universes.

The trade-off we accept is the discipline cost. Every `log.info(...)` call must produce JSON, not free-form strings. We mitigate by wrapping the logging library in a thin adapter that enforces the schema and by CI lint that flags unstructured logging. Schema evolution is genuinely painful — adding a mandatory field requires coordinated rollout across services — and we manage it by versioning the schema (`schema_version: "v1"`) and supporting multiple versions in queries.

### 4. Tracing — auto-instrumentation plus tail sampling

Traces use OTel auto-instrumentation for HTTP / gRPC / DB clients (free), with **manual spans** wrapping LevelDB operations, tenant routing decisions, backup pipeline stages, and failover steps. Sampling is **hybrid**: a 10% probabilistic baseline for common-case traffic, plus tail-sampling policies that keep 100% of any trace where (a) any span errored, (b) the full trace exceeded 1 second, (c) the entry span carried `tenant_tier=enterprise`, or (d) the service was `failover`, `backup`, or `migration`. The tail-sampling decision happens in the Collector after a 30-second buffer. Tempo (Grafana Cloud path) or X-Ray (AMP+AMG path) is the storage backend; trace retention is 7 days hot — most debug windows are under 72 hours, and older forensics fall back to the 90-day log archive.

The sampling policy lives in the Collector's `tail_sampling` processor:

```yaml
tail_sampling:
  decision_wait: 30s              # buffer traces this long before deciding
  num_traces:    50000             # in-memory trace cap
  policies:
    - name: errors                 # any span errored → keep 100%
      type: status_code
      status_code: { status_codes: [ERROR] }
    - name: slow_requests          # full trace > 1s → keep 100%
      type: latency
      latency: { threshold_ms: 1000 }
    - name: high_priority_tenants  # enterprise tier → keep 100%
      type: string_attribute
      string_attribute:
        key:    tenant_tier
        values: ["enterprise"]
    - name: failover_pipeline      # any HA / backup / migration span → 100%
      type: string_attribute
      string_attribute:
        key:    service
        values: ["failover", "backup", "migration"]
    - name: probabilistic_baseline # everything else → 10%
      type: probabilistic
      probabilistic: { sampling_percentage: 10 }
```

Every span carries the same vocabulary as the log records in §3: `tenant_id`, `pod_name`, `service`, `version`, plus span-type-specific attributes. Engineers don't context-switch between "log fields" and "trace attributes" — they're the same set, queried with the same filters, in the same dashboards.

Tail sampling is the senior answer over pure 10% head sampling because errors and slow requests get the same sampling rate as successes under uniform head sampling — exactly the traces engineers need are dropped 9 out of 10 times. Adaptive sampling (X-Ray-style dynamic rate) is opaque: engineers can't tell why a particular trace was dropped, and the policy is a black box. Tail sampling is reasoned about, explicit, and configurable per service.

The cost is real. The 30-second decision buffer means ~50K active traces in memory per Collector replica, ~500MB-1GB of RAM. We size for it with `memory_limiter` + 2-replica HA. Manual span wrapping is ~6-10 critical operations of code change (~2 engineer-days for the initial set, ongoing as new operations are added). Sampling decisions are not reversible — a trace dropped at the Collector cannot be retrieved — and we mitigate by keeping the policies conservative (any error / slow / priority tenant = keep) and by relying on logs as the forensic fallback where traces were dropped.

### 5. Alerting — three tiers, multi-vantage detection, asymmetric hysteresis

Alerts are **tiered**:

| Tier | Examples | Routing | Response time |
|---|---|---|---|
| **Critical** | AZ failure (50% / 2-min quorum), backup pipeline 2 consecutive failures, cross-region replication lag > 12h, EBS volume > 95%, PV-detach failure during failover, cluster-autoscaler unable to scale, Velero schedule missed > 3 cycles (15 min), Blackbox Exporter probe failing from all geographies | PagerDuty → on-call phone | Acknowledge ≤ 15 min, mitigate ≤ 60 min |
| **Warning** | EBS > 80%, backup duration > 2× rolling median, standby refresh lag > 1h, pod restart-loop (> 3 in 15min), Karpenter provisioning errors, DLQ depth > 0, Velero schedule lag (1 cycle missed) | Slack `#ops-warnings` | Triage in business hours |
| **Info** | Routine successes, scheduled rotations, normal scale events, expected drift in Mode 1 | Loki only (30d retention) | No human required |

**Multi-vantage detection** is structural anti-flap: Prometheus runs as 3 replicas, one per AZ, scraping a shared target list. Critical alerts on AZ health require **quorum** — at least 2 of 3 replicas firing the same alert in the same window. Single-observer signals are network partitions between observer and target, not real failures. Implemented via Alertmanager `inhibit_rules` so a single replica's alert never pages.

**Asymmetric hysteresis** mirrors the failover discipline in ADR-04. The failover trigger is aggressive: `unhealthy_targets / total_targets >= 0.5` for `2m` sustained, AZ-scoped, with multi-vantage quorum. Recovery detection is conservative: `healthy_targets / total_targets >= 0.95` for `60m` sustained, and the recovery alert is **notify-only** — there is no auto-failback. A 24-hour cooldown blocks any second failover trigger after the first; symptom alerts (latency, error rate) still fire normally inside the cooldown.

The backup-error coverage is non-trivial because backups can fail in three different ways. **Velero schedule** runs every 5 minutes; the alert rules cover (a) Velero job exit-code non-zero, (b) backup snapshot age exceeding 2× cadence (a backup got skipped), and (c) the weekly restore canary failing — a job that picks a tenant, restores their backup to a sandbox pod, runs a checksum, and reports green / red. Three different failure modes, three rules. The 5-minute Velero cadence drives the alert threshold: missed > 3 cycles (15 minutes elapsed without a successful backup) is Critical.

The spec category coverage maps cleanly:

- **System failures.** Error-rate / latency / saturation alerts at the application and ALB layers; per-tenant outlier detection on tail latency; Blackbox Exporter probe failures from external vantage.
- **Node issues.** `kube_node_status_condition{condition="Ready",status!="true"}`, node-pressure conditions, ASG launch failures, kubelet not heartbeating, Karpenter provisioning errors.
- **Backup errors.** Velero schedule exit code, snapshot age vs cadence (2×), DLM cross-region copy lag, weekly restore-canary status, S3 PutObject errors at the backup endpoint.

Single-tier paging on every threshold breach is the textbook alert-fatigue trap. Single-Prometheus deployment is cheaper and a false-positive on the failover trigger is catastrophic. Symmetric thresholds at oscillating-input boundaries are the canonical recipe for flap. We rejected each in turn — the tiered, multi-vantage, asymmetric design is the standard senior shape, and the rule expressions enforce the asymmetry rather than relying on operator memory.

### 6. Dashboards — seven opinionated views, version-controlled, with a 90-second target

The dashboard library is **seven Grafana dashboards**, version-controlled in the repo, deployed via the Terraform Grafana provider (§7), and built around a stated incident-response workflow:

| # | Dashboard | Audience | Entry signal |
|---|---|---|---|
| 1 | **Service Health Overview** | Anyone (default landing) | Aggregate request rate / error rate / latency P50/P95/P99 across services and AZs. Includes Blackbox Exporter probe panels for the external ALB endpoint (chaos-demo evidence). |
| 2 | **Customer Drill-Down** | Engineer responding to a customer ticket | Filter by `tenant_id`. Per-tenant rate, errors, latency, recent log lines, recent error traces. The first stop after a ticket. |
| 3 | **Pod-Level Detail** | Engineer triaging a single failing pod | Filter by `pod_name`. CPU / memory / disk IO / LevelDB metrics / EBS metrics / restart history. Drill-down from #2. |
| 4 | **Cell Capacity Forecast** | Capacity planning, on-call sweep | Per-cell utilisation, 7-day trend, projected exhaustion date. |
| 5 | **Backup Pipeline Health** | On-call + backup owner | Last successful Velero schedule per tenant, EBS Snapshot age, DLM cross-region copy status to Glacier IR, backup-restore weekly canary. Directly addresses the spec's "backup errors" requirement. |
| 6 | **HA Status & Failover History** | On-call + architecture owner | Per-cell primary state, last failover event timeline, recovery detection status (notify-only). Directly addresses "system failures" and "node issues." |
| 7 | **Migration Progress** *(active during migration phase only)* | Migration captain | Per-tenant migration status, Strangler Fig stage, dual-write divergence, rollback readiness. |

The **90-second debug workflow** is the design forcing function. A ticket arrives at T+0 with `tenant_id=tnt_abc123 reports timeouts since 14:20 UTC`. By T+30 the engineer has Dashboard #2 open, filtered to that tenant, time range last 30 minutes; the request-rate spike, error count, P95 anomaly, and recent error log lines are visible side by side. By T+60 they've clicked the data point at 14:18, jumped to the Tempo / X-Ray panel via the embedded `trace_id`, and seen that LevelDB read on `app-stateful-az1-3` took 8.3 seconds (normal: 80ms). By T+90 they've opened Dashboard #3 filtered to that pod, seen EBS IOPS saturated since 14:15 and disk at 91%, and hypothesised storage pressure → IOPS throttle → tenant query stalls. The action is to scale EBS (online expand) or move the tenant to a freer cell.

If the workflow takes 5 minutes, the dashboard design is wrong — the filter is hard to apply, the log panel is missing, the trace link doesn't resolve. Stating the target makes the design gap visible. We accept that the 90-second target is aspirational for novel root causes; it's the **common-case** target, not the universal one.

The discipline that holds the library together is panel hierarchy (every dashboard has a Logs panel scoped to its filter variables; every dashboard has a Recent Errors trace panel; every aggregation has a tenant breakdown available as a panel variable, not a separate dashboard) and a DORA / SPACE proxy: Dashboard #1 carries a 7-day MTTR widget, manually annotated for now and auto-derived from PagerDuty resolution times in Phase 2.

### 7. Grafana state as code — Terraform Grafana Provider

Everything Grafana — dashboards, folders, data sources, alert rules, contact points, notification policies, SLOs — is managed by the **Terraform Grafana Provider** (`grafana/grafana`). Dashboards live as JSON files in `infrastructure/terraform/grafana/dashboards/` and are referenced by Terraform via `file()`. A single `terraform apply` deploys both AWS infrastructure and Grafana state. A nightly `terraform plan` surfaces UI-edit drift as an alert — the only mechanism that prevents the dashboard library from rotting back into ad-hoc artifacts within six weeks.

The directory layout makes the state surface visible:

```
infrastructure/terraform/
├── aws/                          (existing — VPC, EKS, EBS, IAM, ALB)
└── grafana/
    ├── stack.tf                  Grafana Cloud Stack resource (the tenant)
    ├── datasources.tf            Mimir / Loki / Tempo data sources
    ├── folders.tf                Folder structure (Service / Customer / ...)
    ├── permissions.tf            Team / role / folder permissions
    ├── dashboards.tf             7 dashboards loaded via file(...)
    ├── dashboards/
    │   ├── 01-service-health-overview.json
    │   ├── 02-customer-drill-down.json
    │   ├── 03-pod-level-detail.json
    │   ├── 04-cell-capacity-forecast.json
    │   ├── 05-backup-pipeline-health.json
    │   ├── 06-ha-status-failover-history.json
    │   └── 07-migration-progress.json
    ├── alert_rules.tf            §5 alert rules (Critical / Warning / Info)
    ├── contact_points.tf         PagerDuty integration, Slack webhook
    ├── notification_policies.tf  Tier-to-channel routing tree
    └── slos.tf                   SLO definitions (availability, backup freshness)
```

The dashboard authoring workflow is also cattle-friendly: an engineer edits the dashboard in the Grafana UI for free-form exploration, copies the JSON model from Settings → JSON Model, pastes into the corresponding `.json` file, runs `terraform plan` for the diff, and merges via PR. Subsequent UI edits without a commit are detected by the next nightly plan as drift — explicit signal to either commit the change or revert. Promotion gates are `terraform validate` on every PR, `terraform plan` posting the diff to the PR for human review, and `terraform apply` only from main with required reviewer approval.

The argument over alternatives is a tool-count argument. The team already runs Terraform for AWS (VPC, EKS, EBS, IAM, ALB). Adding the Grafana provider extends an existing skill, not a new one. Grafana Operator with K8s CRDs is strongest against self-hosted Grafana inside the cluster — exactly the path §1 rejected. Grafonnet (Jsonnet) is the right choice at 30+ dashboards with shared mixins; at 7 dashboards, the Jsonnet learning curve is net negative. Grizzly CLI is a separate workflow from Terraform, and engineers context-switch between `terraform apply` and `grr apply`. JSON dashboards are also the lingua franca — Grafana Cloud, AMG, self-hosted Grafana, and Grafonnet all emit and consume the same JSON model, so the format itself is portable. Switching backends per §1's reversibility promise doesn't break the dashboard library.

The trade-offs are honest. Dashboard JSON is verbose and noisy in diffs (1000+ lines for a complex panel), so PR review requires familiarity with the JSON model, mitigated by enforcing structure conventions. The provider lags 1-3 months behind Grafana API for newest features, mitigated by reading the CHANGELOG before adopting bleeding-edge panel types. The Grafana Cloud API key is sensitive and stored in AWS Secrets Manager; rotation is on a schedule (Phase 2 automates it via Lambda).

## Trade-offs accepted (cross-cutting)

- **Telemetry crosses a sub-processor boundary on the default path.** Grafana Cloud is in-EU but is still external to the AWS account. PII-in-logs is forbidden by §3's schema; Stage 3 confirms whether the residual exposure is acceptable.
- **Free-tier cost is bounded but not zero-risk.** Grafana Cloud free tier (10K active series, 50GB logs, 50GB traces) likely covers POC scale. Cardinality budgets in §3 and a monthly cost-alarm bound the surprise.
- **Backend switch is reversible but not free.** Dashboard JSON is mostly portable; alert rules need re-expressed in the target system's syntax (~2 engineer-days either direction).
- **Three Prometheus replicas mean 3× scrape load on targets.** Mitigated by tuning scrape intervals and by deduplicating on read at the unified backend (Mimir / AMP).
- **Quorum logic adds Alertmanager rule complexity.** Real implementation is ~12 critical rules with multi-vantage matching; needs a dedicated rule-test suite (`amtool` / `promtool test rules`).
- **Manual annotation of the MTTR widget is brittle.** Engineers must remember to annotate; PagerDuty-to-Grafana annotation webhook is the Phase 2 automation.

## Alternatives considered (consolidated)

- **Pure CloudWatch native** — rejected on cardinality cost, weaker query language, and no unified dashboard.
- **Self-hosted LGTM stack inside the cluster** — rejected on ops burden for a small SRE team and the chicken-and-egg incident-response failure mode. Documented as upgrade trigger if SRE headcount grows past 3.
- **Datadog / New Relic** — rejected on cost (~$1500/month) and lock-in.
- **Elastic / OpenSearch** — rejected on Elasticsearch ops complexity; the all-in-one promise undercut by reality.
- **Vendor-specific APM agents (X-Ray SDK direct, Datadog APM agent)** — rejected as locking and undercutting backend reversibility. X-Ray as a destination for OTel-emitted traces remains an option; X-Ray as the SDK does not.
- **DIY instrumentation (Prometheus clients + manual trace headers)** — rejected as re-implementation of OTel.
- **Per-pod sidecar Collectors** — rejected on memory overhead at scale; centralised Collector + DaemonSet for node-local concerns is cheaper.
- **Single-tier paging on every threshold breach** — rejected as alert-fatigue trap.
- **Single-Prometheus deployment** — rejected because false-positive on the failover trigger is catastrophic.
- **Symmetric trigger / recovery thresholds** — rejected as flap recipe.
- **Auto-failback when recovery detected** — rejected explicitly; recovery is human-in-the-loop forever.
- **One mega-dashboard** — rejected; hierarchy beats density.
- **Per-service dashboards** — rejected as primary; the natural axis for the stateful tier is tenant, not service.
- **Click-ops Grafana (no IaC)** — rejected; drift, untracked changes, dev/staging/prod cannot be replicated identically.
- **Grafana Operator CRDs** — rejected; strongest fit is self-hosted Grafana, which §1 rejected.
- **Grafonnet / Jsonnet** — rejected at current dashboard count; documented as upgrade trigger past ~30 dashboards.

## Out of POC scope (upgrade triggers)

- **Self-hosted LGTM stack.** Trigger: SRE team grows past 3 engineers AND data residency prohibits any SaaS option.
- **eBPF-based instrumentation (Pixie, Beyla, Cilium Tetragon).** Trigger: language coverage gap or manual span-stitching cost exceeds threshold.
- **Continuous profiling (Pyroscope OTel bridge, Parca).** Trigger: latency hot-spots that traces alone cannot explain.
- **Span-to-metric pipelines (`spanmetrics` processor).** Trigger: metric definitions sprawl past ~50 named series.
- **SLO-driven alerting (burn-rate alerts, error budgets).** Trigger: customer-facing SLAs formalised; team adopts SRE practice formally.
- **ML-based anomaly detection (Grafana Adaptive Metrics, AWS Lookout).** Trigger: cardinality / metric volume grows beyond static-rule maintainability.
- **Per-tenant SLO dashboards.** Trigger: enterprise contracts with formal SLAs.
- **Browser-side tracing (RUM via OTel-Browser SDK).** Trigger: customer-perceived latency complaints that backend traces alone cannot explain.
- **Synthetic monitoring beyond Blackbox Exporter** (Grafana Synthetic Monitoring, k6 Cloud). Trigger: external-perspective availability requirement formalised.
- **Audit-log separation to a write-once store.** Trigger: ISO 27001 / SOC-2 audit prep.
- **Grafonnet migration.** Trigger: dashboard count > 30 OR shared-panel reuse becomes painful in raw JSON.
- **Backstage / portal integration.** Trigger: developer adoption plateaus and "where is the dashboard" friction surfaces.

## Stage 3 questions

1. Data residency policy for telemetry: is Grafana Cloud (EU) acceptable, or must metrics / logs / traces stay inside the AWS trust boundary? Drives the §1 default-vs-fallback choice.
2. Existing instrumentation posture: is the application stack already wired to Prometheus client / X-Ray / Datadog? OTel can co-exist via the Collector's multiple receivers, or can replace; the migration path differs.
3. Existing logging shape: are application logs already structured, or does adoption require a coordinated migration? Drives §3's rollout sequencing.
4. Existing on-call rotation and team calibration on alert volume: PagerDuty / Grafana OnCall / incident.io / homegrown? Currently noisy or quiet? Drives §5's alert routing destinations and tier thresholds.
5. Sampling calibration: what's the request volume and latency profile to size the tail-sampling buffer and trace storage cost against?
6. Developer-experience baseline: is there an existing dashboard library, and are engineers comfortable with PromQL / LogQL or do they need a more click-driven UI? Drives §6's query complexity calibration.
7. Terraform mono-repo: do we add a `grafana/` subdirectory or stand up a separate observability repo? Drives §7's directory layout and CI/CD integration.

## Cross-references

- ADR-01 — architecture & topology; the 3-tier flow (ALB → API → Envoy → StatefulSet) is what the Blackbox Exporter probes from outside and what the W3C `traceparent` propagation traces from edge to LevelDB.
- ADR-02 — storage; per-pod EBS volumes are what the Pod-Level Detail dashboard exposes IOPS / capacity panels for.
- ADR-03 — routing; the Envoy router and the consistent-hash override delta surface as the `tenant_routing.lookup` manual span in §4 and as the override-delta panel in Dashboard #2.
- ADR-04 — backup, DR & HA; Velero's 5-minute schedule, EBS Snapshot, and DLM cross-region copy to Glacier IR drive the alert thresholds in §5 and Dashboard #5's panels. Asymmetric failover hysteresis in this ADR mirrors the recovery discipline in ADR-04.
- ADR-05 — migration; Dashboard #7 and the `service=migration` tail-sampling priority in §4 anchor the Strangler Fig phase.
- ADR-07 — security; PII redaction in §3 layers on top of the same `attributes/redact` discipline used for security-sensitive fields, and audit-log separation is listed as the upgrade trigger.
- ADR-08 — CI/CD & GitOps; the Terraform Grafana provider state in §7 is applied through the same pipeline as the AWS infrastructure, and dashboard PRs run through the same `terraform plan` review gate.
- ADR-10 — FinOps; cardinality budgets, retention tiering, and free-tier ceilings in this ADR are the cost-architecture surface for observability.
- Originally split across private ADR-019..ADR-025; consolidated 2026-05-09.
