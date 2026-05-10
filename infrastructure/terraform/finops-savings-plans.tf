# Savings Plan analysis per ADR-10.
#
# This file does NOT auto-purchase a Savings Plan. SP commitment is a 1-year
# financial obligation; purchase routes through human approval (finance + on-call
# engineering lead sign-off) via the AWS console after monthly FinOps review.
# Terraform's role here is to (a) document the recommended commitment and (b)
# expose it as an output that the dashboard / runbook can reference.
#
# Sizing rationale (per ADR-04, ADR-02):
#   - Stateful tier baseline = 9 × r6id.2xlarge always-on (1:1 to LevelDB pods)
#   - On-demand price ~$0.50/hr × 9 nodes × 730 hr/mo ≈ $3,285/month
#   - Recommended SP commitment = 70% of baseline = ~$2,300/month committed
#   - Compute SP @ "No Upfront, 1Y" yields ~30% discount = ~$700/month savings
#   - 30% headroom on-demand absorbs scale-up / instance-family churn
#
# Why "Compute SP" vs "EC2 Instance SP":
#   - Compute SP applies across instance families AND covers Fargate / Lambda
#   - EC2 Instance SP is cheaper but locks to one family in one region
#   - Stateful tier is pinned to r6id today, but flexibility outweighs the
#     incremental discount as Fargate / Karpenter family expansion is on the
#     roadmap (consensus § 16, out of POC).
#
# aws_ce_recommendations data source is not yet GA in the AWS provider as of
# this writing. Until it lands, the recommendation is encoded as a local +
# output for human review.

locals {
  savings_plan_recommendation = {
    type           = "Compute"    # broader than EC2 — covers Fargate / Lambda
    term           = "1Y"         # 1-year balances flexibility + savings
    payment_option = "No Upfront" # operational cash flow

    # Stateful tier baseline (always-on per ADR-04, sized 1:1 per ADR-02).
    stateful_baseline_hourly_usd  = 4.50 # 9 × r6id.2xlarge × ~$0.50/hr
    stateful_baseline_monthly_usd = 3285 # × 730 hr/mo

    # Recommended commitment = 70% of stateful baseline.
    recommended_commitment_hourly_usd  = 3.15
    recommended_commitment_monthly_usd = 2300

    # Estimated savings @ ~30% discount on the committed slice.
    estimated_savings_usd_monthly = 700

    # Stateless tier: stays on-demand. Karpenter consolidation (per ADR-02)
    # right-sizes capacity; SP commitment on top would be over-provisioning
    # for the variable workload.
    stateless_strategy = "on-demand + Karpenter consolidation"

    # Spot strategy: explicitly forbidden on stateful tier (ADR-04). Stateless
    # spot adoption deferred to Wave 2B per consensus § 16.
    spot_policy = "stateful=forbidden; stateless=deferred"

    # Review cadence — quarterly, with monthly FinOps review checkpoint.
    review_cadence = "quarterly commitment review; monthly utilisation check"
  }
}

# Output for human review before purchase. Surfaced via `terraform output`
# during the monthly FinOps review meeting; used to drive the console-side
# SP purchase action.
output "savings_plan_recommendation" {
  description = "Savings Plan commitment recommendation per ADR-10. Review before purchase via AWS console; do not auto-apply."
  value       = local.savings_plan_recommendation
}
