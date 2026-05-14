#!/usr/bin/env bash
# scripts/dev/runbook-03-bootstrap.sh — Runbook 03 GHA OIDC automation
#
# Automates the manual steps in docs/operations/runbooks/03-github-actions-oidc.md
# for the GitHub Actions ↔ AWS OIDC trust path:
#   1. IAM OIDC provider (token.actions.githubusercontent.com) — detect + reuse if present
#   2. Trust policy + IAM role (aegis-statefulset-gha-ci)
#   3. aegis-statefulset-ci-plan-only inline policy (read-mostly + S3 tf
#      state R/W; locking via S3 native locking `use_lockfile = true`,
#      terraform 1.10+ S3 conditional writes — no DynamoDB table needed)
#   4. Capture + echo the role ARN
#   5. Set GitHub repo variables (AWS_ROLE_ARN, AWS_REGION, AWS_ACCOUNT_ID)
#
# Step 6 of the runbook (manual workflow trigger / verification) is left
# to the operator — see tail message.
#
# Idempotent — safe to re-run. Reads env vars; nothing personal hardcoded.
#
# ============================================================================
# Usage (forker / CI / operator alike)
# ============================================================================
#
#   export AWS_PROFILE=<your-sso-profile>       # e.g. "platform-admin"
#   export AWS_ACCOUNT_ID=<12-digit account>
#   export AWS_REGION=eu-central-1
#   aws sso login --profile "$AWS_PROFILE"      # if SSO-based
#   gh auth login                               # if not yet authenticated
#   bash scripts/dev/runbook-03-bootstrap.sh
#
# Optional env overrides (defaults shown):
#   GITHUB_REPO       — auto-discover via `gh repo view`; e.g. "owner/repo"
#   ROLE_NAME         — aegis-statefulset-gha-ci
#   POLICY_NAME       — aegis-statefulset-ci-plan-only
#   TF_STATE_BUCKET   — aegis-statefulset-tf-state-${AWS_ACCOUNT_ID}
#
# Naming rationale: resources are prefixed with the full repo name
# (`aegis-statefulset-`) not just `aegis-` because shared AWS accounts
# commonly have unrelated `aegis-*` resources owned by other teams.
# Full repo-name prefix avoids collisions on shared accounts.
#
# Prerequisites:
#   - AWS CLI v2 with the profile configured + SSO session active
#   - IAM admin permission on the target account (create-open-id-connect-provider,
#     create-role, put-role-policy)
#   - gh CLI authenticated with repo admin on the target repo
#   - Repo cloned at any path (script derives location from $0)

set -euo pipefail

# ============================================================================
# Path resolution — script-relative, no hardcoded paths
# ============================================================================
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ============================================================================
# Env var validation
# ============================================================================
: "${AWS_ACCOUNT_ID:?ERROR: AWS_ACCOUNT_ID not set; run scripts/dev/runbook-00-bootstrap.sh first}"
: "${AWS_REGION:?ERROR: AWS_REGION not set; run scripts/dev/runbook-00-bootstrap.sh first}"
: "${AWS_PROFILE:?ERROR: AWS_PROFILE not set; run scripts/dev/runbook-00-bootstrap.sh first}"

if ! [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "ERROR: AWS_ACCOUNT_ID must be exactly 12 digits, got: $AWS_ACCOUNT_ID" >&2
    exit 1
fi

# Tool readiness — fail fast with actionable error
if ! command -v aws >/dev/null 2>&1; then
    echo "ERROR: aws CLI not found in PATH; install AWS CLI v2 first" >&2
    exit 1
fi
if ! command -v gh >/dev/null 2>&1; then
    echo "ERROR: gh CLI not found in PATH; install GitHub CLI first (brew install gh)" >&2
    exit 1
fi

# ============================================================================
# Shared config (sourced from runbook-config.yaml — single source of truth
# for IAM role/policy names, OIDC URL/audience/thumbprint, tag-pair values)
# ============================================================================
CONFIG_FILE="${PROJ_ROOT}/scripts/dev/runbook-config.yaml"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: $CONFIG_FILE not found — required for shared resource naming" >&2
    exit 1
fi
# Allow env override (for testing); fall through to config if env unset
ROLE_NAME="${ROLE_NAME:-$(yq '.iam.role_name' "$CONFIG_FILE")}"
POLICY_NAME="${POLICY_NAME:-$(yq '.iam.policy_name' "$CONFIG_FILE")}"
OIDC_URL_FULL=$(yq '.oidc.github_url' "$CONFIG_FILE")
OIDC_AUDIENCE=$(yq '.oidc.audience' "$CONFIG_FILE")
OIDC_THUMBPRINT=$(yq '.oidc.thumbprint' "$CONFIG_FILE")
PROJECT_TAG_KEY=$(yq '.tags.project.key' "$CONFIG_FILE")
PROJECT_TAG_VAL=$(yq '.tags.project.value' "$CONFIG_FILE")
MANAGEDBY_TAG_KEY=$(yq '.tags.managed_by.key' "$CONFIG_FILE")
MANAGEDBY_TAG_VAL=$(yq '.tags.managed_by.value' "$CONFIG_FILE")

# OIDC_URL used in trust-policy condition keys is the bare host (no scheme);
# OIDC_URL_FULL (with https://) is used for create-open-id-connect-provider.
OIDC_URL="${OIDC_URL_FULL#https://}"

# ============================================================================
# Resolve optional env vars with sensible defaults
# ============================================================================
TF_STATE_BUCKET="${TF_STATE_BUCKET:-aegis-statefulset-tf-state-${AWS_ACCOUNT_ID}}"

# GITHUB_REPO — env var, else auto-discover via gh
if [[ -z "${GITHUB_REPO:-}" ]]; then
    if ! gh auth status >/dev/null 2>&1; then
        echo "ERROR: GITHUB_REPO env var unset AND gh CLI not authenticated." >&2
        echo "  Either:  export GITHUB_REPO=owner/repo" >&2
        echo "  Or:      gh auth login   # then re-run this script" >&2
        exit 1
    fi
    if ! GITHUB_REPO="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)"; then
        echo "ERROR: failed to auto-discover GITHUB_REPO via 'gh repo view'." >&2
        echo "  Run this script from within a git-cloned repo, OR set" >&2
        echo "  GITHUB_REPO=owner/repo explicitly." >&2
        exit 1
    fi
    if [[ -z "$GITHUB_REPO" ]]; then
        echo "ERROR: 'gh repo view' returned empty nameWithOwner." >&2
        exit 1
    fi
fi

# Basic shape check: owner/repo
if ! [[ "$GITHUB_REPO" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]]; then
    echo "ERROR: GITHUB_REPO must be in 'owner/repo' form, got: $GITHUB_REPO" >&2
    exit 1
fi

# Confirm gh is authenticated for downstream `gh variable set` calls
if ! gh auth status >/dev/null 2>&1; then
    echo "ERROR: gh CLI not authenticated; run 'gh auth login' first" >&2
    exit 1
fi

# ============================================================================
# Temp dir for trust-policy.json + ci-plan-only.json — never written to repo
# ============================================================================
TMPDIR_POLICIES="$(mktemp -d -t aegis-oidc-XXXXXX)"
# shellcheck disable=SC2064  # $TMPDIR_POLICIES path is set right above and
# immutable after; expanding-now is intentional + correct here.
trap "rm -rf '$TMPDIR_POLICIES' 2>/dev/null || true" EXIT

echo "  ℹ️  scratch dir for policy JSON: $TMPDIR_POLICIES (auto-removed on exit)"
echo "  ℹ️  target repo: $GITHUB_REPO"
echo "  ℹ️  role name:   $ROLE_NAME"
echo "  ℹ️  region:      $AWS_REGION"

# ============================================================================
# Pre-flight scan — show pre-existing collision-relevant resources up front
# so the operator can see at a glance what will be reused vs newly created.
# Read-only (list/get) — safe, no mutations here.
# ============================================================================
echo
echo "=== Pre-flight: scan account for existing relevant resources ==="
EXISTING_OIDC="$(aws iam list-open-id-connect-providers \
    --profile "$AWS_PROFILE" \
    --query "OpenIDConnectProviderList[?contains(Arn, '${OIDC_URL}')].Arn | [0]" \
    --output text 2>/dev/null || true)"
if [[ "$EXISTING_OIDC" == "None" ]]; then EXISTING_OIDC=""; fi
EXISTING_ROLE="$(aws iam get-role \
    --profile "$AWS_PROFILE" \
    --role-name "$ROLE_NAME" \
    --query 'Role.RoleName' \
    --output text 2>/dev/null || true)"
if [[ "$EXISTING_ROLE" == "None" ]]; then EXISTING_ROLE=""; fi
echo "  GitHub Actions OIDC provider:  ${EXISTING_OIDC:-(none — will create)}"
echo "  IAM role $ROLE_NAME:  ${EXISTING_ROLE:-(none — will create)}"

# ============================================================================
echo
echo "=== Step 1/5: IAM OIDC provider for GitHub Actions ==="
# ============================================================================
EXISTING_PROVIDER_ARN="$(aws iam list-open-id-connect-providers \
    --profile "$AWS_PROFILE" \
    --query "OpenIDConnectProviderList[?contains(Arn, '${OIDC_URL}')].Arn | [0]" \
    --output text 2>/dev/null || true)"

if [[ -n "$EXISTING_PROVIDER_ARN" && "$EXISTING_PROVIDER_ARN" != "None" ]]; then
    OIDC_PROVIDER_ARN="$EXISTING_PROVIDER_ARN"
    echo "  ℹ️  OIDC provider already exists — skipping create"
    echo "     $OIDC_PROVIDER_ARN"
else
    if ! OIDC_PROVIDER_ARN="$(aws iam create-open-id-connect-provider \
            --profile "$AWS_PROFILE" \
            --url "$OIDC_URL_FULL" \
            --client-id-list "$OIDC_AUDIENCE" \
            --thumbprint-list "$OIDC_THUMBPRINT" \
            --query 'OpenIDConnectProviderArn' \
            --output text 2>&1)"; then
        echo "  ❌ Failed to create OIDC provider:" >&2
        echo "     $OIDC_PROVIDER_ARN" >&2
        echo "     Check IAM admin permission (iam:CreateOpenIDConnectProvider)." >&2
        exit 1
    fi
    echo "  ✅ created OIDC provider"
    echo "     $OIDC_PROVIDER_ARN"
fi

# ============================================================================
echo
echo "=== Step 2/5: Trust policy + IAM role ($ROLE_NAME) ==="
# ============================================================================
TRUST_POLICY="$TMPDIR_POLICIES/trust-policy.json"
cat > "$TRUST_POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "${OIDC_PROVIDER_ARN}"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "${OIDC_URL}:aud": "${OIDC_AUDIENCE}"
        },
        "StringLike": {
          "${OIDC_URL}:sub": "repo:${GITHUB_REPO}:*"
        }
      }
    }
  ]
}
EOF

if aws iam get-role --profile "$AWS_PROFILE" --role-name "$ROLE_NAME" >/dev/null 2>&1; then
    echo "  ℹ️  role $ROLE_NAME already exists — updating trust policy (idempotent)"
    if ! AWS_ERR=$(aws iam update-assume-role-policy \
            --profile "$AWS_PROFILE" \
            --role-name "$ROLE_NAME" \
            --policy-document "file://${TRUST_POLICY}" 2>&1 >/dev/null); then
        echo "  ❌ Failed to update assume-role policy on $ROLE_NAME:" >&2
        echo "$AWS_ERR" | sed 's/^/     /' >&2
        echo "     Common causes: iam:UpdateAssumeRolePolicy denied at permission-set level," >&2
        echo "                    or organisation SCP blocks IAM mutations on this account." >&2
        exit 1
    fi
    echo "  ✅ trust policy refreshed (sub=repo:${GITHUB_REPO}:*)"
else
    if ! AWS_ERR=$(aws iam create-role \
            --profile "$AWS_PROFILE" \
            --role-name "$ROLE_NAME" \
            --assume-role-policy-document "file://${TRUST_POLICY}" \
            --description "GitHub Actions CI for aegis-statefulset (managed by runbook-03-bootstrap.sh)" \
            --tags "Key=${PROJECT_TAG_KEY},Value=${PROJECT_TAG_VAL}" "Key=${MANAGEDBY_TAG_KEY},Value=${MANAGEDBY_TAG_VAL}" \
            2>&1 >/dev/null); then
        echo "  ❌ Failed to create role $ROLE_NAME:" >&2
        echo "$AWS_ERR" | sed 's/^/     /' >&2
        echo "" >&2
        echo "  Common causes:" >&2
        echo "  - Organisation SCP explicit-denies iam:CreateRole on this account" >&2
        echo "    (look for 'explicit deny in a service control policy' in the error above)" >&2
        echo "  - Permission set lacks iam:CreateRole or iam:TagRole" >&2
        echo "  - Trust policy malformed (check the JSON above)" >&2
        echo "" >&2
        echo "  Workarounds when SCP blocks IAM mutation:" >&2
        echo "  - Have an org admin pre-create the role + attach inline policy manually" >&2
        echo "  - Use a different AWS account where the SCP does not apply" >&2
        echo "  - Skip GHA OIDC for this environment (CI workflows will be non-functional" >&2
        echo "    until role exists, but architecture / chaos demo are unaffected)" >&2
        exit 1
    fi
    echo "  ✅ created role $ROLE_NAME"
fi

# ============================================================================
echo
echo "=== Step 3/5: plan-only inline policy ($POLICY_NAME) ==="
# ============================================================================
CI_POLICY="$TMPDIR_POLICIES/ci-plan-only.json"
cat > "$CI_POLICY" <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "TerraformPlanRead",
      "Effect": "Allow",
      "Action": [
        "ec2:Describe*",
        "eks:Describe*",
        "iam:Get*",
        "iam:List*",
        "s3:GetBucketLocation",
        "s3:ListAllMyBuckets",
        "s3:ListBucket",
        "s3:GetObject",
        "kms:Describe*",
        "kms:List*",
        "logs:Describe*",
        "route53:Get*",
        "route53:List*"
      ],
      "Resource": "*"
    },
    {
      "Sid": "TerraformStateBucket",
      "Effect": "Allow",
      "Action": [
        "s3:GetObject",
        "s3:PutObject",
        "s3:DeleteObject"
      ],
      "Resource": "arn:aws:s3:::${TF_STATE_BUCKET}/*"
    }
  ]
}
EOF

# put-role-policy is upsert — re-runs are fine without an explicit check
if ! aws iam put-role-policy \
        --profile "$AWS_PROFILE" \
        --role-name "$ROLE_NAME" \
        --policy-name "$POLICY_NAME" \
        --policy-document "file://${CI_POLICY}" >/dev/null 2>&1; then
    echo "  ❌ Failed to put-role-policy on $ROLE_NAME / $POLICY_NAME." >&2
    echo "     Check iam:PutRolePolicy permission." >&2
    exit 1
fi
echo "  ✅ inline policy $POLICY_NAME applied (state bucket: $TF_STATE_BUCKET)"

# ============================================================================
echo
echo "=== Step 4/5: Capture ROLE_ARN ==="
# ============================================================================
if ! ROLE_ARN="$(aws iam get-role \
        --profile "$AWS_PROFILE" \
        --role-name "$ROLE_NAME" \
        --query 'Role.Arn' \
        --output text 2>/dev/null)"; then
    echo "  ❌ Failed to read role ARN for $ROLE_NAME." >&2
    exit 1
fi
if [[ -z "$ROLE_ARN" || "$ROLE_ARN" == "None" ]]; then
    echo "  ❌ get-role returned empty ARN — unexpected." >&2
    exit 1
fi
echo "  ✅ ROLE_ARN=$ROLE_ARN"

# ============================================================================
echo
echo "=== Step 5/5: Set GitHub repo variables ==="
# ============================================================================
_gh_var_set() {
    local name="$1" value="$2"
    if ! gh variable set "$name" --body "$value" --repo "$GITHUB_REPO" >/dev/null 2>&1; then
        echo "  ❌ Failed to set repo variable $name on $GITHUB_REPO." >&2
        echo "     Check gh auth (repo admin scope) and that the repo exists." >&2
        return 1
    fi
    echo "  ✅ set $name"
}

_gh_var_set AWS_ROLE_ARN    "$ROLE_ARN"
_gh_var_set AWS_REGION      "$AWS_REGION"
_gh_var_set AWS_ACCOUNT_ID  "$AWS_ACCOUNT_ID"

echo
echo "  Current repo variables on $GITHUB_REPO:"
if ! gh variable list --repo "$GITHUB_REPO" 2>/dev/null | sed 's/^/    /'; then
    echo "    ⚠️  could not list repo variables — check gh auth scope"
fi

# ============================================================================
echo
echo "=== Done — Runbook 03 complete ==="
# ============================================================================
echo "  ROLE_ARN: $ROLE_ARN"
echo "  Repo:     $GITHUB_REPO"
echo "  Region:   $AWS_REGION"
echo
echo "Next: trigger terraform-plan.yml from the GitHub UI or:"
echo "  gh workflow run terraform-plan.yml --repo $GITHUB_REPO"
echo "  gh run watch --repo $GITHUB_REPO"
echo
echo "Or read the next runbook (Grafana Cloud setup):"
echo "  cat $PROJ_ROOT/docs/operations/runbooks/04-grafana-cloud-setup.md"
