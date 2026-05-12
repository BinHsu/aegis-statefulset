# Branch protection — the meta-trust layer

> **What this is:** declarative description of the GitHub branch
> protection rules this repo expects to be enforced. Branch protection
> CANNOT be expressed as repo files (GitHub stores them in the repo's
> Settings → Branches API), so this doc IS the source of truth that
> the operator applies via UI or `gh api`.
>
> **Why this matters:** without branch protection, `.github/CODEOWNERS`
> is just a notification mechanism — it doesn't ACTUALLY block merges
> from non-owners. CODEOWNERS + branch protection are a pair; one
> without the other has a gap.

---

## 1. The meta-trust problem

Every in-repo security defense (`.gitleaks.toml` allowlist, pre-commit
hook, secret-scanning workflow, Kyverno admission policies) is itself
a file in the repo. An attacker who acquires PR merge access to `main`
can — as their first move — modify any of these files to neutralise
the defense before any subsequent malicious change is detected.

Three example attacks:

| Attack | Mitigation |
|---|---|
| Add `.*` to `.gitleaks.toml` allowlist | CODEOWNERS requires Bin's review on `.gitleaks.toml`; branch protection blocks merge without it |
| Delete `.github/workflows/secret-scanning.yml` | CODEOWNERS routes; branch protection enforces |
| Force-push `main` to a malicious commit, overwriting all defenses | Branch protection's "Restrict pushes to matching branches" + "Do not allow force pushes" |

CODEOWNERS without branch protection = security theatre. This doc is
the runbook for closing that gap.

---

## 2. Required branch protection rules

Apply to **`main`** branch. Source of truth is GitHub Settings →
Branches → Add rule for `main`.

### 2.1. Mandatory checks

- [x] **Require a pull request before merging** — no direct push to main
  - [x] **Require approvals** — minimum 1 (single-developer repo; raise to 2+ if team grows)
  - [x] **Dismiss stale pull request approvals when new commits are pushed** — prevents approval-then-modify attack
  - [x] **Require review from Code Owners** — enforces CODEOWNERS file
  - [x] **Require approval of the most recent reviewable push** — closes the "approve, push silently, merge" race

### 2.2. Status checks

- [x] **Require status checks to pass before merging**
  - [x] **Require branches to be up to date before merging** — prevents merge against stale base
  - Required status checks (must all pass):
    - `pr-validation / Helm lint`
    - `pr-validation / kubeconform`
    - `pr-validation / Terraform fmt + validate + tflint + tfsec`
    - `pr-validation / shellcheck`
    - `pr-validation / Trivy filesystem scan`
    - `secret-scanning / gitleaks scan`
    - `secret-scanning / trufflehog scan`

### 2.3. Force push + deletion protection

- [x] **Do not allow bypassing the above settings** — even admins must obey
- [x] **Restrict pushes that create matching branches** — no direct creation of conflicting branches
- [ ] **Allow force pushes** — DISABLED
- [ ] **Allow deletions** — DISABLED

### 2.4. Signed commits (optional uplift)

- [ ] **Require signed commits** — uplift for production; not enforced in POC
  - Trade-off: requires every contributor to set up GPG / SSH commit signing
  - Defends against: someone with a stolen developer credential committing on the developer's behalf
  - POC posture: rely on CODEOWNERS + branch protection; revisit for production

---

## 3. Apply via `gh` CLI (audit-traceable)

GitHub UI is the easiest path. For audit-traceable application (the
configuration ends up in a script that can be reviewed + replayed):

```bash
# Set token + repo
export GH_TOKEN=$(gh auth token)
export REPO="BinHsu/aegis-statefulset"

# Apply branch protection (this is the spec equivalent to § 2 above)
gh api \
  --method PUT \
  -H "Accept: application/vnd.github+json" \
  "/repos/${REPO}/branches/main/protection" \
  -f required_status_checks[strict]=true \
  -f required_status_checks[contexts][]="pr-validation / Helm lint" \
  -f required_status_checks[contexts][]="pr-validation / kubeconform" \
  -f required_status_checks[contexts][]="pr-validation / Terraform fmt + validate + tflint + tfsec" \
  -f required_status_checks[contexts][]="pr-validation / shellcheck" \
  -f required_status_checks[contexts][]="pr-validation / Trivy filesystem scan" \
  -f required_status_checks[contexts][]="secret-scanning / gitleaks scan" \
  -f required_status_checks[contexts][]="secret-scanning / trufflehog scan" \
  -f enforce_admins=true \
  -f required_pull_request_reviews[dismiss_stale_reviews]=true \
  -f required_pull_request_reviews[require_code_owner_reviews]=true \
  -f required_pull_request_reviews[required_approving_review_count]=1 \
  -f required_pull_request_reviews[require_last_push_approval]=true \
  -f restrictions=null \
  -f allow_force_pushes=false \
  -f allow_deletions=false
```

Verify the applied configuration:

```bash
gh api "/repos/${REPO}/branches/main/protection" | jq .
```

---

## 4. What this doc does NOT cover (deliberately deferred)

- **Required signed commits** — listed § 2.4 as upgrade trigger; POC accepts unsigned to minimise contributor friction.
- **Tag protection rules** — `v*` tags should arguably also be CODEOWNER-gated to prevent rogue tag pushes that look like release artefacts. Out of POC; documented as future work.
- **Environment protection rules** (production deploy) — when ArgoCD environment promotion is wired up, the GitHub Environment for `prod` should require manual approval. Out of POC; ADR-08 § GitOps promotion covers the principle.
- **Repository-level secret scanning** (GitHub native, separate from gitleaks workflow) — should be enabled in Settings → Code security → Secret scanning. Zero-config, free for public repos. Defends against the case where someone disables our `.github/workflows/secret-scanning.yml` (CODEOWNER review would catch this in PR, but if it slips through, GitHub's native scanner is the catch-all). See ADR-09.

---

## 5. Audit trail

The configuration applied via § 3 is visible in GitHub's audit log
(Organization → Audit log → Branch protection rule created/updated).
Operator should screenshot or `gh api` capture the audit log entry
after applying, attach to the same change-management ticket that
documents this protection setup.

---

## 6. Cross-references

- [`.github/CODEOWNERS`](../../.github/CODEOWNERS) — paths requiring CODEOWNER approval (this doc enforces those approvals via branch protection).
- [`docs/adr/ADR-09-supply-chain.md`](../adr/ADR-09-supply-chain.md) § "Defense in depth — external scanner layer" — explains how this in-repo defense layer is complemented by GitHub native secret scanning + Dependabot, which CANNOT be neutralised by repo PR.
- [`docs/adr/ADR-08-cicd-and-gitops.md`](../adr/ADR-08-cicd-and-gitops.md) § "Manual prod sync GitOps" — same posture as this doc: the configuration that protects production is itself explicit + auditable, not implicit.
