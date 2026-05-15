# Runbook 04 — Grafana Cloud setup

**Goal:** Sign up Grafana Cloud free tier, mint an API token, store in
AWS Secrets Manager, and let `infrastructure/terraform/grafana-cloud.tf`
provision the stack + datasources + 8 dashboards.

**Time:** ~30 min  
**Cost:** $0 (free tier — 10K series, 14-day retention, sufficient for
POC demo)  
**Trust boundary:** Bin holds the email + the API token; Claude does not.

---

## 0. Prerequisites

```bash
aws sts get-caller-identity       # for Secrets Manager write
terraform --version               # ≥ 1.6
```

Working email address. The free tier sign-up takes < 5 min.

---

## 1. Sign up Grafana Cloud free tier

1. Go to https://grafana.com/auth/sign-up/create-user
2. Sign up with email
3. Choose **Free** plan when prompted
4. Stack name: pick something like `aegis-poc` (becomes
   `aegis-poc.grafana.net`)
5. Region: pick **EU** (Frankfurt) to match the AWS workload region

After sign-up you land in the stack. Note the URL:

```
https://aegis-poc.grafana.net   # your stack URL
```

---

## 2. Create the API token

In the Grafana Cloud Portal (https://grafana.com → Account → Security):

1. **Access Policies** → **Create access policy**
2. Name: `terraform-aegis-poc`
3. Realms: scope to your stack only
4. Scopes (minimum required by the terraform provider):
   - `stacks:read`
   - `stacks:write`
   - `metrics:write`
   - `logs:write`
   - `traces:write`
5. Save → **Add token** → name `terraform-token` → copy the value

It looks like `glc_eyJv...` (long base64). **Copy once — Grafana Cloud
will not show it again.**

---

## 3. Store the token in AWS Secrets Manager

```bash
aws secretsmanager create-secret \
  --name aegis/grafana-cloud/api-token \
  --description "Grafana Cloud API token for terraform provider" \
  --secret-string "glc_eyJv..." \
  --region eu-central-1

# Verify
aws secretsmanager get-secret-value \
  --secret-id aegis/grafana-cloud/api-token \
  --region eu-central-1 \
  --query SecretString --output text | head -c 10
# expect: "glc_eyJv" (first 10 chars)
```

The terraform `grafana-cloud.tf` file (already in the repo) reads
this secret via `data.aws_secretsmanager_secret_version`, so once the
secret is in place, terraform will pick it up.

---

## 4. Capture the stack endpoints into terraform.tfvars

Grafana Cloud assigns three datasource endpoints per stack. Find them
in the stack UI under **Connections** → **Data sources**:

| Datasource | URL pattern | Used by |
|---|---|---|
| Mimir (Prometheus-compatible) | `https://prometheus-prod-XX-prod-eu-XXX.grafana.net/api/prom` | metrics scrape forwarder |
| Loki | `https://logs-prod-eu-XXX.grafana.net` | structured log shipping |
| Tempo | `https://tempo-eu-XXX.grafana.net` | trace ingestion |

Edit `infrastructure/terraform/terraform.tfvars`:

```hcl
grafana_cloud_stack_slug = "aegis-poc"
grafana_cloud_org_slug   = "<your-org-slug>"
# the three endpoint URLs are auto-resolved by data sources, so you
# don't need to copy them in unless your stack region differs from
# defaults
```

The token itself comes from Secrets Manager (Step 3) — do NOT put the
token in `tfvars`.

---

## 5. Apply the Grafana Cloud terraform module

If you've already done Runbook 02 Stage A, the Grafana stack is created
during Stage E. Otherwise apply standalone:

```bash
cd infrastructure/terraform
terraform apply \
  -target=data.aws_secretsmanager_secret.grafana_cloud_token \
  -target=data.aws_secretsmanager_secret_version.grafana_cloud_token \
  -target=provider.grafana \
  -target=grafana_cloud_stack.main \
  -target=grafana_data_source.prometheus \
  -target=grafana_data_source.loki \
  -target=grafana_data_source.tempo \
  -target=grafana_dashboard.service_availability \
  -target=grafana_dashboard.statefulset_health \
  -target=grafana_dashboard.backup_pipeline \
  -target=grafana_dashboard.dr_drill \
  -target=grafana_dashboard.network_policy \
  -target=grafana_dashboard.finops_overview \
  -target=grafana_dashboard.cost_per_tenant \
  -target=grafana_dashboard.alert_history
# expect: ~3 min
```

**Verify:** open `https://aegis-poc.grafana.net/dashboards`. Should see
8 dashboards. Click `service-availability` — the panels will show "no
data" until Runbook 02 deploys the workload, but the dashboard
structure (5 panels including probe_success timeline + chaos event
annotations) is in place.

---

## 6. Wire the cluster to send telemetry

Once the EKS cluster is up (Runbook 02 Stage C), three send-paths
populate the dashboards:

| Signal | Sender | Destination | Wired in |
|---|---|---|---|
| Metrics | in-cluster Prometheus `remoteWrite` | Grafana Cloud Mimir | `cluster-controllers.tf` (`kube_prometheus_stack`) |
| Logs    | Grafana Alloy `loki.source.kubernetes` | Grafana Cloud Loki | `grafana-alloy.tf` + `alloy-config.river.tpl` |
| Traces  | Grafana Alloy `otelcol.exporter.otlphttp` | Grafana Cloud Tempo | `grafana-alloy.tf` + `alloy-config.river.tpl` |

App pods point their OpenTelemetry SDK at the in-cluster Alloy service
(`http://alloy.monitoring.svc.cluster.local:4318`); Alloy in turn pushes
upstream using basic-auth credentials sourced from the
`alloy-grafana-cloud-token` K8s Secret.

Confirm the Alloy ConfigMap rendered with the expected endpoints:

```bash
kubectl get configmap -n monitoring alloy -o yaml \
  | grep -E 'endpoint|url' | head -20
# expect URLs ending in:
#   tempo-prod-XX-prod-eu-XXX.grafana.net/otlp   (traces export)
#   logs-prod-eu-XXX.grafana.net/loki/api/v1/push (logs push)
```

Confirm Alloy + Prometheus are running:

```bash
kubectl get pods -n monitoring
# expect:
#   alloy-0                                       1/1 Running
#   prometheus-kube-prometheus-stack-0           2/2 Running
#   kube-prometheus-stack-*                       Running
```

Trigger a request through the system and check Grafana for arrival
of all three signals:

```bash
curl -X POST "http://${ALB_HOST}/data" -H 'Content-Type: application/json' \
  -d '{"key":"smoke-test","value":"hello"}'
# wait ~30s for scrape/push intervals

# In Grafana: Explore → Mimir → query
#   rate(aegis_data_ops_total[1m])
# expect: a non-zero value

# Explore → Loki → query
#   {namespace="aegis-stateful"} |= "data"
# expect: at least one log line; trace_id field present per ADR-06 § 3

# Explore → Tempo → search
#   service.name="aegis-stateful-mock"
# expect: traces with two-level shape http.server (root) → fileops.write (child)
```

If you see "no data" after 5 min in any single pane:

| Symptom | Likely cause | Fix |
|---|---|---|
| Mimir empty, Loki+Tempo OK | Prometheus `remoteWrite` not configured | check `kube_prometheus_stack` helm release; `kubectl logs -n monitoring prometheus-* -c prometheus \| grep -i remote` |
| Loki empty | Alloy can't reach Loki ingest endpoint | `kubectl logs -n monitoring alloy-0 \| grep -i loki` — token scope must include `logs:write` |
| Tempo empty, Loki OK | App's `OTEL_EXPORTER_OTLP_ENDPOINT` env unreachable | `kubectl exec <pod> -- env \| grep OTEL` + `kubectl get svc -n monitoring alloy` |
| All three empty | Most likely cause: token scope missing | re-mint at Step 2 with metrics:write + logs:write + traces:write |

---

## 7. (Optional) Import a screenshot trigger for chaos demo

Grafana service-availability dashboard has chaos event annotations
configured. To make screenshots align cleanly with chaos events, run:

```bash
GRAFANA_TOKEN=$(aws secretsmanager get-secret-value \
  --secret-id aegis/grafana-cloud/api-token \
  --query SecretString --output text)
GRAFANA_URL=https://aegis-poc.grafana.net

# Add a manual annotation when starting Phase 1 chaos
curl -X POST "$GRAFANA_URL/api/annotations" \
  -H "Authorization: Bearer $GRAFANA_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "text": "Phase 1: master AZ failure",
    "tags": ["chaos", "phase-1"],
    "time": '"$(date +%s%3N)"'
  }'
```

Run the same with `Phase 1: rotation start` and `Phase 1: recovery`.
Screenshots taken from the dashboard will show the annotation lines —
one of the strongest pieces of demo evidence.

---

## 8. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `Failed to authenticate with Grafana Cloud API` | Wrong token / scope missing | Re-mint at Step 2; ensure `metrics:write`, `logs:write`, `traces:write` |
| Stack URL returns 404 | Stack name typo in tfvars | `terraform refresh`; verify `grafana_cloud_stack_slug` matches portal |
| `no data` in Mimir after 5 min | OTel Collector can't reach Grafana endpoint | Check egress NetworkPolicy in `monitoring` namespace; confirm ADR-07 allowlists outbound to `*.grafana.net` |
| Dashboards exist but show "Datasource not found" | Datasource UID mismatch | Re-apply with `terraform apply -replace=grafana_dashboard.service_availability` |
| Free tier quota exceeded mid-demo | High cardinality | Per-tenant labels are the usual culprit; reduce `tenant` label cardinality during demo (1–3 tenants is enough) |

---

## 9. Tie-back to architecture

- ADR-06 observability backend choice: `grafana_cloud` is the default
- ADR-06 OpenTelemetry instrumentation: vendor-neutral; backend is reversible
- ADR-06 alerting tiered hysteresis: alert rules render to Grafana Cloud
- ADR-06 developer self-service dashboards: 8 dashboards
- ADR-06 Grafana IaC via terraform provider: this runbook is the bootstrap

---

## 10. Done criteria

- [ ] Grafana Cloud stack `aegis-poc.grafana.net` reachable
- [ ] API token in Secrets Manager `aegis/grafana-cloud/api-token`
- [ ] `terraform apply` for `grafana_cloud_stack.main` succeeded
- [ ] 8 dashboards visible in the Grafana UI
- [ ] OTel Collector pods can reach Grafana endpoints (egress NetworkPolicy correct)
- [ ] First scrape arrives in Mimir within 5 min of cluster up
