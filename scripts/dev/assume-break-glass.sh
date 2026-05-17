#!/usr/bin/env bash
# scripts/dev/assume-break-glass.sh
#
# Assume a "break-glass" IAM role in the workload account that:
#  (a) is in the org's SCP `DenyIamPrivilegeEscalation` allow-list, so it
#      can perform iam:CreateRole / iam:PassRole / etc.
#  (b) has a trust policy that allows the operator's regular SSO PlatformAdmin
#      session — no cross-account hop needed
#
# This is the preferred "operator local terraform" path in orgs where LDZ
# has provisioned an explicit break-glass role for exactly this purpose.
# Compare with assume-controltower.sh which uses AWSControlTowerExecution
# from the management account (fallback when no break-glass role exists).
#
# Discovery model: the helper reads break-glass role name + region from
# runbook-config.yaml; if the role doesn't exist in the workload account,
# it errors out with a clear pointer to assume-controltower.sh as fallback.
#
# Usage:
#   source scripts/dev/runbook-00-bootstrap.sh    # AWS_PROFILE / AWS_ACCOUNT_ID / AWS_REGION
#   source scripts/dev/assume-break-glass.sh      # exports temp creds
#   terraform apply                                # works (SCP-exempted via break-glass)
#
# MUST be sourced (not executed) — exports temp credentials into the
# calling shell.

# Detect sourced vs executed (cross-shell: bash + zsh)
if [[ -n "${BASH_VERSION:-}" ]]; then
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        echo "ERROR: this script must be sourced, not executed." >&2
        echo "  Run:   source ${BASH_SOURCE[0]}" >&2
        exit 1
    fi
    _SCRIPT_PATH="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
    case "${ZSH_EVAL_CONTEXT:-}" in
        *:file*) : ;;
        *) echo "ERROR: this script must be sourced, not executed." >&2; exit 1 ;;
    esac
    _SCRIPT_PATH="${0}"
else
    echo "ERROR: unsupported shell (need bash 4+ or zsh 5+)." >&2
    return 1 2>/dev/null || exit 1
fi

set -u

SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"

# ============================================================================
# Required inputs
# ============================================================================
: "${AWS_PROFILE:?AWS_PROFILE not set; source runbook-00-bootstrap.sh first}"
: "${AWS_ACCOUNT_ID:?AWS_ACCOUNT_ID not set}"
: "${AWS_REGION:?AWS_REGION not set}"

# ============================================================================
# Config — break-glass role name (from config.yaml + env override)
# ============================================================================
CONFIG_FILE="$SCRIPT_DIR/runbook-config.yaml"
BREAK_GLASS_ROLE="${BREAK_GLASS_ROLE:-}"
if [[ -z "$BREAK_GLASS_ROLE" ]] && [[ -f "$CONFIG_FILE" ]] && command -v yq >/dev/null 2>&1; then
    BREAK_GLASS_ROLE=$(yq '.iam.break_glass_role // "aegis-emergency-break-glass"' "$CONFIG_FILE")
fi
BREAK_GLASS_ROLE="${BREAK_GLASS_ROLE:-aegis-emergency-break-glass}"

BG_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${BREAK_GLASS_ROLE}"
BG_SESSION_NAME="${BG_SESSION_NAME:-aegis-thu-demo}"
BG_DURATION_SECONDS="${BG_DURATION_SECONDS:-3600}"

echo "=== Assume break-glass role ==="
echo "  Target role:    $BG_ROLE_ARN"
echo "  Via profile:    $AWS_PROFILE (same-account SSO; no cross-account hop)"
echo "  Session name:   $BG_SESSION_NAME"
echo "  Duration:       ${BG_DURATION_SECONDS}s"
echo

# Pre-flight: confirm role exists
if ! aws iam get-role --role-name "$BREAK_GLASS_ROLE" --profile "$AWS_PROFILE" \
        >/dev/null 2>&1; then
    echo "  ❌ Role $BREAK_GLASS_ROLE not found in account $AWS_ACCOUNT_ID" >&2
    echo "     Fallback: source scripts/dev/assume-controltower.sh" >&2
    echo "     (uses AWSControlTowerExecution from management account)" >&2
    return 1
fi

# Assume the role
_creds=$(aws sts assume-role \
    --role-arn "$BG_ROLE_ARN" \
    --role-session-name "$BG_SESSION_NAME" \
    --duration-seconds "$BG_DURATION_SECONDS" \
    --profile "$AWS_PROFILE" \
    --query 'Credentials' --output json 2>&1)

if ! echo "$_creds" | grep -q AccessKeyId; then
    echo "  ❌ AssumeRole failed:" >&2
    echo "$_creds" | sed 's/^/     /' >&2
    return 1
fi

# Export temp creds — env vars take precedence over AWS_PROFILE in the
# credential resolution chain, so terraform / aws CLI / SDK all switch
# identity automatically.
AWS_ACCESS_KEY_ID=$(echo "$_creds" | jq -r .AccessKeyId)
AWS_SECRET_ACCESS_KEY=$(echo "$_creds" | jq -r .SecretAccessKey)
AWS_SESSION_TOKEN=$(echo "$_creds" | jq -r .SessionToken)
_expiry=$(echo "$_creds" | jq -r .Expiration)

export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

# Unset AWS_PROFILE — explicit safety: even though env vars win on
# precedence, leaving AWS_PROFILE set can confuse tooling that bypasses
# the standard SDK resolution (e.g. some CLI wrappers).
unset AWS_PROFILE

# Verify
_actual=$(aws sts get-caller-identity --query 'Arn' --output text 2>/dev/null || echo "ERROR")
if [[ "$_actual" == *"$BREAK_GLASS_ROLE"* ]]; then
    echo "  ✅ Now operating as $BREAK_GLASS_ROLE"
    echo "     ARN: $_actual"
    echo "     Expires: $_expiry  (re-source this script before then)"
else
    echo "  ⚠️  AssumeRole succeeded but identity check returned: $_actual" >&2
fi

unset _creds _expiry _actual
