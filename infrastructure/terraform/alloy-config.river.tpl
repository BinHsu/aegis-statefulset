// alloy-config.river — Grafana Alloy configuration for the cluster.
//
// Scope: Logs + Traces only.
//   - Logs   → Grafana Cloud Loki   (pod stdout discovered via K8s API)
//   - Traces → Grafana Cloud Tempo  (OTLP/HTTP receiver on :4318, gRPC :4317)
//
// Metrics intentionally NOT routed through Alloy — the in-cluster Prometheus
// (kube-prometheus-stack helm release in cluster-controllers.tf) already
// remoteWrites scraped samples directly to Grafana Cloud Mimir. Funneling
// the same metrics through Alloy too would double the egress + double the
// active-series billing.
//
// Auth model: numeric user IDs are non-sensitive and templated inline;
// the Grafana Cloud API token is injected as the GRAFANA_CLOUD_TOKEN env
// var (mounted from a K8s Secret) and referenced via sys.env() so the
// rendered ConfigMap stays diff-friendly in terraform plan output.
//
// URL conventions (Grafana Cloud, late 2025):
//   Tempo OTLP HTTP write path: <traces_url>/otlp + Alloy appends /v1/traces
//                               → final path /otlp/v1/traces ✓
//   Loki push path:             <logs_url>/loki/api/v1/push  ✓

// ---- Traces: OTLP receiver → Tempo --------------------------------------

otelcol.receiver.otlp "default" {
  http {
    endpoint = "0.0.0.0:4318"
  }
  grpc {
    endpoint = "0.0.0.0:4317"
  }
  output {
    traces = [otelcol.processor.batch.default.input]
  }
}

otelcol.processor.batch "default" {
  // Default 1s timeout; bound by 8192 spans per batch. Good for POC load;
  // tail-sampling per ADR-06 § 4 stays in-collector and is the next layer
  // to wire when trace volume grows.
  output {
    traces = [otelcol.exporter.otlphttp.tempo.input]
  }
}

otelcol.exporter.otlphttp "tempo" {
  client {
    endpoint = "${traces_url}/otlp"
    auth     = otelcol.auth.basic.tempo.handler
  }
}

otelcol.auth.basic "tempo" {
  username = "${traces_user}"
  password = sys.env("GRAFANA_CLOUD_TOKEN")
}

// ---- Logs: K8s pod discovery → Loki -------------------------------------

discovery.kubernetes "pods" {
  role = "pod"
}

discovery.relabel "pods" {
  targets = discovery.kubernetes.pods.targets

  // Keep only pods in workload namespaces; drop kube-system / monitoring /
  // velero stack chatter that doesn't help the 90-second debug workflow.
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    regex         = "kube-system|kube-public|kube-node-lease"
    action        = "drop"
  }

  // Expose the labels Grafana dashboards filter on.
  rule {
    source_labels = ["__meta_kubernetes_namespace"]
    target_label  = "namespace"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_name"]
    target_label  = "pod"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_container_name"]
    target_label  = "container"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_name"]
    target_label  = "app"
  }
  rule {
    source_labels = ["__meta_kubernetes_pod_label_app_kubernetes_io_component"]
    target_label  = "component"
  }
}

loki.source.kubernetes "pods" {
  targets    = discovery.relabel.pods.output
  forward_to = [loki.write.grafana_cloud.receiver]
}

loki.write "grafana_cloud" {
  endpoint {
    url = "${logs_url}/loki/api/v1/push"

    basic_auth {
      username = "${logs_user}"
      password = sys.env("GRAFANA_CLOUD_TOKEN")
    }
  }
}
