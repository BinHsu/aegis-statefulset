# Runbook 01 — Docker build, push, and digest update

**Goal:** Build the mock stateful app image, push to a registry, capture
the digest, and update three `values.yaml` image blocks (stateful / api /
envoy) per ADR-09 SHA-pin discipline.

**Time:** ~15 min  
**Cost:** ~$0 (Docker Hub / ECR free tier; ~10 MB image)  
**Trust boundary:** Bin executes; Claude does not have registry credentials.

---

## 0. Prerequisites

```bash
docker --version    # ≥ 24
aws --version       # ≥ 2.13 (only if pushing to ECR)
```

Pick a registry. Three reasonable choices:

| Registry | When to use | Login |
|---|---|---|
| **AWS ECR** | If running demo on AWS (Item 02) — same account, no cross-cloud pull | `aws ecr get-login-password ...` |
| **Docker Hub** | Public throwaway POC | `docker login` |
| **GHCR** | If repo is on GitHub and visible | `echo $GH_PAT \| docker login ghcr.io -u USERNAME --password-stdin` |

**Recommended for this submission:** ECR (matches the Item 02 EKS demo,
no IRSA dance for cross-registry pulls). If you skip Item 02 and only
do paper review, use Docker Hub.

---

## 1. Resolve the distroless base digest

The Dockerfile has `TODO_VERIFY_FROM_DOCKER_HUB` placeholder for the
distroless static base. Replace with the live digest:

```bash
docker pull gcr.io/distroless/static:nonroot
DISTROLESS_DIGEST=$(docker inspect gcr.io/distroless/static:nonroot \
  --format='{{index .RepoDigests 0}}' | cut -d@ -f2)
echo "$DISTROLESS_DIGEST"
# expected: sha256:abcdef... (64 hex chars after sha256:)
```

Edit `app/Dockerfile`:

```diff
-FROM gcr.io/distroless/static@sha256:TODO_VERIFY_FROM_DOCKER_HUB
+FROM gcr.io/distroless/static@sha256:abcdef...   # paste $DISTROLESS_DIGEST
```

**Verification:** Dockerfile no longer contains the literal string
`TODO_VERIFY_FROM_DOCKER_HUB`:

```bash
grep -c TODO_VERIFY_FROM_DOCKER_HUB app/Dockerfile   # expect: 0
```

---

## 2. Build the mock image

```bash
cd app/
docker build -t aegis-stateful-mock:v0.1.0 -f Dockerfile .
cd ..
```

**What to observe:**
- Stage 1 (golang:1.22-alpine) compiles `main.go` to `/app` static binary
- Stage 2 (distroless) is ~2 MB, no shell, runs as UID 65532
- Final image SHOULD be < 5 MB. If > 20 MB, the build went wrong (CGO leaked).

**Verification:**

```bash
docker inspect aegis-stateful-mock:v0.1.0 --format='{{.Size}}' \
  | awk '{printf "%.1f MB\n", $1/1024/1024}'
# expect: 2-5 MB
```

---

## 3. Push to registry, capture digest

### 3a. ECR path

```bash
AWS_REGION=eu-central-1
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# One-time: create the ECR repo if absent
aws ecr describe-repositories --repository-names aegis-stateful-mock \
  --region "$AWS_REGION" 2>/dev/null \
  || aws ecr create-repository --repository-name aegis-stateful-mock \
       --image-scanning-configuration scanOnPush=true \
       --image-tag-mutability IMMUTABLE \
       --region "$AWS_REGION"

# Authenticate Docker daemon to ECR — via ephemeral DOCKER_CONFIG
# (bypasses macOS Keychain / Linux keyring / Windows Credential Manager so
# the auth state is OS-agnostic, CI-friendly, and won't conflict with stale
# credential-helper entries). Cleanup happens automatically at shell exit.
export DOCKER_CONFIG="$(mktemp -d -t aegis-docker-XXXXXX)"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker --config "$DOCKER_CONFIG" login --username AWS --password-stdin "$ECR_REGISTRY"

# Tag + push (subsequent docker commands need --config "$DOCKER_CONFIG"
# for ECR-authenticated operations; building / tagging work without it)
docker tag aegis-stateful-mock:v0.1.0 \
  "${ECR_REGISTRY}/aegis-stateful-mock:v0.1.0"
docker --config "$DOCKER_CONFIG" push \
  "${ECR_REGISTRY}/aegis-stateful-mock:v0.1.0"

# Capture digest
STATEFUL_DIGEST=$(docker inspect \
  "${ECR_REGISTRY}/aegis-stateful-mock:v0.1.0" \
  --format='{{index .RepoDigests 0}}' | cut -d@ -f2)
echo "stateful: $STATEFUL_DIGEST"
```

**Why temp `DOCKER_CONFIG` rather than the default `~/.docker/`:** the
default config delegates to the OS credential helper — `osxkeychain` on
macOS, `secretservice` on Linux, `wincred` on Windows. Each has its own
quirks (Keychain can refuse to overwrite a stale entry with
`The specified item already exists in the keychain. (-25299)`; Linux
keyring may not be unlocked in headless / CI sessions). Using `mktemp`
+ `--config` makes the auth state ephemeral and free from cross-process
state, which is the right default for runbook scripts.

### 3b. Docker Hub path

```bash
DOCKER_USER=<your-username>
docker login   # interactive
docker tag aegis-stateful-mock:v0.1.0 \
  "${DOCKER_USER}/aegis-stateful-mock:v0.1.0"
docker push "${DOCKER_USER}/aegis-stateful-mock:v0.1.0"

STATEFUL_DIGEST=$(docker inspect \
  "${DOCKER_USER}/aegis-stateful-mock:v0.1.0" \
  --format='{{index .RepoDigests 0}}' | cut -d@ -f2)
```

---

## 4. Resolve nginx + envoy digests (api + envoy tiers)

The two stateless tiers also have `TODO_VERIFY_FROM_DOCKER_HUB` placeholders.

```bash
docker pull nginx:1.27.0
NGINX_DIGEST=$(docker inspect nginx:1.27.0 \
  --format='{{index .RepoDigests 0}}' | cut -d@ -f2)
echo "nginx: $NGINX_DIGEST"

docker pull envoyproxy/envoy:v1.30.0
ENVOY_DIGEST=$(docker inspect envoyproxy/envoy:v1.30.0 \
  --format='{{index .RepoDigests 0}}' | cut -d@ -f2)
echo "envoy: $ENVOY_DIGEST"
```

---

## 5. Update `values.yaml` — three image blocks

Edit `helm/aegis-statefulset/values.yaml`. The schema has three image
blocks (lines ~38, ~66, ~94 — search `image:` to locate).

```yaml
# stateful tier (line ~38)
stateful:
  image:
    repository: <ECR_REGISTRY>/aegis-stateful-mock     # if ECR
    # repository: <DOCKER_USER>/aegis-stateful-mock    # if Docker Hub
    tag: "v0.1.0"
    digest: "sha256:..."   # paste $STATEFUL_DIGEST

# api tier (line ~66)
api:
  image:
    repository: nginx
    tag: "1.27.0"
    digest: "sha256:..."   # paste $NGINX_DIGEST

# envoy tier (line ~94)
envoy:
  image:
    repository: envoyproxy/envoy
    tag: "v1.30.0"
    digest: "sha256:..."   # paste $ENVOY_DIGEST
```

**Verification (no placeholders remain):**

```bash
grep -n TODO_FILL_REAL_DIGEST helm/aegis-statefulset/values.yaml   # expect 0
grep -n TODO_VERIFY_FROM_DOCKER_HUB helm/aegis-statefulset/values.yaml   # expect 0
grep -n "digest:" helm/aegis-statefulset/values.yaml
# expect 3 lines, each with "sha256:" + 64 hex chars
```

---

## 6. Re-render template to confirm digest format

```bash
helm template helm/aegis-statefulset/ \
  | grep -E "image: " | head -10
# expect lines like:
#   image: <repo>@sha256:abc...
```

The chart MUST render `repo@sha256:digest` form (not `repo:tag`) per
ADR-09. If you see `repo:tag` only, the template helper isn't picking
up `digest`.

---

## 7. Rollback / re-do

If you push a bad image:

- **ECR with IMMUTABLE tag mutability:** you cannot overwrite
  `aegis-stateful-mock:v0.1.0`. Bump to v0.1.1 and re-do steps 2–5.
- **Docker Hub:** technically can overwrite but DON'T — bump tag.

---

## 8. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `denied: requested access to the resource is denied` | Wrong registry login | Re-auth: ECR `get-login-password`, Hub `docker login` |
| Image is 200+ MB | CGO leaked, dynamic linking | Verify `CGO_ENABLED=0` in Dockerfile build stage |
| `manifest unknown` after push | Pushed to wrong registry / typo | Re-tag, re-push, verify with `docker manifest inspect` |
| Distroless digest changes daily | Google rebuilds the base | Acceptable — pin once, refresh via Renovate weekly per ADR-09 |
| Pod CrashLoopBackOff with "exec format error" | Built on Mac M1, deployed to amd64 nodes | Add `--platform linux/amd64` to `docker build` |

---

## 9. Tie-back to architecture

This runbook satisfies:
- **ADR-09** SHA pinning supply chain — every external image is `repo@digest`
- **ADR-09** SLSA L3 SBOM provenance — image signed via Cosign in CI (separate, not this runbook)
- **ADR-07** Pod Security Standards — runtime image is non-root (UID 65532), distroless static (no shell, no package manager)

---

## 10. Done criteria

- [ ] `app/Dockerfile` has no `TODO_VERIFY_FROM_DOCKER_HUB`
- [ ] `helm/aegis-statefulset/values.yaml` has three real `sha256:` digests
- [ ] `helm template` output renders all three images as `repo@sha256:...`
- [ ] Image pushed and visible in registry
- [ ] Repo committed (Wave 4 + this digest update) but NOT yet pushed to GitHub (next runbook may need adjustments)
