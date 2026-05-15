# Cluster-level controllers managed via terraform helm_release.
# Layer 2 of Three-Layer DR (per ADR-04):
#   Layer 1: Terraform infra (this repo)
#   Layer 2: helm_release for cluster controllers (this file)
#   Layer 3: Velero (handles per-namespace snapshot/restore — Helm chart)
#
# Provider configured to use the just-created EKS cluster.
#
# Chart pinning: explicit chart versions per ADR-09.
# TODO production: per ADR-09 (SHA pinning supply chain), pin chart digests via
#   `helm pull --version <ver> --untar` + commit chart SHA in a separate manifest,
#   or vendor charts into the repo at a known SHA. Tag-based versions are
#   tag-mutable; SHA / digest pins are immutable.

provider "helm" {
  kubernetes {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
    }
  }
}

# kubernetes provider for the raw K8s resources we manage from terraform
# (e.g. kubernetes_secret holding the Grafana Cloud token consumed by Alloy).
# Same auth shape as the helm provider's embedded kubernetes{} block.
provider "kubernetes" {
  host                   = aws_eks_cluster.main.endpoint
  cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name]
  }
}

# AWS Load Balancer Controller — manages ALB target group bindings (TGB) for
# the application gateways and supports the Strangler Fig migration pattern
# (per ADR-05) by allowing per-tenant target group cutovers.
resource "helm_release" "aws_load_balancer_controller" {
  name       = "aws-load-balancer-controller"
  repository = "https://aws.github.io/eks-charts"
  chart      = "aws-load-balancer-controller"
  version    = "1.6.2" # TODO ADR-09: pin to chart digest
  namespace  = "kube-system"

  set {
    name  = "clusterName"
    value = aws_eks_cluster.main.name
  }

  # Bypass IMDSv2 introspection. EKS managed node groups default to
  # IMDSv2 hop-limit=1, but a pod calling IMDS via containerd takes
  # 2 hops (pod → host → IMDS), so the metadata fetch returns 401.
  # Passing region + vpcId explicitly avoids the metadata round-trip.
  set {
    name  = "region"
    value = var.aws_region
  }
  set {
    name  = "vpcId"
    value = module.vpc.vpc_id
  }

  set {
    name  = "serviceAccount.name"
    value = "aws-load-balancer-controller"
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.alb_controller.arn
  }

  depends_on = [
    aws_eks_node_group.stateful_master,
    aws_eks_node_group.stateless_master
  ]
}

# External Secrets Operator — pulls Secrets Manager material into the cluster
# without baking secrets into manifests (per ADR-07 secrets discipline).
resource "helm_release" "external_secrets" {
  name             = "external-secrets"
  repository       = "https://charts.external-secrets.io"
  chart            = "external-secrets"
  version          = "0.9.11" # TODO ADR-09: pin to chart digest
  namespace        = "external-secrets"
  create_namespace = true

  depends_on = [helm_release.aws_load_balancer_controller]
}

# Kyverno — admission policy engine. Enforces tenant-isolation, image-source,
# and topology-spread guardrails referenced in helm/policies/.
resource "helm_release" "kyverno" {
  name             = "kyverno"
  repository       = "https://kyverno.github.io/kyverno/"
  chart            = "kyverno"
  version          = "3.1.4" # TODO ADR-09: pin to chart digest
  namespace        = "kyverno"
  create_namespace = true

  depends_on = [helm_release.aws_load_balancer_controller]
}

# monitoring namespace — created explicitly (not via the helm release's
# create_namespace) so the Grafana Cloud remoteWrite secret can land in
# it BEFORE the Prometheus CRD is reconciled. The Prometheus operator's
# remoteWrite basicAuth requires a SecretKeySelector (name + key); it
# cannot take an inline credential value.
resource "kubernetes_namespace" "monitoring" {
  metadata {
    name = "monitoring"
  }
}

# Grafana Cloud basic-auth credentials for Prometheus remoteWrite → Mimir.
# username = the stack's numeric prometheus_user_id, password = the
# access-policy token. Consumed by the Prometheus CRD via the
# basicAuth.{username,password}.{name,key} selectors set on the helm
# release below.
resource "kubernetes_secret" "prometheus_remote_write" {
  metadata {
    name      = "grafana-cloud-remote-write"
    namespace = kubernetes_namespace.monitoring.metadata[0].name
  }

  data = {
    username = tostring(grafana_cloud_stack.main.prometheus_user_id)
    password = var.grafana_cloud_token
  }

  type = "Opaque"
}

# kube-prometheus-stack — Prometheus + Alertmanager + Grafana operator stack.
# Per ADR-06 the in-cluster stack is the source of truth for short-window
# observability; long-term goes to Grafana Cloud (see grafana-cloud.tf).
#
# remoteWrite forwards in-cluster Prometheus samples to Grafana Cloud Mimir.
# Without this, dashboards over in grafana-cloud.tf show "No data" forever
# because the data path stops at the in-cluster Prometheus — ServiceMonitor
# scrapes work fine, but the samples never leave the cluster.
#
# Auth = Grafana Cloud basic-auth via the grafana-cloud-remote-write
# secret (scope must include metrics:write per runbook 04 § 2). The URL
# gets the /push suffix — grafana_cloud_stack.main.prometheus_url returns
# the query base, remote_write needs the push endpoint.
resource "helm_release" "kube_prometheus_stack" {
  name             = "kube-prometheus-stack"
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = "56.6.2" # TODO ADR-09: pin to chart digest
  namespace        = kubernetes_namespace.monitoring.metadata[0].name
  create_namespace = false

  set {
    name  = "prometheus.prometheusSpec.remoteWrite[0].url"
    value = "${grafana_cloud_stack.main.prometheus_url}/push"
  }

  # basicAuth on the Prometheus CRD takes a SecretKeySelector (name +
  # key), NOT an inline value — username/password reference keys in the
  # grafana-cloud-remote-write secret created above.
  set {
    name  = "prometheus.prometheusSpec.remoteWrite[0].basicAuth.username.name"
    value = kubernetes_secret.prometheus_remote_write.metadata[0].name
  }

  set {
    name  = "prometheus.prometheusSpec.remoteWrite[0].basicAuth.username.key"
    value = "username"
  }

  set {
    name  = "prometheus.prometheusSpec.remoteWrite[0].basicAuth.password.name"
    value = kubernetes_secret.prometheus_remote_write.metadata[0].name
  }

  set {
    name  = "prometheus.prometheusSpec.remoteWrite[0].basicAuth.password.key"
    value = "password"
  }

  depends_on = [
    helm_release.aws_load_balancer_controller,
    kubernetes_secret.prometheus_remote_write,
  ]
}

# Velero — Layer 3 of Three-Layer DR (per ADR-04). EBS snapshot + S3 BSL.
# IRSA via velero-storage.tf; bucket via velero-storage.tf.
resource "helm_release" "velero" {
  name             = "velero"
  repository       = "https://vmware-tanzu.github.io/helm-charts"
  chart            = "velero"
  version          = "5.2.0" # TODO ADR-09: pin to chart digest
  namespace        = "velero"
  create_namespace = true

  # Skip the upgradeCRDs init Job. Default kubectl image
  # docker.io/bitnami/kubectl:1.30 no longer exists on Docker Hub
  # (Bitnami switched to full-semver tag schema). CRDs are still
  # installed via the chart's regular templates, just without the
  # post-upgrade migration hook. Re-enable + pin to an existing tag
  # (e.g. docker.io/bitnami/kubectl:1.30.6) when the velero chart
  # is bumped to a version where this hook is needed.
  set {
    name  = "upgradeCRDs"
    value = "false"
  }

  set {
    name  = "credentials.useSecret"
    value = "false"
  }

  set {
    name  = "serviceAccount.server.create"
    value = "true"
  }

  set {
    name  = "serviceAccount.server.name"
    value = "velero"
  }

  set {
    name  = "serviceAccount.server.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.velero.arn
  }

  set {
    name  = "configuration.backupStorageLocation[0].name"
    value = "default"
  }

  set {
    name  = "configuration.backupStorageLocation[0].provider"
    value = "aws"
  }

  set {
    name  = "configuration.backupStorageLocation[0].bucket"
    value = aws_s3_bucket.velero_bsl.id
  }

  set {
    name  = "configuration.backupStorageLocation[0].config.region"
    value = var.aws_region
  }

  # Source-region VolumeSnapshotLocation — used by operational Schedule
  # (Schedule A, 5-min cadence). All snapshots in source region.
  set {
    name  = "configuration.volumeSnapshotLocation[0].name"
    value = "source-region"
  }

  set {
    name  = "configuration.volumeSnapshotLocation[0].provider"
    value = "aws"
  }

  set {
    name  = "configuration.volumeSnapshotLocation[0].config.region"
    value = var.aws_region
  }

  # DR-region VolumeSnapshotLocation — used by DR-tier Schedule (Schedule
  # B, 4h cadence). When that schedule runs with snapshotMoveData=true,
  # Velero invokes EBS CopySnapshot to replicate to DR region.
  # Per ADR-04 § "dual-cadence pattern" (operational vs DR-tier).
  set {
    name  = "configuration.volumeSnapshotLocation[1].name"
    value = "dr-region"
  }

  set {
    name  = "configuration.volumeSnapshotLocation[1].provider"
    value = "aws"
  }

  set {
    name  = "configuration.volumeSnapshotLocation[1].config.region"
    value = var.dr_region
  }

  # Source-region operational BSL — used by Schedule A, no replication
  # (per FSB dual-bucket pattern; see velero-storage.tf).
  set {
    name  = "configuration.backupStorageLocation[1].name"
    value = "operational"
  }

  set {
    name  = "configuration.backupStorageLocation[1].provider"
    value = "aws"
  }

  set {
    name  = "configuration.backupStorageLocation[1].bucket"
    value = aws_s3_bucket.velero_bsl_operational.id
  }

  set {
    name  = "configuration.backupStorageLocation[1].config.region"
    value = var.aws_region
  }

  depends_on = [
    aws_iam_role_policy.velero,
    aws_s3_bucket.velero_bsl,
    aws_s3_bucket.velero_bsl_operational
  ]
}

# Karpenter — stateless tier auto-scaling (per ADR-02 mode-aware horizontal
# scaling). Stateful tier remains on fixed per-AZ MNGs.
resource "helm_release" "karpenter" {
  name       = "karpenter"
  repository = "oci://public.ecr.aws/karpenter"
  chart      = "karpenter"
  # Pinned to the last v0.x line to avoid the v1.x CRD migration
  # (karpenter.sh/v1alpha5 → v1) which requires manifest rewrites in
  # NodePool / EC2NodeClass elsewhere. Bump to 1.x when those CRDs are
  # updated together. NOTE: the OCI chart tag has no `v` prefix —
  # `0.37.0`, not `v0.37.0` (the v-prefixed tag 404s).
  version          = "0.37.0" # TODO ADR-09: pin to chart digest
  namespace        = "karpenter"
  create_namespace = true

  set {
    name  = "settings.clusterName"
    value = aws_eks_cluster.main.name
  }

  set {
    name  = "serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = aws_iam_role.karpenter.arn
  }

  depends_on = [helm_release.aws_load_balancer_controller]
}

# ArgoCD — optional, deployed via terraform when enabled. Otherwise managed
# out-of-band by the platform team.
resource "helm_release" "argocd" {
  count = var.enable_argocd ? 1 : 0

  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = "5.51.6" # TODO ADR-09: pin to chart digest
  namespace        = "argocd"
  create_namespace = true

  depends_on = [helm_release.aws_load_balancer_controller]
}
