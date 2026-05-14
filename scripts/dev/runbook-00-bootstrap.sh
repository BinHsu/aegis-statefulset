#!/usr/bin/env bash
# scripts/dev/runbook-00-bootstrap.sh — pre-runbook environment bootstrap
#
# Runs before any of runbooks 01-04. Idempotent — safe to re-run any time.
# Interactive if env vars unset; fully scripted if env vars pre-set.
#
# ============================================================================
# What this does
# ============================================================================
#   1. Resolves AWS_PROFILE / AWS_ACCOUNT_ID / AWS_REGION — interactive
#      prompts if not pre-set; auto-skip if env vars already exported
#   2. Optionally runs `aws sso login` (skip if already authenticated)
#   3. Cross-checks identity matches the resolved account ID
#   4. Exports env vars into the shell session
#   5. Ensures infrastructure/terraform/terraform.tfvars exists with demo
#      overrides (idempotent — won't clobber if already there)
#   6. Prints readiness checklist for the runbook toolchain
#
# ============================================================================
# Usage
# ============================================================================
#
# (A) Interactive — for first-time forker / non-Bin user:
#
#     source scripts/dev/runbook-00-bootstrap.sh
#     # prompts for profile + SSO + region as needed
#
# (B) Fully scripted — for CI / scripts / Bin's preset wrapper:
#
#     export AWS_PROFILE=<your-sso-profile-name>
#     export AWS_ACCOUNT_ID=<12-digit AWS account>   # optional: auto-derived
#     export AWS_REGION=eu-central-1
#     export FINOPS_ALERT_EMAIL=alerts@example.com   # optional
#     source scripts/dev/runbook-00-bootstrap.sh
#
# (C) Mix — pre-set some, prompt for the rest:
#
#     export AWS_PROFILE=my-profile
#     source scripts/dev/runbook-00-bootstrap.sh
#     # prompts only for SSO confirmation + region
#
# MUST be sourced (not executed) so env vars persist in your shell.
# ============================================================================

set -u  # NOT set -e — sourced; failure shouldn't kill the shell

# Detect sourced vs executed (cross-shell: bash + zsh)
# bash: $BASH_SOURCE[0] != $0 when sourced
# zsh:  $ZSH_EVAL_CONTEXT contains 'file' when sourced
if [[ -n "${BASH_VERSION:-}" ]]; then
    if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
        echo "ERROR: this script must be sourced, not executed." >&2
        echo "  Run:   source ${BASH_SOURCE[0]}" >&2
        echo "  NOT:   bash   ${BASH_SOURCE[0]}" >&2
        exit 1
    fi
    _SCRIPT_PATH="${BASH_SOURCE[0]}"
elif [[ -n "${ZSH_VERSION:-}" ]]; then
    case "${ZSH_EVAL_CONTEXT:-}" in
        *:file*) : ;; # sourced — proceed
        *)
            echo "ERROR: this script must be sourced, not executed." >&2
            echo "  Run:   source $0" >&2
            exit 1
            ;;
    esac
    # In zsh, $0 inside a sourced file IS the file path
    _SCRIPT_PATH="${0}"
else
    echo "ERROR: unsupported shell. Requires bash 4+ or zsh 5+." >&2
    return 1 2>/dev/null || exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "$_SCRIPT_PATH")" && pwd)"
PROJ_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# ============================================================================
# Bootstrap runbook-config.yaml from .example if missing
# ============================================================================
# Pattern parallels terraform.tfvars.example → terraform.tfvars:
# the .example file is canonical (committed); the working file is
# gitignored so forker / operator can customise without polluting
# the repo. Idempotent — if working file exists, leaves it alone.
RUNBOOK_CONFIG_EXAMPLE="$SCRIPT_DIR/runbook-config.yaml.example"
RUNBOOK_CONFIG="$SCRIPT_DIR/runbook-config.yaml"
if [[ ! -f "$RUNBOOK_CONFIG" ]]; then
    if [[ ! -f "$RUNBOOK_CONFIG_EXAMPLE" ]]; then
        echo "  ❌ Neither $RUNBOOK_CONFIG nor $RUNBOOK_CONFIG_EXAMPLE exists" >&2
        return 1 2>/dev/null || exit 1
    fi
    cp "$RUNBOOK_CONFIG_EXAMPLE" "$RUNBOOK_CONFIG"
    echo "  ℹ️  copied runbook-config.yaml.example → runbook-config.yaml (working copy)"
fi

# Optional values with defaults
FINOPS_ALERT_EMAIL="${FINOPS_ALERT_EMAIL:-}"
TFVARS_ENVIRONMENT="${TFVARS_ENVIRONMENT:-staging}"
TFVARS_BUDGET_USD="${TFVARS_BUDGET_USD:-500}"
TFVARS_BUDGET_STATEFUL_USD="${TFVARS_BUDGET_STATEFUL_USD:-350}"

# ============================================================================
echo "=== Step 1/5: Pick AWS profile ==="
# ============================================================================
if [[ -z "${AWS_PROFILE:-}" ]]; then
    # Enumerate available profiles
    mapfile -t _profiles < <(aws configure list-profiles 2>/dev/null | grep -v '^$')
    if [[ ${#_profiles[@]} -eq 0 ]]; then
        echo "  ❌ No AWS profiles found. Configure one first:" >&2
        echo "      aws configure sso     # for SSO" >&2
        echo "      aws configure         # for IAM user keys" >&2
        return 1
    fi
    echo "  Available profiles:"
    for i in "${!_profiles[@]}"; do
        printf "    %d. %s\n" $((i+1)) "${_profiles[$i]}"
    done
    read -r -p "  Pick by number (1-${#_profiles[@]}) or type a profile name: " _choice
    if [[ "$_choice" =~ ^[0-9]+$ ]] && (( _choice >= 1 && _choice <= ${#_profiles[@]} )); then
        AWS_PROFILE="${_profiles[$((_choice-1))]}"
    elif [[ -n "$_choice" ]]; then
        AWS_PROFILE="$_choice"
    else
        echo "  ❌ No profile selected — abort" >&2
        return 1
    fi
fi
echo "  ✅ AWS_PROFILE=$AWS_PROFILE"

# ============================================================================
echo
echo "=== Step 2/5: AWS SSO session ==="
# ============================================================================
# Check if already authenticated (works for both SSO sessions + long-term creds)
if aws sts get-caller-identity --profile "$AWS_PROFILE" >/dev/null 2>&1; then
    echo "  ✅ Already authenticated for $AWS_PROFILE — no login needed"
else
    echo "  ℹ️  No active credentials detected for $AWS_PROFILE"
    read -r -p "  Run 'aws sso login --profile $AWS_PROFILE' now? (y/N): " _sso
    if [[ "$_sso" =~ ^[Yy] ]]; then
        if ! aws sso login --profile "$AWS_PROFILE"; then
            echo "  ❌ SSO login failed — abort" >&2
            return 1
        fi
    else
        echo "  ⚠️  Skipping SSO login. If next step fails, re-run and answer 'y' to SSO." >&2
    fi
fi

# Verify identity works now
_caller_json=$(aws sts get-caller-identity --profile "$AWS_PROFILE" --output json 2>/dev/null)
if [[ -z "$_caller_json" ]]; then
    echo "  ❌ Cannot get caller identity. SSO session may be expired." >&2
    echo "     Run: aws sso login --profile $AWS_PROFILE" >&2
    return 1
fi
_actual_account=$(echo "$_caller_json" | grep -o '"Account"[^"]*"[^"]*"' | grep -oE '[0-9]{12}')
_actual_arn=$(echo "$_caller_json"     | grep -o '"Arn"[^"]*"[^"]*"'     | sed 's/.*"\(arn[^"]*\)".*/\1/')

# Cross-check with $AWS_ACCOUNT_ID if pre-set; auto-derive if not
if [[ -n "${AWS_ACCOUNT_ID:-}" ]]; then
    if [[ "$_actual_account" != "$AWS_ACCOUNT_ID" ]]; then
        echo "  ❌ Account mismatch — expected $AWS_ACCOUNT_ID, got $_actual_account" >&2
        echo "     Profile $AWS_PROFILE points at a different account." >&2
        return 1
    fi
else
    AWS_ACCOUNT_ID="$_actual_account"
    echo "  ℹ️  AWS_ACCOUNT_ID auto-derived from caller identity"
fi
echo "  ✅ Identity verified — account $AWS_ACCOUNT_ID"
echo "     ARN: $_actual_arn"

# ============================================================================
echo
echo "=== Step 3/5: AWS region ==="
# ============================================================================
if [[ -z "${AWS_REGION:-}" ]]; then
    _region_default=$(aws configure get region --profile "$AWS_PROFILE" 2>/dev/null || echo "eu-central-1")
    read -r -p "  AWS region [$_region_default]: " _region_input
    AWS_REGION="${_region_input:-$_region_default}"
fi
echo "  ✅ AWS_REGION=$AWS_REGION"

# Export all three for downstream consumers
export AWS_PROFILE AWS_ACCOUNT_ID AWS_REGION

# ============================================================================
echo
echo "=== Step 4/5: Ensure terraform.tfvars ready ==="
# ============================================================================
TFVARS="$PROJ_ROOT/infrastructure/terraform/terraform.tfvars"
TFEXAMPLE="$PROJ_ROOT/infrastructure/terraform/terraform.tfvars.example"

_sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then sed -i '' "$@"; else sed -i "$@"; fi
}

if [[ -f "$TFVARS" ]]; then
    echo "  ✅ $TFVARS already exists"
    grep -E "^(environment|monthly_budget_usd|monthly_budget_stateful_usd|grafana_cloud_token) *=" "$TFVARS" \
      2>/dev/null | sed 's/^/       /'
elif [[ ! -f "$TFEXAMPLE" ]]; then
    echo "  ⚠️  terraform.tfvars.example missing; skipping tfvars generation"
else
    echo "  ℹ️  generating $TFVARS from .example with overrides"
    cp "$TFEXAMPLE" "$TFVARS"
    _sed_inplace "s|^environment = \"prod\"|environment = \"${TFVARS_ENVIRONMENT}\"|" "$TFVARS"
    _sed_inplace "s|^monthly_budget_usd          = 10000|monthly_budget_usd          = ${TFVARS_BUDGET_USD}|" "$TFVARS"
    _sed_inplace "s|^monthly_budget_stateful_usd = 7000|monthly_budget_stateful_usd = ${TFVARS_BUDGET_STATEFUL_USD}|" "$TFVARS"
    _sed_inplace "s|^grafana_cloud_token = \"PASTE_OR_USE_TF_VAR_grafana_cloud_token_ENV\"|grafana_cloud_token = \"\"  # TODO: fill after runbook 04 Grafana Cloud signup|" "$TFVARS"
    if [[ -n "$FINOPS_ALERT_EMAIL" ]]; then
        _sed_inplace "s|^finops_alert_emails = \[$|finops_alert_emails = [\\
  \"${FINOPS_ALERT_EMAIL}\",|" "$TFVARS"
    fi
    echo "  ✅ generated $TFVARS"
fi

# ============================================================================
echo
echo "=== Step 5/5: Toolchain readiness ==="
# ============================================================================
_check() {
    if eval "$1" >/dev/null 2>&1; then
        echo "  ✅ $2"
    else
        echo "  ❌ $2 — fix before proceeding"
    fi
}
_check "command -v docker"     "docker installed"
_check "docker info"           "docker daemon running"
_check "command -v terraform"  "terraform installed"
_check "command -v kubectl"    "kubectl installed"
_check "command -v helm"       "helm installed"
_check "command -v gh"         "gh installed"
_check "command -v yq"         "yq installed (for runbook config parsing)"
_check "command -v pandoc"     "pandoc installed (for PDF render)"
_check "command -v weasyprint" "weasyprint installed (for PDF render)"
_check "gh auth status"        "gh authenticated"

echo
echo "=== Bootstrap complete ==="
echo "  Next: bash $PROJ_ROOT/scripts/dev/runbook-01-bootstrap.sh"
echo "  Or:   cat $PROJ_ROOT/docs/operations/runbooks/01-docker-build-push.md"

# Cleanup helper internals (don't leak into user shell)
unset -f _check _sed_inplace 2>/dev/null
unset _profiles _choice _sso _caller_json _actual_account _actual_arn _region_default _region_input 2>/dev/null
