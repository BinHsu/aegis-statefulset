# route53.tf
#
# DNS records for the platform. Single-region, single A record per
# consensus.md § 3 — no Route 53 failover policy in POC because:
#   - ALB is regional and natively multi-AZ.
#   - Cross-region failover is out of POC scope (ADR-04).
#
# What lives here:
#   - The hosted zone (looked up — assumes operator manages the zone).
#   - The apex/wildcard A-records pointing at the ALB.
#   - Per-tenant CNAMEs for migration's "ExternalName bridge" pattern
#     (ADR-05 Strangler Fig — DNS is the cutover surface).

data "aws_route53_zone" "main" {
  name         = var.domain_name
  private_zone = false
}

# Apex record — alias to the ALB.
resource "aws_route53_record" "apex" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# Wildcard for tenant subdomains (e.g. acme.aegis.example.com).
resource "aws_route53_record" "wildcard" {
  zone_id = data.aws_route53_zone.main.zone_id
  name    = "*.${var.domain_name}"
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

# Health check on the ALB. Used by Route 53 evaluate_target_health and
# also exported for CloudWatch alerting parity with multi-vantage probes.
resource "aws_route53_health_check" "alb" {
  fqdn              = aws_lb.main.dns_name
  port              = 443
  type              = "HTTPS"
  resource_path     = "/healthz"
  failure_threshold = 3
  request_interval  = 30

  tags = merge(local.common_tags, {
    Name = "aegis-statefulset-${var.environment}-alb-health"
  })
}

# Migration helper — ExternalName CNAMEs are managed in K8s, but for the
# legacy host-side cutover (step 6 of per-shard-cutover.sh) the operator
# updates CNAMEs in this zone too. Output the zone ID so the cutover
# script can target it without hard-coding.
output "route53_zone_id" {
  value       = data.aws_route53_zone.main.zone_id
  description = "Hosted zone ID for migration cutover scripts"
}

# --------------------------------------------------------------------
# Cross-region weighted routing (per ADR-04)
# --------------------------------------------------------------------
# api.<domain> is the cross-region cutover surface. Default weights:
#   primary_traffic_weight = 100  (eu-central-1)
#   dr_traffic_weight      = 0    (eu-west-1)
# DR cutover is manual (per ADR-04): operator runs
#   aws route53 change-resource-record-sets
# to flip the weights — no health-check auto-failover so brownouts in
# primary don't surprise-evacuate to a colder DR region.

resource "aws_route53_record" "api_primary" {
  zone_id        = data.aws_route53_zone.main.zone_id
  name           = "api.${var.domain_name}"
  type           = "A"
  set_identifier = "primary-region"

  weighted_routing_policy {
    weight = var.primary_traffic_weight
  }

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = false # Manual cutover only — no auto-failover
  }
}

resource "aws_route53_record" "api_dr" {
  count = var.dr_region_alb_dns != "" ? 1 : 0

  zone_id        = data.aws_route53_zone.main.zone_id
  name           = "api.${var.domain_name}"
  type           = "A"
  set_identifier = "dr-region"

  weighted_routing_policy {
    weight = var.dr_traffic_weight
  }

  alias {
    name                   = var.dr_region_alb_dns
    zone_id                = var.dr_region_alb_zone_id
    evaluate_target_health = false
  }
}
