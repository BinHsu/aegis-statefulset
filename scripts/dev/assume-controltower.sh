#!/usr/bin/env bash
# scripts/dev/assume-controltower.sh
#
# Fetch a 1-hour AWS session via AWSControlTowerExecution role in the
# target workload account, sourced from the org's management account.
#
# Why: in mature Control-Tower-managed AWS orgs, SCPs typically deny
# IAM mutations from regular member-account principals (including SSO
# administrative roles like PlatformAdmin). The SCP allow-list usually
# includes AWSControlTowerExecution as the canonical "bootstrap"
# principal — it's how Control Tower itself provisions baseline
# resources across member accounts. Borrowing this principal lets
# `terraform apply` run from a local shell against a workload account
# without needing GHA OIDC + a custom CI role (which itself would need
# Control Tower to provision...).
#
# Usage:
#   source scripts/dev/runbook-00-bootstrap.sh           # sets AWS_ACCOUNT_ID etc
#   source scripts/dev/assume-controltower.sh            # exports temp creds
#   terraform apply                                       # works
#
# MUST be sourced (not executed) — exports temp credentials into the
# calling shell.

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "ERROR: this script must be sourced, not executed." >&2
    echo "  Run:   source ${BASH_SOURCE[0]}" >&2
    exit 1
fi

set -u

# ============================================================================
# Required inputs (from runbook-00-bootstrap.sh or operator)
# ============================================================================
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID not set; source runbook-00-bootstrap.sh first}"
: "${AWS_REGION:?AWS_REGION not set}"

# ============================================================================
# Optional env (defaults sensible for the standard Control Tower setup)
# ============================================================================
CTEXEC_ROLE_ARN="${CTEXEC_ROLE_ARN:-arn:aws:iam::${AWS_ACCOUNT_ID}:role/AWSControlTowerExecution}"
CTEXEC_VIA_PROFILE="${CTEXEC_VIA_PROFILE:-aegis-management-admin}"
CTEXEC_SESSION_NAME="${CTEXEC_SESSION_NAME:-aegis-thu-demo}"
CTEXEC_DURATION_SECONDS="${CTEXEC_DURATION_SECONDS:-3600}"

echo "=== Assume AWSControlTowerExecution ==="
echo "  Target role:    $CTEXEC_ROLE_ARN"
echo "  Via profile:    $CTEXEC_VIA_PROFILE"
echo "  Session name:   $CTEXEC_SESSION_NAME"
echo "  Duration:       ${CTEXEC_DURATION_SECONDS}s"
echo

# Verify management profile is SSO-authenticated
if ! aws sts get-caller-identity --profile "$CTEXEC_VIA_PROFILE" >/dev/null 2>&1; then
    echo "  ❌ Profile $CTEXEC_VIA_PROFILE not authenticated." >&2
    echo "     Run: aws sso login --profile $CTEXEC_VIA_PROFILE" >&2
    return 1
fi

# Assume the role
_creds=$(aws sts assume-role \
    --role-arn "$CTEXEC_ROLE_ARN" \
    --role-session-name "$CTEXEC_SESSION_NAME" \
    --duration-seconds "$CTEXEC_DURATION_SECONDS" \
    --profile "$CTEXEC_VIA_PROFILE" \
    --query 'Credentials' --output json 2>&1)

if ! echo "$_creds" | grep -q AccessKeyId; then
    echo "  ❌ AssumeRole failed:" >&2
    echo "$_creds" | sed 's/^/     /' >&2
    return 1
fi

# Export temp credentials into the calling shell
AWS_ACCESS_KEY_ID=$(echo "$_creds" | jq -r .AccessKeyId)
AWS_SECRET_ACCESS_KEY=$(echo "$_creds" | jq -r .SecretAccessKey)
AWS_SESSION_TOKEN=$(echo "$_creds" | jq -r .SessionToken)
_expiry=$(echo "$_creds" | jq -r .Expiration)

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# Unset AWS_PROFILE so AWS CLI uses the env-var temp creds, not the profile
# (env vars take precedence over profile, but unsetting is explicit + safer)
unset AWS_PROFILE

# Verify
_actual=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo "ERROR")
if [[ "$_actual" == *AWSControlTowerExecution* ]]; then
    echo "  ✅ Now operating as AWSControlTowerExecution"
    echo "     ARN: $_actual"
    echo "     Expires: $_expiry  (re-run this script before then)"
else
    echo "  ⚠️  AssumeRole succeeded but identity check returned: $_actual" >&2
fi

# Cleanup local scratch vars
unset _creds _expiry _actual
