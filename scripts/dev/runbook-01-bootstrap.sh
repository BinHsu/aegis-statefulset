#!/usr/bin/env bash
# scripts/dev/runbook-01-bootstrap.sh — Runbook 01 ECR path automation
#
# Automates the manual steps in docs/operations/runbooks/01-docker-build-push.md
# for the ECR registry path:
#   1. Resolve distroless base digest, patch app/Dockerfile
#   2. docker build --platform linux/amd64 the mock stateful app
#   3. ECR create-if-not-exists, login, tag, push the mock image
#   4. Pull nginx / envoy / blackbox-exporter, capture digests
#   5. Edit helm/aegis-statefulset/values.yaml + templates/blackbox-exporter.yaml
#   6. helm template verify — all images render repo@sha256: form
#
# Idempotent — safe to re-run. Reads env vars; nothing personal hardcoded.
#
# ============================================================================
# Usage (forker / CI / Bin alike)
# ============================================================================
#
#   export AWS_PROFILE=<your-sso-profile>       # e.g. "platform-admin"
#   export AWS_ACCOUNT_ID=<12-digit account>
#   export AWS_REGION=eu-central-1
#   aws sso login --profile "$AWS_PROFILE"      # if SSO-based
#   bash scripts/dev/runbook-01-bootstrap.sh
#
# Prerequisites:
#   - docker daemon running
#   - terraform / helm / kubectl installed (for helm template verify)
#   - AWS CLI v2 with the profile configured + SSO session active
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
: "${AWS_ACCOUNT_ID:?ERROR: AWS_ACCOUNT_ID not set; see usage docstring at top of file}"
: "${AWS_REGION:?ERROR: AWS_REGION not set}"
: "${AWS_PROFILE:?ERROR: AWS_PROFILE not set}"

if ! [[ "$AWS_ACCOUNT_ID" =~ ^[0-9]{12}$ ]]; then
    echo "ERROR: AWS_ACCOUNT_ID must be exactly 12 digits, got: $AWS_ACCOUNT_ID" >&2
    exit 1
fi

# ============================================================================
# Shared config (sourced from runbook-config.yaml — single source of truth
# for ECR repo name, image tags, distroless base, tag-pair values)
# ============================================================================
CONFIG_FILE="${PROJ_ROOT}/scripts/dev/runbook-config.yaml"
if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "ERROR: $CONFIG_FILE not found — required for shared resource naming" >&2
    exit 1
fi
ECR_REPO=$(yq '.ecr.repository' "$CONFIG_FILE")
STATEFUL_TAG=$(yq '.images.stateful_mock.tag' "$CONFIG_FILE")
NGINX_TAG=$(yq '.images.nginx.tag' "$CONFIG_FILE")
ENVOY_TAG=$(yq '.images.envoy.tag' "$CONFIG_FILE")
BLACKBOX_TAG=$(yq '.images.blackbox_exporter.tag' "$CONFIG_FILE")
DISTROLESS_IMAGE=$(yq '.images.distroless_base.repository' "$CONFIG_FILE")
DISTROLESS_VARIANT=$(yq '.images.distroless_base.variant' "$CONFIG_FILE")
PROJECT_TAG_KEY=$(yq '.tags.project.key' "$CONFIG_FILE")
PROJECT_TAG_VAL=$(yq '.tags.project.value' "$CONFIG_FILE")
MANAGEDBY_TAG_KEY=$(yq '.tags.managed_by.key' "$CONFIG_FILE")
MANAGEDBY_TAG_VAL=$(yq '.tags.managed_by.value' "$CONFIG_FILE")

# ============================================================================
# Derived constants
# ============================================================================
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

DOCKERFILE="$PROJ_ROOT/app/Dockerfile"
VALUES="$PROJ_ROOT/helm/aegis-statefulset/values.yaml"
BLACKBOX_TEMPLATE="$PROJ_ROOT/helm/aegis-statefulset/templates/blackbox-exporter.yaml"

# Cross-platform sed -i (BSD vs GNU)
sed_inplace() {
    if [[ "$(uname)" == "Darwin" ]]; then
        sed -i '' "$@"
    else
        sed -i "$@"
    fi
}

# ============================================================================
echo "=== Step 1/7: Resolve distroless base digest ==="
# ============================================================================
docker pull "${DISTROLESS_IMAGE}:${DISTROLESS_VARIANT}"
DISTROLESS_DIGEST=$(docker inspect "${DISTROLESS_IMAGE}:${DISTROLESS_VARIANT}" \
  --format='{{index .RepoDigests 0}}' | cut -d@ -f2)
echo "  distroless: $DISTROLESS_DIGEST"

# ============================================================================
echo
echo "=== Step 2/7: Patch app/Dockerfile ==="
# ============================================================================
if grep -q "FROM ${DISTROLESS_IMAGE}@sha256:TODO_VERIFY_FROM_DOCKER_HUB" "$DOCKERFILE"; then
    sed_inplace "s|${DISTROLESS_IMAGE}@sha256:TODO_VERIFY_FROM_DOCKER_HUB|${DISTROLESS_IMAGE}@${DISTROLESS_DIGEST}|" "$DOCKERFILE"
    echo "  ✅ patched Dockerfile distroless digest"
else
    echo "  ℹ️  Dockerfile FROM already has a real digest — skipping"
fi
grep "^FROM ${DISTROLESS_IMAGE}" "$DOCKERFILE"

# ============================================================================
echo
echo "=== Step 3/7: docker build --platform linux/amd64 ==="
# ============================================================================
docker build --platform linux/amd64 \
    -t "${ECR_REPO}:${STATEFUL_TAG}" \
    -f "$DOCKERFILE" \
    "$PROJ_ROOT/app"

IMG_SIZE_MB=$(docker inspect "${ECR_REPO}:${STATEFUL_TAG}" \
    --format='{{.Size}}' | awk '{printf "%.1f", $1/1024/1024}')
echo "  ✅ build OK, size: ${IMG_SIZE_MB} MB"
if (( $(echo "$IMG_SIZE_MB > 20" | bc -l 2>/dev/null || echo 0) )); then
    echo "  ⚠️  Image >20 MB — possible CGO leak; check Dockerfile build stage"
fi

# ============================================================================
echo
echo "=== Step 4/7: ECR repo + login + push ==="
# ============================================================================
if ! aws ecr describe-repositories --repository-names "${ECR_REPO}" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
    aws ecr create-repository \
        --repository-name "${ECR_REPO}" \
        --image-scanning-configuration scanOnPush=true \
        --image-tag-mutability IMMUTABLE \
        --tags "Key=${PROJECT_TAG_KEY},Value=${PROJECT_TAG_VAL}" "Key=${MANAGEDBY_TAG_KEY},Value=${MANAGEDBY_TAG_VAL}" \
        --region "$AWS_REGION" >/dev/null
    echo "  ✅ created ECR repo ${ECR_REPO} (tagged for teardown discovery)"
else
    # Idempotent: tag existing repo too (in case it was created before this fix)
    aws ecr tag-resource \
        --resource-arn "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${ECR_REPO}" \
        --tags "Key=${PROJECT_TAG_KEY},Value=${PROJECT_TAG_VAL}" "Key=${MANAGEDBY_TAG_KEY},Value=${MANAGEDBY_TAG_VAL}" \
        --region "$AWS_REGION" >/dev/null 2>&1 || true
    echo "  ℹ️  ECR repo ${ECR_REPO} already exists (tags ensured)"
fi

# Docker login — two-layer defense against macOS Keychain conflicts:
# (a) Clear stale Keychain entries for any registry in ~/.docker/config.json
#     `auths` (OrbStack / Docker Desktop inherits global credsStore even with
#     --config $tmpdir; pre-clearing avoids "item already exists" errors).
#     docker-credential-osxkeychain uses INTERNET passwords (not generic) —
#     `security delete-internet-password` is the right command.
# (b) Use ephemeral DOCKER_CONFIG with pre-populated {"auths": {}}; forces
#     plaintext storage so credentials never touch system keystore.
# On non-Darwin (Linux / CI), step (a) is no-op; step (b) provides the same
# ephemeral isolation benefit.
if [[ "$(uname)" == "Darwin" ]]; then
    CLEAR_TARGETS=()
    if [[ -f ~/.docker/config.json ]]; then
        if command -v jq >/dev/null 2>&1; then
            while IFS= read -r host; do
                [[ -n "$host" ]] && CLEAR_TARGETS+=("$host")
            done < <(jq -r '.auths // {} | keys[]' ~/.docker/config.json 2>/dev/null \
                     | grep -E '\.dkr\.ecr\..*\.amazonaws\.com$')
        else
            while IFS= read -r host; do
                [[ -n "$host" ]] && CLEAR_TARGETS+=("$host")
            done < <(grep -oE '"[0-9]+\.dkr\.ecr\.[^"]+\.amazonaws\.com"' ~/.docker/config.json \
                     | tr -d '"' | sort -u)
        fi
    fi
    CLEAR_TARGETS+=("$ECR_REGISTRY")
    CLEARED=0
    for HOST in "${CLEAR_TARGETS[@]}"; do
        while security delete-internet-password -s "$HOST" >/dev/null 2>&1; do
            CLEARED=$((CLEARED + 1))
        done
    done
    if [[ $CLEARED -gt 0 ]]; then
        echo "  ℹ️  cleared $CLEARED stale Keychain entry/entries across ${#CLEAR_TARGETS[@]} ECR host(s)"
    fi
fi

export DOCKER_CONFIG
DOCKER_CONFIG="$(mktemp -d -t aegis-docker-XXXXXX)"
echo '{"auths": {}}' > "$DOCKER_CONFIG/config.json"
# shellcheck disable=SC2064  # $DOCKER_CONFIG path is set right above
# and immutable after; expanding-now is intentional + correct here.
trap "rm -rf '$DOCKER_CONFIG' 2>/dev/null || true" EXIT
echo "  ℹ️  using ephemeral DOCKER_CONFIG (plaintext, no Keychain)"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker --config "$DOCKER_CONFIG" login --username AWS --password-stdin "$ECR_REGISTRY"

docker tag "${ECR_REPO}:${STATEFUL_TAG}" \
    "${ECR_REGISTRY}/${ECR_REPO}:${STATEFUL_TAG}"

# Use AWS ECR API to check "already pushed" — `docker manifest inspect` is
# unreliable here because BuildKit creates a new attestation manifest on
# every build (even with all layers cached), so the locally-tagged image
# has a different manifest list digest than what's in ECR. On some Docker
# CLI builds (OrbStack) this causes manifest inspect to mis-report the
# tag's existence, leading to a redundant push that hits IMMUTABLE tag
# protection. AWS ECR API is the authoritative check.
if aws ecr describe-images \
        --repository-name "${ECR_REPO}" \
        --image-ids "imageTag=${STATEFUL_TAG}" \
        --region "$AWS_REGION" >/dev/null 2>&1; then
    echo "  ℹ️  ${STATEFUL_TAG} already in ECR — skipping push (tag is IMMUTABLE)"
else
    docker --config "$DOCKER_CONFIG" push "${ECR_REGISTRY}/${ECR_REPO}:${STATEFUL_TAG}"
    echo "  ✅ pushed mock to ECR"
fi

# Fetch digest from ECR directly — source-of-truth. Local docker inspect can
# return a stale or newly-built (unpushed) manifest digest because BuildKit
# adds a new attestation manifest on every build even when content is cached,
# so the local RepoDigests entry can diverge from what's actually in ECR.
STATEFUL_DIGEST=$(aws ecr describe-images \
    --repository-name "${ECR_REPO}" \
    --image-ids "imageTag=${STATEFUL_TAG}" \
    --region "$AWS_REGION" \
    --query 'imageDetails[0].imageDigest' \
    --output text)
echo "  stateful: $STATEFUL_DIGEST"

# ============================================================================
echo
echo "=== Step 5/7: Resolve nginx / envoy / blackbox-exporter digests ==="
# ============================================================================
docker pull "nginx:${NGINX_TAG}"
NGINX_DIGEST=$(docker inspect "nginx:${NGINX_TAG}" \
    --format='{{index .RepoDigests 0}}' | cut -d@ -f2)
echo "  nginx:    $NGINX_DIGEST"

docker pull "envoyproxy/envoy:${ENVOY_TAG}"
ENVOY_DIGEST=$(docker inspect "envoyproxy/envoy:${ENVOY_TAG}" \
    --format='{{index .RepoDigests 0}}' | cut -d@ -f2)
echo "  envoy:    $ENVOY_DIGEST"

docker pull "prom/blackbox-exporter:${BLACKBOX_TAG}"
BLACKBOX_DIGEST=$(docker inspect "prom/blackbox-exporter:${BLACKBOX_TAG}" \
    --format='{{index .RepoDigests 0}}' | cut -d@ -f2)
echo "  blackbox: $BLACKBOX_DIGEST"

# ============================================================================
echo
echo "=== Step 6/7: Patch values.yaml + templates/blackbox-exporter.yaml ==="
# ============================================================================
# Idempotent structured edits via yq — overwrites regardless of prior
# state (works for fresh TODO_FILL_REAL_DIGEST placeholders OR previously-
# patched real values). Previous sed approach only matched the initial
# TODO state and was a no-op on subsequent runs after rename / re-pin.
yq -i ".stateful.image.repository = \"${ECR_REGISTRY}/${ECR_REPO}\"" "$VALUES"
yq -i ".stateful.image.tag = \"${STATEFUL_TAG}\"" "$VALUES"
yq -i ".stateful.image.digest = \"${STATEFUL_DIGEST}\"" "$VALUES"
yq -i ".api.image.tag = \"${NGINX_TAG}\"" "$VALUES"
yq -i ".api.image.digest = \"${NGINX_DIGEST}\"" "$VALUES"
yq -i ".envoy.image.tag = \"${ENVOY_TAG}\"" "$VALUES"
yq -i ".envoy.image.digest = \"${ENVOY_DIGEST}\"" "$VALUES"

# blackbox-exporter — image is hardcoded in the template file (chart
# inconsistency worth refactoring post-submission). Use a regex sed
# that matches either the TODO placeholder OR any existing sha256:hex64
# digest, so re-runs with a new digest update cleanly.
# Delimiter must NOT be `|` because the alternation inside the pattern
# also uses `|` — BSD sed (macOS) treats the first `|` as the end of
# the search pattern. Use `#` as delimiter instead.
sed_inplace -E "s#prom/blackbox-exporter:${BLACKBOX_TAG}@sha256:(TODO_VERIFY_FROM_DOCKER_HUB|[A-Fa-f0-9]{64})#prom/blackbox-exporter:${BLACKBOX_TAG}@${BLACKBOX_DIGEST}#" "$BLACKBOX_TEMPLATE"

echo "  ✅ patched values.yaml 3 image blocks + templates/blackbox-exporter.yaml"

# ============================================================================
echo
echo "=== Step 7/7: helm template verify ==="
# ============================================================================
if helm template "$PROJ_ROOT/helm/aegis-statefulset/" 2>/dev/null \
   | grep -E "^[[:space:]]+image: " > /tmp/aegis-helm-images.$$.txt; then
    cat /tmp/aegis-helm-images.$$.txt
    rm -f /tmp/aegis-helm-images.$$.txt
    echo "  ✅ helm template renders image blocks"
else
    echo "  ⚠️  helm template returned no image lines — investigate"
fi

# Final verification — no TODO placeholders left in active code (FROM lines
# in Dockerfile + values.yaml + blackbox-exporter template). Excludes
# comments which may legitimately mention placeholder names.
# Wrap each grep in (cmd || true) so zero-match (correct state!) doesn't
# trigger pipefail and abort the script before the summary prints.
SEARCH_ACTIVE=("$VALUES" "$BLACKBOX_TEMPLATE")
REMAINING_ACTIVE=$( ( grep -E "TODO_FILL_REAL_DIGEST|TODO_VERIFY_FROM_DOCKER_HUB" \
    "${SEARCH_ACTIVE[@]}" 2>/dev/null || true ) | wc -l | tr -d ' ')
REMAINING_DOCKERFILE=$( ( grep -E "^FROM.*TODO_(FILL_REAL_DIGEST|VERIFY_FROM_DOCKER_HUB)" \
    "$DOCKERFILE" 2>/dev/null || true ) | wc -l | tr -d ' ')
REMAINING=$((REMAINING_ACTIVE + REMAINING_DOCKERFILE))

echo
echo "=== Done — Runbook 01 complete ==="
echo "  Remaining TODO placeholders in active code: $REMAINING"
if [[ $REMAINING -gt 0 ]]; then
    echo "  ⚠️  Some placeholders still present:"
    grep -nE "TODO_FILL_REAL_DIGEST|TODO_VERIFY_FROM_DOCKER_HUB" \
        "${SEARCH_ACTIVE[@]}" 2>/dev/null || true
    grep -nE "^FROM.*TODO_" "$DOCKERFILE" 2>/dev/null || true
fi
echo
echo "  Digests captured (for reference):"
echo "    stateful: $STATEFUL_DIGEST"
echo "    nginx:    $NGINX_DIGEST"
echo "    envoy:    $ENVOY_DIGEST"
echo "    blackbox: $BLACKBOX_DIGEST"
echo
echo "Next: Runbook 03 (GHA OIDC)"
echo "  cat $PROJ_ROOT/docs/operations/runbooks/03-github-actions-oidc.md"
