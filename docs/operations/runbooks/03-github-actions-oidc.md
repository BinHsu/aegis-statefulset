# Runbook 03 — GitHub Actions ↔ AWS OIDC trust

**Goal:** Wire up keyless authentication from GitHub Actions to AWS via
OIDC, so workflows can assume an IAM role for `terraform plan`,
`tfsec`, and Cosign signing — without storing long-lived AWS access keys
as repo secrets.

**Time:** ~30 min  
**Cost:** $0  
**Trust boundary:** Bin executes; Claude doesn't hold AWS or GitHub
admin credentials.

---

## 0. Prerequisites

```bash
aws sts get-caller-identity       # IAM admin in the target account
gh auth status                    # repo admin on the target repo
```

Three workflows already declare `id-token: write`:
- `.github/workflows/terraform-plan.yml` — for AWS OIDC role assumption
- `.github/workflows/helm-release.yml` — for Cosign keyless OIDC signing
- `.github/workflows/sbom-attestation.yml` — for Cosign keyless OIDC

This runbook makes all three actually work.

---

## 1. Create the GitHub OIDC provider in IAM

```bash
aws iam create-open-id-connect-provider \
  --url https://token.actions.githubusercontent.com \
  --client-id-list sts.amazonaws.com \
  --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
```

**Thumbprint note:** AWS now auto-resolves OIDC thumbprints from the
JWKS endpoint as of 2023, so the explicit thumbprint is increasingly
ceremonial — but the API still expects you to pass *something*. The
value above is the long-standing GitHub Actions thumbprint.

**Verify:**

```bash
aws iam list-open-id-connect-providers
# expect: arn:aws:iam::ACCOUNT:oidc-provider/token.actions.githubusercontent.com
```

---

## 2. Create the IAM role with trust policy

Decide who can assume — restrict to your repo. Replace `OWNER/REPO` with
the actual GitHub identifier (e.g., `binhsu/aegis-statefulset`).

`trust-policy.json`:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Federated": "arn:aws:iam::ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
      },
      "Action": "sts:AssumeRoleWithWebIdentity",
      "Condition": {
        "StringEquals": {
          "token.actions.githubusercontent.com:aud": "sts.amazonaws.com"
        },
        "StringLike": {
          "token.actions.githubusercontent.com:sub": "repo:OWNER/REPO:*"
        }
      }
    }
  ]
}
```

Substitute `ACCOUNT_ID` and `OWNER/REPO`, then:

```bash
aws iam create-role \
  --role-name aegis-gha-ci \
  --assume-role-policy-document file://trust-policy.json \
  --description "GitHub Actions CI for aegis-statefulset"
```

**Tighten the `sub` condition once stable.** `repo:OWNER/REPO:*` allows
ANY workflow in ANY branch — fine for early POC, too permissive for
prod. Common production tightenings:

| Policy | `sub` value |
|---|---|
| Only main branch | `repo:OWNER/REPO:ref:refs/heads/main` |
| Only protected envs | `repo:OWNER/REPO:environment:production` |
| Pull-requests only (no push to main triggers) | `repo:OWNER/REPO:pull_request` |

Per ADR-08 GitOps + ADR-08 four-workflow split, `terraform apply` is
**not** done from CI. CI only does `plan` and `lint`. Scope the role
permissions accordingly:

---

## 3. Attach minimum permissions (CI plan-only, NO apply)

`ci-plan-only.json` — read-mostly, can describe state but not mutate
infrastructure:

```json
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
      "Resource": "arn:aws:s3:::YOUR_TF_STATE_BUCKET/*"
    }
  ]
}
```

**Note on state locking:** State locking uses S3 native locking
(`use_lockfile = true`, terraform 1.10+ S3 conditional writes via
`If-None-Match`) — no DynamoDB table is required, so no
`dynamodb:*` grants on `terraform-state-lock` appear in this policy.

```bash
aws iam put-role-policy \
  --role-name aegis-gha-ci \
  --policy-name ci-plan-only \
  --policy-document file://ci-plan-only.json
```

**Capture the role ARN** — you'll need it for the workflow:

```bash
ROLE_ARN=$(aws iam get-role --role-name aegis-gha-ci \
  --query 'Role.Arn' --output text)
echo "$ROLE_ARN"
# arn:aws:iam::ACCOUNT_ID:role/aegis-gha-ci
```

---

## 4. Add the role ARN to GitHub repo as a variable (not a secret)

Role ARNs are not secret. Use a repo variable so it's visible in the
Actions tab.

```bash
gh variable set AWS_ROLE_ARN --body "$ROLE_ARN" --repo OWNER/REPO
gh variable set AWS_REGION   --body "eu-central-1" --repo OWNER/REPO
```

Confirm:

```bash
gh variable list --repo OWNER/REPO
```

---

## 5. Verify the workflow YAML uses the role

`.github/workflows/terraform-plan.yml` should already include this
shape:

```yaml
permissions:
  id-token: write   # for AWS OIDC role assumption
  contents: read
  pull-requests: write   # for plan-output comment

jobs:
  plan:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-assume: ${{ vars.AWS_ROLE_ARN }}
          aws-region:    ${{ vars.AWS_REGION }}
      - uses: hashicorp/setup-terraform@v3
      - run: terraform init && terraform plan -no-color
        working-directory: infrastructure/terraform
```

If the `aws-actions/configure-aws-credentials` block is missing or uses
`aws-access-key-id` / `aws-secret-access-key` (long-lived keys), edit
to match the OIDC pattern above.

---

## 6. Test by triggering a workflow

```bash
gh workflow run terraform-plan.yml --repo OWNER/REPO
gh run watch --repo OWNER/REPO
```

**Expected:** the workflow succeeds at the `Configure AWS credentials`
step (you'll see `assumed role aegis-gha-ci` in the log) and produces
a terraform plan output.

If it fails at `AssumeRoleWithWebIdentity is not authorized`:
- Check the trust policy `sub` condition matches the actual repo path
- Check the `aud` is `sts.amazonaws.com` (not the older `sigstore` value)
- Check the OIDC provider ARN matches the one in the trust policy

---

## 7. Cosign keyless signing — same OIDC path

For `helm-release.yml` and `sbom-attestation.yml`, Cosign uses the same
GitHub OIDC token to obtain a Sigstore certificate. No additional AWS
role needed; just the workflow `id-token: write` permission already in
the YAML.

The first signed push will create entries in the public Rekor
transparency log — ensure your workflow doesn't sign images you don't
want public. (For POC mock images this is fine.)

---

## 8. Failure modes

| Symptom | Cause | Fix |
|---|---|---|
| `Could not assume role` | `sub` condition too restrictive | Re-check repo path; for first run keep `repo:OWNER/REPO:*` |
| `OIDC provider not found` | Step 1 not run, or different account | `aws iam list-open-id-connect-providers` |
| `Region not specified` | `AWS_REGION` variable missing | `gh variable list` to confirm |
| Workflow tries to AssumeRole on every step | Missing `permissions: id-token: write` at job level | Add to job block, not just workflow block |
| Cosign fails with "not connected to internet" | GHA runner needs egress to fulcio.sigstore.dev | Confirm runner has network |

---

## 9. Tie-back to architecture

- ADR-08 GitOps via ArgoCD: CI does plan + lint; **apply is manual**, not via OIDC
- ADR-09 SHA pinning: Cosign signs the digest, OIDC trust is keyless
- ADR-09 SLSA L3 SBOM provenance: same OIDC trust chain used for attestation

---

## 10. Done criteria

- [ ] OIDC provider exists in IAM
- [ ] `aegis-gha-ci` role created with plan-only permissions
- [ ] GitHub repo variables `AWS_ROLE_ARN` + `AWS_REGION` set
- [ ] `terraform-plan.yml` workflow runs successfully on PR
- [ ] No long-lived AWS access keys in repo secrets
- [ ] Cosign keyless signing works on `helm-release.yml`
