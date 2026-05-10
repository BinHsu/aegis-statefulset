-- =============================================================================
-- Per-tenant cost attribution — Athena queries (per ADR-040)
-- =============================================================================
-- Joins CUR with the tenant cost dimension propagated from pod label
-- aegis.io/tenant-id via Container Insights → CloudWatch metric dimensions.
--
-- Pre-requisites:
--   1. CUR table populated (see infrastructure/terraform/finops-cur-athena.tf).
--      First delivery cycle is 24-48h post-apply; queries return empty
--      until the first CUR partition lands.
--   2. Container Insights enabled on EKS cluster (see helm chart values
--      finops.cost_metrics.scrape_enabled).
--   3. Pod labels include aegis.io/tenant-id (set by placement service per
--      ADR-001 — per-tenant pod model means this label exists by construction).
--   4. Cost Allocation Tags activated in AWS Billing Console for:
--      Project, Environment, Tier, Component, CostCenter, Owner, DataClass,
--      BackupPolicy.
--
-- Schema notes:
--   - cur_view assumes the standard CUR Parquet schema with RESOURCES and
--     SPLIT_COST_ALLOCATION_DATA enabled.
--   - tenant_cost_view is a materialised join of CUR with the tenant
--     dimension; create as a Glue table over the join result.
--   - User-defined tags in CUR Parquet schema appear as columns named
--     resource_tags_user_<tag_lowercase>.
-- =============================================================================


-- -----------------------------------------------------------------------------
-- Q1: Top 10 tenants by monthly compute + storage cost
-- -----------------------------------------------------------------------------
-- Used by Grafana dashboard panel #4 (top tenants table).
-- Drives chargeback / showback line items in monthly FinOps review.
SELECT
    tenant_id,
    SUM(CASE WHEN line_item_product_code IN ('AmazonEC2', 'AmazonEKS') THEN line_item_unblended_cost ELSE 0 END) AS compute_cost,
    SUM(CASE WHEN line_item_product_code = 'AmazonEBS'                THEN line_item_unblended_cost ELSE 0 END) AS storage_cost,
    SUM(CASE WHEN line_item_product_code = 'AmazonS3'                 THEN line_item_unblended_cost ELSE 0 END) AS backup_cost,
    SUM(CASE WHEN line_item_product_code = 'AWSDataTransfer'          THEN line_item_unblended_cost ELSE 0 END) AS network_cost,
    SUM(line_item_unblended_cost) AS total_cost
FROM tenant_cost_view
WHERE billing_period_start >= date_trunc('month', current_date)
  AND billing_period_start <  date_trunc('month', current_date + interval '1' month)
GROUP BY tenant_id
ORDER BY total_cost DESC
LIMIT 10;


-- -----------------------------------------------------------------------------
-- Q2: Component breakdown (matches default_tags Component)
-- -----------------------------------------------------------------------------
-- Used by Grafana dashboard panel #3 (cost-by-component bar chart).
-- Surfaces stateful vs backup vs network vs observability spend split.
SELECT
    resource_tags_user_component AS component,
    SUM(line_item_unblended_cost) AS total_cost,
    COUNT(DISTINCT line_item_resource_id) AS resource_count
FROM cur_view
WHERE billing_period_start = date_trunc('month', current_date)
  AND resource_tags_user_project = 'aegis-statefulset'
GROUP BY resource_tags_user_component
ORDER BY total_cost DESC;


-- -----------------------------------------------------------------------------
-- Q3: Anomaly check — daily cost vs 30-day average per tier
-- -----------------------------------------------------------------------------
-- Complement to AWS Cost Anomaly Detector. AWS detector triggers on absolute
-- impact >= $100; this query surfaces percentage deviation per tier, which
-- catches earlier signal on tier-level drift even when absolute $ is small.
WITH daily_cost AS (
    SELECT
        DATE(line_item_usage_start_date) AS usage_date,
        resource_tags_user_tier          AS tier,
        SUM(line_item_unblended_cost)    AS day_cost
    FROM cur_view
    WHERE line_item_usage_start_date >= current_date - interval '30' day
      AND resource_tags_user_project = 'aegis-statefulset'
    GROUP BY DATE(line_item_usage_start_date), resource_tags_user_tier
)
SELECT
    usage_date,
    tier,
    day_cost,
    AVG(day_cost) OVER (
        PARTITION BY tier
        ORDER BY usage_date
        ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING
    ) AS avg_30d,
    (day_cost / NULLIF(
        AVG(day_cost) OVER (
            PARTITION BY tier
            ORDER BY usage_date
            ROWS BETWEEN 30 PRECEDING AND 1 PRECEDING
        ), 0)
    ) - 1 AS pct_deviation
FROM daily_cost
WHERE usage_date >= current_date - interval '7' day
ORDER BY usage_date DESC, tier;


-- -----------------------------------------------------------------------------
-- Q4: Savings Plan utilisation — daily check
-- -----------------------------------------------------------------------------
-- Used by Grafana dashboard panel #8 (SP utilisation timeseries).
-- Targets:
--   < 80% sustained = SP over-provisioned (consider letting commitment lapse)
--   80-100%         = healthy band
--   > 100%          = uncovered on-demand spend (consider increasing commitment)
SELECT
    DATE(line_item_usage_start_date) AS usage_date,
    SUM(savings_plan_used_commitment) AS sp_used_usd,
    SUM(savings_plan_total_commitment_to_date) AS sp_committed_usd,
    SUM(savings_plan_used_commitment)
        / NULLIF(SUM(savings_plan_total_commitment_to_date), 0)
        * 100 AS sp_utilization_pct
FROM cur_view
WHERE line_item_usage_start_date >= current_date - interval '7' day
  AND line_item_line_item_type IN ('SavingsPlanCoveredUsage', 'SavingsPlanRecurringFee')
GROUP BY DATE(line_item_usage_start_date)
ORDER BY usage_date DESC;


-- -----------------------------------------------------------------------------
-- Q5: EBS waste detection (high-cost volumes, low utilisation candidates)
-- -----------------------------------------------------------------------------
-- Surfaces EBS volumes ranked by monthly cost. Pairs with CloudWatch metric
-- VolumeIdleTime to identify candidates for downsize / deletion.
-- Useful input for monthly FinOps review.
SELECT
    line_item_resource_id              AS volume_id,
    SUM(line_item_usage_amount)        AS total_gb_hours,
    SUM(line_item_unblended_cost)      AS total_cost,
    resource_tags_user_component       AS component,
    resource_tags_user_tier            AS tier,
    resource_tags_user_dataclass       AS data_class,
    MAX(line_item_availability_zone)   AS az
FROM cur_view
WHERE line_item_product_code = 'AmazonEBS'
  AND line_item_usage_type LIKE '%VolumeUsage%'
  AND billing_period_start = date_trunc('month', current_date)
  AND resource_tags_user_project = 'aegis-statefulset'
GROUP BY line_item_resource_id,
         resource_tags_user_component,
         resource_tags_user_tier,
         resource_tags_user_dataclass
ORDER BY total_cost DESC
LIMIT 50;


-- -----------------------------------------------------------------------------
-- Q6: NAT gateway egress audit (per ADR-026 NetworkPolicy reduces this)
-- -----------------------------------------------------------------------------
-- NAT gateway egress is a stealth cost line — easy to overlook, often
-- order-of-magnitude larger than NAT instance-hours. NetworkPolicy reduces
-- east-west NAT traffic; VPC endpoints (Interface / Gateway) reduce
-- north-south. This query surfaces the bill for both.
SELECT
    DATE(line_item_usage_start_date) AS usage_date,
    line_item_usage_type             AS nat_usage_type,
    SUM(line_item_usage_amount)      AS gb_processed,
    SUM(line_item_unblended_cost)    AS cost_usd
FROM cur_view
WHERE line_item_product_code = 'AmazonVPC'
  AND line_item_usage_type LIKE '%NatGateway%'
  AND line_item_usage_start_date >= date_trunc('month', current_date)
GROUP BY DATE(line_item_usage_start_date), line_item_usage_type
ORDER BY usage_date DESC, cost_usd DESC;


-- -----------------------------------------------------------------------------
-- Q7: Untagged resource audit (tag governance)
-- -----------------------------------------------------------------------------
-- Surfaces resources missing the day-1 mandatory tag set. Run before each
-- monthly FinOps review; expected output is the empty set.
SELECT
    line_item_resource_id          AS resource_id,
    line_item_product_code         AS service,
    SUM(line_item_unblended_cost)  AS month_cost
FROM cur_view
WHERE billing_period_start = date_trunc('month', current_date)
  AND (resource_tags_user_project   IS NULL
    OR resource_tags_user_component IS NULL
    OR resource_tags_user_tier      IS NULL
    OR resource_tags_user_owner     IS NULL)
GROUP BY line_item_resource_id, line_item_product_code
HAVING SUM(line_item_unblended_cost) > 0
ORDER BY month_cost DESC
LIMIT 100;
