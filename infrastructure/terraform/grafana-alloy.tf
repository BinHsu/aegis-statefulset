# grafana-alloy.tf
#
# Grafana Alloy — single in-cluster agent for L (logs) + T (traces) per
# ADR-06. Receives OTLP from the application, tails pod logs via the K8s
# API, and forwards both to Grafana Cloud.
#
# Why Alloy (over standalone OTel Collector + promtail):
#   - One helm release, one auth path, one config surface.
#   - Vendor-recommended end-state — Grafana Cloud's 2025 quickstart and
#     the on-boarding wizard both default to Alloy.
#   - River config (alloy-config.river.tpl) is the same shape as the
#     OTel Collector pipelines language; if we ever swap back to vanilla
#     OTel Collector, the components map 1:1.
#
# Why metrics stay on the kube-prometheus-stack remoteWrite path:
#   See cluster-controllers.tf:121. Funneling metrics through Alloy too
#   would double the egress + double the Grafana Cloud active-series bill
#   for no incremental capability.

# Auth: token lives in a K8s Secret so the rendered ConfigMap is plan-diff
# friendly. River config references the token via sys.env("GRAFANA_CLOUD_TOKEN").
resource "kubernetes_secret" "alloy_grafana_cloud_token" {
  metadata {
    name      = "alloy-grafana-cloud-token"
    namespace = "monitoring"
  }

  data = {
    GRAFANA_CLOUD_TOKEN = var.grafana_cloud_token
  }

  type = "Opaque"

  depends_on = [helm_release.kube_prometheus_stack]
}

resource "helm_release" "grafana_alloy" {
  name             = "alloy"
  repository       = "https://grafana.github.io/helm-charts"
  chart            = "alloy"
  version          = "0.9.2" # TODO ADR-09: pin to chart digest
  namespace        = "monitoring"
  create_namespace = false # monitoring ns created by kube-prometheus-stack

  values = [
    yamlencode({
      alloy = {
        configMap = {
          create = true
          content = templatefile("${path.module}/alloy-config.river.tpl", {
            traces_url  = grafana_cloud_stack.main.traces_url
            traces_user = tostring(grafana_cloud_stack.main.traces_user_id)
            logs_url    = grafana_cloud_stack.main.logs_url
            logs_user   = tostring(grafana_cloud_stack.main.logs_user_id)
          })
        }

        # GRAFANA_CLOUD_TOKEN injected from the K8s Secret above; Alloy
        # River reads it via sys.env(). envFrom keeps the value out of
        # the ConfigMap and out of terraform plan diffs.
        envFrom = [
          {
            secretRef = {
              name = kubernetes_secret.alloy_grafana_cloud_token.metadata[0].name
            }
          },
        ]

        # OTLP listeners (4317 gRPC, 4318 HTTP) exposed at pod level so
        # the cluster-internal Service auto-created by the chart routes
        # workload-pod OTLP traffic in. Application points its SDK at
        # alloy.monitoring.svc.cluster.local:4318 (per helm chart values:
        # observability.otel.endpoint).
        extraPorts = [
          {
            name     = "otlp-http"
            port     = 4318
            protocol = "TCP"
          },
          {
            name     = "otlp-grpc"
            port     = 4317
            protocol = "TCP"
          },
        ]
      }

      # Single replica is sufficient for POC volume (1 primary pod's worth
      # of traces + logs). Scale to >1 only after we observe sustained
      # ingest pressure on the otelcol.processor.batch backlog metric.
      controller = {
        type     = "statefulset"
        replicas = 1
      }
    }),
  ]

  depends_on = [
    helm_release.kube_prometheus_stack,
    kubernetes_secret.alloy_grafana_cloud_token,
  ]
}
