#!/usr/bin/env bash
# scripts/build/build-stateful-mock.sh
#
# Build and push the aegis-stateful-mock image to ECR.
#
# Same surface as `app/Makefile` but composable from CI: the script logs
# in to ECR, builds, pushes, and prints the resulting image digest. Pin
# Helm `stateful.image.digest` on the printed value (ADR-09).
#
# Required environment:
#   ECR_REGISTRY  e.g. <account-id>.dkr.ecr.eu-central-1.amazonaws.com
#
# Optional environment:
#   IMAGE_TAG     defaults to v0.1
#
# Exit codes:
#   0  success (digest printed)
#   1  missing required env, build failure, push failure, or describe-images failure

set -euo pipefail

REGISTRY="${ECR_REGISTRY:?ECR_REGISTRY env var required (e.g. <account>.dkr.ecr.eu-central-1.amazonaws.com)}"
TAG="${IMAGE_TAG:-v0.1}"

log() {
  printf '[%s] [build-stateful-mock] %s\n' "$(date -Iseconds)" "$*"
}

log "Building aegis-stateful-mock:${TAG}"

# Resolve app dir relative to this script (location-independent).
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="${SCRIPT_DIR}/../../app"
cd "${APP_DIR}"

# 1. Build (local + registry-tagged).
docker build \
  -t "aegis-stateful-mock:${TAG}" \
  -t "${REGISTRY}/aegis-stateful-mock:${TAG}" \
  .

# 2. ECR login. Region is field 4 of the ECR hostname.
ECR_REGION="$(echo "${REGISTRY}" | cut -d. -f4)"
log "Logging in to ECR (region=${ECR_REGION})"
aws ecr get-login-password --region "${ECR_REGION}" \
  | docker login --username AWS --password-stdin "${REGISTRY}"

# 3. Push.
log "Pushing ${REGISTRY}/aegis-stateful-mock:${TAG}"
docker push "${REGISTRY}/aegis-stateful-mock:${TAG}"

# 4. Resolve digest from registry (the ground truth, not the local digest).
DIGEST="$(aws ecr describe-images \
  --repository-name aegis-stateful-mock \
  --image-ids "imageTag=${TAG}" \
  --query 'imageDetails[0].imageDigest' \
  --output text)"

echo
log "Build complete"
echo "  Image:  ${REGISTRY}/aegis-stateful-mock:${TAG}"
echo "  Digest: ${DIGEST}"
echo
echo "Update helm/aegis-statefulset/values.yaml stateful.image.digest with:"
echo "  ${DIGEST}"
