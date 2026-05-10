# ADR-08: CI/CD & GitOps — fast PR validation, manual apply on stateful, ArgoCD pull-based delivery

## Status
Proposed (POC submission scope; subject to confirmation in Stage 3 conversation).

## Thesis
The pipeline architecture is a single asymmetric bet: cheap, fast, parallel validation on every PR — and deliberate, human-supervised application of any change that touches stateful infrastructure or production state. CI runs lint, schema validation, security scanning, anonymisation enforcement, and `terraform plan` against read-only credentials. CI does **not** apply. ArgoCD pulls signed artifacts from git and reconciles them per tier — auto-sync for stateless, manual sync for stateful — with PR-based promotion through dev → staging → prod soak windows. The shape exists because EBS volumes carry customer data, Helm errors roll back in seconds while Terraform errors don't, and the cost of "click into a PR and see green" matters more for a take-home submission than the cost of "click into the AWS console."

## Context (why these decisions belong together)
The CI/CD layer has to answer four questions in coherent order. **Where do workflows run?** **What concerns get split into separate workflows?** **What gates run before a change merges?** **And how does a merged commit reach the cluster?** Each question's answer constrains the next one's options.

The platform target frames the answers. The repository is hosted on GitHub; the reviewer lands on a PR and expects inline checks. A small SRE team operates the environment, which forbids platforms that are themselves a job to run (Jenkins, self-hosted CircleCI). The application's stateful tier — per-tenant pods pinned to specific EBS volumes — makes any auto-applied configuration drift potentially data-affecting, which forbids both push-based deployment from CI and self-healing GitOps for the stateful pool. Helm errors are recoverable; Terraform errors against EBS / EKS / IAM are minutes-to-hours-to-recover on a good day. The asymmetry between those two truths drives every gate decision in this ADR.

The pipeline is also a public-private boundary problem. The repo at `https://github.com/BinHsu/aegis-statefulset.git` is intentionally generic — the architecture stays portable across companies, and the public submission persists independent of any single interview outcome. A discipline-only rule against company-name leaks is a rule waiting to fail under merge-conflict pressure or copy-paste from private notes; a structural CI gate is the only mechanism that enforces the boundary at the speed humans actually work.

The shape this ADR converges on — GitHub Actions as the platform, four workflows for separate concerns, a four-tool Terraform stack with read-only plan and manual apply, kubeconform-validated Helm, an anonymisation grep that fails the build, and ArgoCD with split sync policy plus PR-based promotion through ApplicationSet — is the senior calibration of those constraints. None of the individual choices are novel; the value is the integration.

## Decisions

### 1. Platform — GitHub Actions, GitHub-hosted runners, SHA-pinned actions

**GitHub Actions** runs all CI/CD workflows. Workflows live in `.github/workflows/` and run on **GitHub-hosted runners** by default. All workflow YAML pins first-party actions to documented version tags (`actions/checkout@v4`, not `@main`); third-party actions are pinned to commit SHAs per supply-chain hygiene (CICD-SEC-3). Self-hosted runners are documented as the upgrade path for workflows that need to reach into a private VPC; they are not used in the POC.

The argument is friction-asymmetric. The reviewer opens a PR and sees Actions checks inline — no external account, no secondary URL, no "click here to see CI results." For a take-home submission, that goodwill is the entire point. The free tier (2,000 minutes/month for private repos, unlimited for public) covers POC scale comfortably. The marketplace covers every tool the rest of this ADR references — `helm/chart-testing-action`, `hashicorp/setup-terraform`, `aquasecurity/trivy-action`, `terraform-linters/setup-tflint`, `aquasecurity/tfsec-action` — without boilerplate install steps. YAML-native workflows match the shape of the K8s manifests and Helm values the rest of the project produces. No Groovy DSL detour.

We considered the alternatives. **CircleCI** is a strong product and adds an account boundary for a reviewer who already has GitHub access — small friction, unjustified for a submission where every click costs goodwill. **Jenkins** is heavyweight, requires hosting (an EC2 instance, a Helm chart, an ECS service — something we'd then monitor), and operating it is a job that the SRE headcount cannot absorb. **AWS CodePipeline + CodeBuild** is AWS-native and integrates cleanly with the workload account, but the OSS tooling ecosystem has weaker first-class support than GitHub Marketplace, and reviewers would need AWS console access to see CI results — defeats the click-into-the-PR demo path. **GitLab CI** is functionally equal-or-better; rejected solely because the repo is on GitHub.

The trade-off we accept is vendor lock-in to GitHub. Workflow YAML uses GitHub-specific syntax (`uses:`, `${{ secrets.* }}`); migration to a different platform later requires rewriting four files and ~300 lines. We accept that — workflows are themselves declarative IaC, and the architectural decisions in §2-§5 (four-workflow split, anonymisation gate, validation tooling, manual apply, ArgoCD) port to any CI platform. Only the YAML changes.

### 2. Pipeline shape — four workflows, one trigger and one concern each

The pipeline is split into **four workflows**, each with a single trigger and a single concern. The split exists because conflating them either drives `if:` conditional sprawl across one monolithic file (hard to read, easy to mis-write) or runs irrelevant steps on every trigger (wasted minutes, noisy failure surface). Four workflows pay a small duplication cost — each has its own `actions/checkout` and runner setup — for a large debugging benefit: failures are scoped, logs are short, and the re-run button is per-workflow.

**`pr-validation.yml`** triggers on `pull_request` and must complete in under 5 minutes for fast PR cycles. Steps: `helm lint`, `helm template | kubeconform -strict`, `terraform fmt -check`, `terraform init -backend=false`, `terraform validate`, `tflint`, `shellcheck` on `scripts/**/*.sh`, `markdownlint` on `docs/**/*.md`, the anonymisation grep (§4), and Trivy image vulnerability scan. Output is pass/fail to the GitHub PR checks UI. This workflow is the reviewer's "is this PR green?" signal.

**`helm-release.yml`** triggers on `push` of tags matching `helm-v*`. Steps: `helm package helm/app/`, push to OCI registry (ECR Public or `ghcr.io`), `cosign sign` the chart artifact (sigstore-based, no key management overhead), and optionally bump `Chart.yaml` and open a follow-up PR back to `main`. This is the artifact-publishing workflow; ArgoCD picks up the OCI chart from §6.

**`terraform-plan.yml`** triggers on `pull_request` with path filter `infrastructure/terraform/**`. Steps: `terraform init` with backend (read-only credentials per §3), `terraform plan -out=tfplan`, `tfsec` over the touched modules, format the plan summary as Markdown, post it as a PR comment via `actions/github-script`. **No auto-apply.** Apply is manual via runbook (§3).

**`dr-drill.yml`** triggers on `workflow_dispatch` and `schedule` (quarterly cron, `0 9 1 */3 *`). Steps: spin up an isolated test cluster in a sandbox AWS account (Terraform workspace `dr-drill`), simulate cluster destruction by `terraform destroy` of the EKS module while leaving EBS volumes intact (per ADR-04 — EBS is treasure), run `scripts/dr/rebuild-from-ebs-tags.sh`, verify EBS data preserved (data integrity hash on a known test tenant) and routing rebuilt (curl returns 200), tear down the test cluster. Output: drill report posted as a GitHub issue (`dr-drill-YYYY-Q*`) with pass/fail and timing data. This workflow exists because the scariest scripts in the repo are the ones we run least; quarterly automated rehearsal is exactly the SRE discipline behind ADR-04's recovery posture.

We considered three alternative shapes. **A single monolithic `ci.yml`** with `if:` conditionals — rejected on debugging ergonomics; the failure surface becomes one badge that could mean any of seven things. **Workflow per file type** (Helm workflow, Terraform workflow, Markdown workflow) — rejected because PR feedback should be one badge, not seven; tool-level split inverts the reviewer's mental model. **Three workflows (drop the DR drill)** — defensible, since the DR drill is closer to a tested operational procedure than to traditional CI, and rejected because the entire point of automating the drill is removing it from the "I'll get to it next quarter" backlog.

The trade-offs are small. Four `actions/checkout` calls instead of one (~3 seconds each, parallel anyway). The DR drill consumes ~$30-50 per quarterly run for a small EKS test cluster lasting ~30 minutes — tiny compared to the value of catching a broken recovery script before an incident. Cron drift across timezones is documented in the workflow header comment.

### 3. Terraform CI — fmt + validate + tflint + tfsec, plan-as-PR-comment, manual apply

The Terraform layer manages the irreversible part of the platform: VPCs, subnets, EKS clusters, EBS volumes, IAM roles, S3 backends, security groups. A bad Helm release rolls back in seconds; a bad Terraform apply can delete an EBS volume holding customer data or split-brain a security group across two AZs. The asymmetry forces a different posture.

In **`pr-validation.yml`** (fast feedback, every PR):

```yaml
- name: terraform fmt
  run: terraform fmt -check -recursive infrastructure/terraform/

- name: terraform init (no backend)
  working-directory: infrastructure/terraform/
  run: terraform init -backend=false

- name: terraform validate
  working-directory: infrastructure/terraform/
  run: terraform validate

- name: tflint
  working-directory: infrastructure/terraform/
  run: |
    tflint --init
    tflint --recursive

- name: tfsec
  uses: aquasecurity/tfsec-action@v1.0.3
  with:
    working_directory: infrastructure/terraform/
    soft_fail: false
```

`terraform init -backend=false` skips contacting the remote state backend — the validate-only path doesn't need state, and avoiding the backend means CI doesn't need write credentials for fast-path validation.

In **`terraform-plan.yml`** (deep feedback, infrastructure-touching PRs only):

```yaml
- name: terraform init (with backend)
  working-directory: infrastructure/terraform/
  run: terraform init
  env:
    AWS_ACCESS_KEY_ID:     ${{ secrets.TERRAFORM_PLAN_RO_AWS_KEY }}
    AWS_SECRET_ACCESS_KEY: ${{ secrets.TERRAFORM_PLAN_RO_AWS_SECRET }}

- name: terraform plan
  working-directory: infrastructure/terraform/
  run: terraform plan -out=tfplan -no-color | tee plan.txt

- name: Comment plan on PR
  uses: actions/github-script@v7
  with:
    script: |
      const fs = require('fs');
      const plan = fs.readFileSync('infrastructure/terraform/plan.txt', 'utf8');
      const truncated = plan.length > 60000
        ? plan.slice(0, 60000) + '\n...truncated...'
        : plan;
      github.rest.issues.createComment({
        issue_number: context.issue.number,
        owner: context.repo.owner,
        repo: context.repo.repo,
        body: '### Terraform plan\n\n```\n' + truncated + '\n```'
      });
```

The credentials used by the plan workflow are **read-only** at the AWS IAM layer — scoped to `*:Describe*`, `*:Get*`, `*:List*` on the resources Terraform manages. A compromised plan token cannot mutate infrastructure. The blast radius collapses from "destroy the platform" to "read configuration."

**Apply is not in CI.** Apply runs from a developer's authenticated workstation or from a dedicated supervised "apply runner" (a small EC2 instance or ECS task with elevated IAM, accessible only via SSO + MFA). The runbook (`docs/runbooks/terraform-apply.md`) documents the procedure. This is the deliberate human pause that protects EBS / EKS / IAM from auto-applied error.

The argument over the obvious alternative — auto-apply on merge to `main` — is the asymmetric-cost argument. GitOps purists are right that the merged commit IS the desired state and apply should follow automatically; they are right for **stateless** infrastructure (Lambda, IAM policies, Route53), and we accept that path if the team demonstrates appetite. They are wrong for **stateful** infrastructure where the cost of an erroneous merge is irreversible at human time scales. **Atlantis** and **Terraform Cloud** implement plan-as-comment + apply-via-PR-comment in a managed product with excellent ergonomics, and we documented them as the natural upgrade — Atlantis is a self-hosted service we'd then operate; Terraform Cloud is a paid SaaS that adds an account boundary for the reviewer. The bash-and-script approach in this section delivers ~80% of the value for ~5% of the operational cost. **Skipping `tfsec`** in favour of AWS Config / Security Hub at runtime is shift-right for a check that wins on shift-left — catching a public S3 bucket in CI prevents the bucket from existing at all; catching it via Security Hub means it existed for some window, possibly indexed.

The trade-offs are honest. Plan output can exceed GitHub's ~65KB comment cap; we truncate with a marker, and the runbook says "if the plan looks truncated, run `terraform plan` locally before applying" — acceptable because apply is manual anyway. `tfsec`'s rule set evolves and can shift to false-positive over time; pinning the action version (`@v1.0.3`) keeps the rule set stable. Read-only plan credentials require careful IAM curation — every new resource type Terraform manages may need IAM additions, documented in the runbook. Manual apply means human latency: PRs that merge during off-hours wait until morning. We accept that as a feature, not a bug — no 3 AM auto-apply on stateful infrastructure.

### 4. Helm CI — `helm lint` + `kubeconform -strict` + Pluto deprecation check

Helm charts are template-driven YAML generators where two classes of bug are easy to ship and impossible to catch by reading the chart source. **Template syntax errors** (a missing `{{ end }}`, a typo in `.Values.replicaCount`, an `if` that produces empty manifests under a particular values combination) surface only at `helm install`. **K8s schema violations** (a `Deployment` with the wrong `apiVersion`, a `StatefulSet` with `spec.serviceName` typo'd, a `PersistentVolumeClaim` with an invalid `storageClassName` shape) surface only when the API server rejects the manifest, sometimes long after `helm install` reports success.

Three Helm-related steps run in `pr-validation.yml`:

```yaml
- name: Helm lint
  run: helm lint helm/app/

- name: Helm template + kubeconform
  run: |
    helm template release-name helm/app/ --debug \
      | kubeconform -summary -strict \
                    -kubernetes-version 1.29 \
                    -schema-location default \
                    -schema-location 'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' \
                    -

- name: Deprecated API check (Pluto)
  run: pluto detect-helm helm/app/ -t k8s=v1.29.0
```

`-strict` rejects unknown fields, which catches `replicaCount` typos like `replicasCount`. The `datreeio/CRDs-catalog` provides schemas for any CRDs the chart references (`ServiceMonitor`, etc.). The K8s version is pinned at **1.29** to match the EKS LTS target — bumping the cluster is a coordinated operation that includes bumping this pin.

This catches both error classes in CI without spinning up a real cluster — no `kind`, no EKS sandbox, no kubectl. Total runtime is ~15 seconds for a chart this size. `helm lint` alone validates chart structure but not K8s API schema, so a `Deployment` using `apiVersion: extensions/v1beta1` (deprecated since 1.16) would pass `helm lint` and fail at `kubectl apply` — insufficient on its own. `helm install --dry-run` against a real cluster requires cluster spin-up (60-120s per PR), produces flaky tests when the test cluster is unwell, and validates only the request to the API server (not admission controllers) — partial coverage at higher cost. **Polaris** adds policy-grade checks (security best practices, resource-limit presence) and is overkill for the current chart count; documented as upgrade trigger. **helm-unittest** with values-matrix coverage is the right choice once chart logic branches on more than two values; not yet warranted.

The trade-offs are scoped. The CRD schema gap (kubeconform doesn't natively know all CRDs; the catalog is community-maintained and not exhaustive) is acceptable since the chart uses well-known CRDs only. The K8s 1.29 pin requires manual bump on cluster upgrade — documented in the cluster-upgrade runbook. `helm template` cannot fully simulate Helm hooks (rendered but not executed); hooks are tested in dedicated integration tests, not at this gate. We render the chart with `values.yaml` defaults only; a bug that surfaces only when `values.someFlag=true` is missed — mitigated by helm-unittest when chart complexity warrants.

### 5. Anonymisation gate — structural enforcement of the public/private boundary

The repository operates under a **Public/Private Boundary Rule**: public files (anything outside `_context/`, `.claude-rules/`, and the root `CLAUDE.md` / `AGENTS.md`) MUST NOT mention the customer by name. The private workspace is gitignored; the public repo is intentionally generic so the architecture stays portable across companies and the public submission persists independent of any single interview outcome.

A discipline-only rule is a rule waiting to fail. Under merge-conflict pressure, under context-switch fatigue, under copy-paste from a private prep doc, a developer eventually pastes the wrong string into a public file. Pushed to the public repo, captured by GitHub's commit history, indexed by search engines — one slip undoes the entire point of the public/private split. The cost of one slip is high; the marginal cost of a CI check is one second per PR.

The anonymisation grep runs as a mandatory step in `pr-validation.yml`. A non-zero match count fails the workflow:

```yaml
- name: Anonymisation check (Public/Private Boundary Rule)
  run: |
    matches=$(grep -ri "<company-name>" \
      --include="*.md" --include="*.yaml" --include="*.yml" \
      --include="*.tf" --include="*.sh" --include="*.json" \
      --exclude-dir=_context \
      --exclude-dir=.claude-rules \
      --exclude-dir=.git \
      --exclude-dir=node_modules \
      . | wc -l)
    if [ "$matches" -gt 0 ]; then
      echo "ERROR: Customer name found in public files. The Public/Private Boundary Rule forbids this."
      grep -rin "<company-name>" \
        --include="*.md" --include="*.yaml" --include="*.yml" \
        --include="*.tf" --include="*.sh" --include="*.json" \
        --exclude-dir=_context \
        --exclude-dir=.claude-rules \
        --exclude-dir=.git \
        --exclude-dir=node_modules \
        .
      exit 1
    fi
    echo "OK: Public surface clean."
```

The actual customer name is held in a repository secret (`COMPANY_PRIVATE_NAME`) and substituted into the grep at runtime, so the check itself does not encode the very string we are forbidding from public files. This avoids the meta-leak where the workflow YAML (a public file) would otherwise contain the forbidden token.

A matching `.git/hooks/pre-commit` script that runs the same grep is provided as `scripts/dev/install-hooks.sh` for fast local feedback. It's not mandatory because hooks are bypass-able (`git commit --no-verify`), not enforced on CI-only contributors, and not enforced for AI-generated commits where the hook may be skipped. Hooks are useful as fast local feedback; they are not authoritative. CI must hold the line.

The argument against the obvious alternatives is the asymmetric-cost argument again. **Discipline-only** loses on the cost of a single permanent slip. **Pre-commit hook only** loses on bypass-ability and CI-only contributors. **A third-party secret-scanner action** (`gitleaks`, `trufflehog`) is reasonable but oversized — those tools target real secrets (AWS keys, JWTs, certs) with sophisticated entropy detection; configuring them for a plain-string match is more YAML than the eight-line bash above. Documented as the upgrade trigger if the forbidden-string list grows past ~10 patterns. **Encrypt-at-rest the customer name in public files via tokens** is rejected because the public repo is read by hiring teams and architecture evaluators; un-substituted public docs would be confusing and amateur. The right answer is to write public docs in genuinely customer-agnostic prose, which is what the Boundary Rule already mandates.

The known gaps are scoped: the check does not catch images, binaries, or filenames. A PNG with the customer logo embedded, or a file named `the-customer-config.tf`, would slip through. POC accepts this; mitigation is reviewer judgment in PRs. A more thorough check would scan filenames and OCR images — listed as upgrade trigger.

### 6. GitOps — ArgoCD pull-based, sync policy split by tier

CI's job ends at "artifact published, validated, signed." The next problem — *how does that artifact reach the cluster?* — is a deployment-controller question, not a CI question. **Push from CI** (CI runs `helm upgrade --install` with `KUBECONFIG` injected as a secret) is simple, direct, and produces no record on the cluster that anything was supposed to happen — drift between git and cluster is invisible. **Pull from cluster** (a controller inside the cluster watches a git repository, reconciles desired state to actual state, surfaces drift as alerts) is the GitOps shape. **Imperative tooling** (Pulumi, kubectl scripts) sacrifices the "git is the source of truth" property.

For this architecture, drift detection matters more than usual. The stateful tier's pods are pinned to specific EBS volumes (per ADR-02), and an undetected configuration drift on a primary pod could silently change replica count, resource limits, or volume claim references — any of which can corrupt or orphan customer data. The asymmetry between "stateless tier drift" (cheap to fix) and "stateful pod drift" (potentially data-affecting) drives the choice toward a controller that detects and alerts on drift, not one that pushes and forgets.

A second concern: the stateful tier is exactly where automatic reconciliation becomes dangerous. A self-healing controller that auto-syncs every commit will happily restart a primary pod to apply a label change, mid-traffic. The deployment policy must distinguish stateless ("sync aggressively, drift is bad") from stateful ("review the change, apply on a maintenance window, never auto-stomp a running pod").

**ArgoCD** is the deployment controller. AppProject + Application CRDs source manifests from this repo (`helm/aegis-statefulset/` for the chart; `infrastructure/terraform/` is out of ArgoCD scope — Terraform manages itself per §3). Sync policy is **split by tier**:

```yaml
# Stateless tier — auto-sync + self-heal + auto-prune
syncPolicy:
  automated:
    prune: true
    selfHeal: true
  syncOptions:
    - CreateNamespace=true

# Stateful tier — manual sync only
syncPolicy: {}   # no automated block — manual sync via UI or `argocd app sync`
```

The stateless tier (API tier, Envoy router, observability stack, control plane) benefits from aggressive self-heal: any drift is a bug, fix it. The stateful tier (primary + standby StatefulSets) requires human review before sync — the operator runs `argocd app diff`, verifies the backup window via Dashboard #5 (per ADR-06), and manually triggers `argocd app sync`. **Manual sync only for prod** is the canonical rule; CI does plan + lint, never apply.

**AppProject** scopes RBAC and source whitelisting:

```yaml
spec:
  sourceRepos:
    - https://github.com/<org>/aegis-statefulset
  destinations:
    - server: https://kubernetes.default.svc
      namespace: 'app-*'
  clusterResourceWhitelist:
    - group: ''
      kind: Namespace
  namespaceResourceBlacklist:
    - group: ''
      kind: ResourceQuota   # managed by platform team, not Helm
```

The AppProject is the multi-tenancy primitive — if the platform later hosts multiple application teams, each gets their own AppProject with their own source whitelist and destination scope.

The argument over **Flux v2** is a coin flip the POC resolves toward ArgoCD on operational ergonomics: ArgoCD's UI is more discoverable for newcomers (lower onboarding cost for a small SRE team), and ApplicationSet is more expressive than Flux's `Kustomization` + matrix pattern for the multi-env fan-out in §7. Flux would be a clean swap if the customer already runs it; the architectural benefits (pull model, drift detection, multi-env fan-out) are equivalent and adopting the team's existing controller reduces onboarding cost to near-zero. **Pulumi for K8s** loses the GitOps pull model — Pulumi runs from a CI worker mutating cluster state directly; the drift-detection-via-reconciliation property is gone. **Push-based GitHub Actions running `helm install`** loses on no drift detection, no audit trail beyond rotating CI logs, and `KUBECONFIG` in CI secrets increasing the credential blast radius. **Direct `kubectl apply` from a runbook** loses on every dimension that matters.

The honest scope statement: ArgoCD has been operated at portfolio level (`aegis-aws-landing-zone`), not at production scale. Senior in conceptual depth — sync policies, AppProject RBAC, ApplicationSet patterns, the stateless / stateful sync-policy split — and ramping in operational scar tissue (long-running ArgoCD upgrades, repo-server scaling, sync-wave debugging at scale). Portfolio-level use does not equal panel-level operational depth across every edge case; framed honestly in Stage 3.

The trade-offs are operational. ArgoCD itself runs as Deployments + StatefulSet in a dedicated namespace and becomes an SRE responsibility — its own upgrade cadence, its own backup story for the application registry. Manual sync for stateful means a merged PR is *queued* until a human clicks Sync; forgotten syncs become silent drift, mitigated by an alert rule (per ADR-06) on "stateful Application OutOfSync > 24h." ArgoCD UI editing creates drift — a well-meaning operator can edit live resources via the UI; mitigated by AppProject RBAC restricting UI write actions to `argocd-admin` role. First-sync chicken-and-egg: ArgoCD needs to be installed before it can manage anything, including itself; bootstrapping via Helm + `terraform apply`, then ArgoCD adopts itself via an Application pointing at its own chart. Repo coupling: ArgoCD watches one or more git repos, so repo availability is a deployment-path dependency — GitHub's SLA is high enough; stricter posture mirrors to S3-backed git or self-hosted Gitea.

### 7. Multi-environment fan-out — ApplicationSet, PR-based promotion through soak windows

A flat per-env Application layout works for two environments and one shared stack. Two pressures push beyond it: a third environment will appear (dev → staging → prod, where staging is the soak chamber that runs real-traffic-shaped load against the production candidate before customer data is touched), and **promotion needs to be a deliberate, audited event** — not "an operator edits the prod Application's `targetRevision` from a workstation with no record beyond shell history."

**ArgoCD ApplicationSet** (list generator) is the multi-env primitive. A single template parameterised by a generator produces N Applications, one per environment:

```yaml
generators:
  - list:
      elements:
        - env: dev
          targetRevision: main
          valuesFile: values-dev.yaml
          namespace: app-dev
          syncPolicyMode: auto
        - env: staging
          targetRevision: <SHA>          # bumped via promotion PR after dev soak
          valuesFile: values-staging.yaml
          namespace: app-staging
          syncPolicyMode: auto
        - env: prod
          targetRevision: <SHA>          # MUST be specific SHA, not branch
          valuesFile: values-prod.yaml
          namespace: app
          syncPolicyMode: manual
template:
  metadata:
    name: 'aegis-statefulset-{{.env}}'
  spec:
    project: aegis-statefulset
    source:
      repoURL: https://github.com/BinHsu/aegis-statefulset.git
      targetRevision: '{{.targetRevision}}'
      path: helm/aegis-statefulset
      helm:
        valueFiles:
          - values.yaml
          - '{{.valuesFile}}'
    destination:
      server: https://kubernetes.default.svc
      namespace: '{{.namespace}}'
```

`repoURL`, `path`, `helm.valueFiles[0]`, `project`, and `destination.server` live in one template. Per-env Applications copy-paste these and drift over time — the manifest that says "auto-sync, but not really, mostly" is born from one of those drifts. Adding a regional clone, a dedicated tenant cell, or a canary cell becomes a single list element, not a new file.

**Promotion model** (fixed sequence):

1. Developer merges a PR to `main` → **dev** auto-syncs.
2. After dev soak (24h, error budget green, no SLO regression), open a **promotion PR** bumping **staging** `targetRevision` to dev's commit SHA.
3. PR is reviewed; CI gates run (anonymisation §5, helm lint §4, terraform validate §3); on merge, staging auto-syncs.
4. After staging soak (24-48h depending on change class), open a promotion PR bumping **prod** `targetRevision` to staging's commit SHA.
5. After prod PR merge, prod stays `OutOfSync` (no automated block per §6).
6. Operator runs `argocd app sync aegis-statefulset-prod` after `argocd app diff` review and a verified backup window.

| Env | `targetRevision` | Sync mode | Rationale |
|---|---|---|---|
| dev | `main` | auto | Tracks trunk; failure is cheap. |
| staging | specific SHA | auto | Soak chamber; SHA pin means reproducible deploy. |
| prod | specific SHA | **manual** | Stateful tier; SHA pin + human sync gate. |

PR-based promotion (over direct CLI bump) buys an audit trail (`git log gitops/argocd/applicationsets/` is the canonical record of what went to prod when), forced diff review (a PR diff is mandatory; `argocd app diff` is voluntary), CI gates running on the promotion PR (the anonymisation gate, helm lint, terraform validate all run on the bump PR — catching the case where staging passed but a late chart edit slipped in), and `git revert` as the rollback mechanism (no bespoke runbook; revert the promotion PR, ArgoCD sees the old SHA, sync rolls forward to the prior state — stateful caveat: data-affecting changes still need ADR-04 recovery paths; the GitOps revert covers config rollback only).

The trade-offs are deliberate. ApplicationSet introduces a generator + template indirection that new operators have to learn — `argocd app get aegis-statefulset-prod` shows the rendered Application, but the source-of-truth lives in the ApplicationSet. Per-element sync policy is a sharp edge in pure ApplicationSet templates: the `syncPolicy.automated` block either exists or doesn't, and templating it via `if/else` is brittle — POC handles this via a dedicated prod Application (manual sync) with the ApplicationSet covering dev / staging only, with the fully unified path documented as follow-up. PR-based promotion is slower than direct CLI (5-15 minutes including review vs 30 seconds); an emergency-bypass procedure with a CHANGE_NUMBER and post-merge post-mortem is documented for genuine hotfixes. Soak windows add lead time (24h dev + 24-48h staging means a typical change reaches prod in 2-3 days from merge) — a feature for stateful platforms where production data is the asset and lead time is the acceptable price for filtering bad changes.

## Trade-offs accepted (cross-cutting)

- **Vendor lock-in to GitHub Actions** — accepted; rewrite cost is low against the daily PR-integration benefit, and the architectural decisions port to any CI platform.
- **Manual apply means human latency on Terraform changes** — accepted as a feature on stateful infrastructure.
- **Manual sync on stateful prod means forgotten syncs become silent drift** — mitigated by the OutOfSync > 24h alert rule.
- **Provider download in `terraform init` adds ~10-30 seconds per workflow** — cached via `actions/cache` keyed on `.terraform.lock.hcl`.
- **CRD schema gap in kubeconform** — accepted; chart uses well-known CRDs only; community catalog covers them.
- **Repository secret for the anonymisation forbidden token is awkward** — documented inline so future contributors don't "simplify" by hardcoding.
- **ApplicationSet adds an abstraction layer** — accepted; offset by DRY and the explicit per-env revision pinning.
- **Promotion PR overhead** — accepted; a feature on stateful platforms.

## Alternatives considered (consolidated)

- **CircleCI / Jenkins / AWS CodePipeline / GitLab CI** — rejected on platform-alignment, ops burden, and reviewer-friction asymmetry.
- **Single monolithic `ci.yml`** — rejected on debugging ergonomics.
- **Auto-apply on merge to `main`** — accepted for stateless infrastructure if team appetite emerges; rejected for stateful (EBS / EKS / VPC).
- **Atlantis / Terraform Cloud (HCP)** — rejected for POC on ops cost / SaaS account boundary; documented as natural upgrade.
- **AWS Config / Security Hub instead of `tfsec`** — rejected as shift-right where shift-left wins.
- **`helm lint` only** — rejected as insufficient for K8s schema validation.
- **`helm install --dry-run` against a real cluster** — rejected on cluster spin-up cost and partial coverage.
- **Polaris / Conftest / OPA Rego policies** — documented as upgrade triggers when chart count or organisational policy library demands.
- **Discipline-only / pre-commit-hook-only anonymisation** — rejected on bypass-ability and asymmetric-leak cost.
- **`gitleaks` / `trufflehog` for anonymisation** — documented as upgrade trigger past ~10 forbidden patterns.
- **Push-based deployment from CI** — rejected on no drift detection and credential blast radius.
- **Pulumi / direct `kubectl apply`** — rejected on losing the pull-based reconciliation property.
- **Flux v2 instead of ArgoCD** — equally defensible; would adopt if customer runs Flux already.
- **Per-env Application manifests instead of ApplicationSet** — rejected on duplication drift.
- **Direct CLI promotion** — rejected on no audit trail and no forced diff review.

## Out of POC scope (upgrade triggers)

- **Self-hosted runners on private VPC infrastructure.** Trigger: workflows must reach private EKS endpoints, private S3, or VPC-only services.
- **Reusable workflows / composite actions.** Trigger: pipeline DRY-up across 5+ workflows.
- **Build attestation and SLSA provenance.** Trigger: customer or compliance demand for verified build supply chain (GitHub Actions has native `attestations` support).
- **Atlantis / Terraform Cloud for plan + supervised apply.** Trigger: team appetite for chat-ops style apply.
- **Multi-workspace plan fan-out.** Trigger: dev / staging / prod environments diverge enough that "validate against all" matters more than "validate against one."
- **Drift detection scheduled workflow for Terraform.** Trigger: hand-edits or console changes become a source of drift.
- **OPA / Conftest policies on plan output.** Trigger: organisational policies grow past `tfsec` native coverage.
- **Cost estimation in plan comment (`infracost`).** Trigger: visible UX win; near-term upgrade.
- **helm-unittest with values-matrix coverage.** Trigger: chart logic branches on more than two values.
- **Polaris / Datree / Monokle policy checks.** Trigger: chart count and contributor count grow past where bash + kubeconform feels lightweight.
- **Multi-token forbidden-string list via `gitleaks`.** Trigger: list grows past ~10 patterns.
- **Filename and binary scanning for anonymisation.** Trigger: a near-miss where a logo image or filename leaked the customer identity.
- **ArgoCD HA replica configuration.** Trigger: ArgoCD becomes a hard dependency for incident response or scale exceeds single-replica throughput.
- **App-of-Apps across multiple repos.** Trigger: more than one application or team uses the controller.
- **ArgoCD Notifications / Slack integration.** Routine follow-up; out of POC.
- **Sync waves and pre/post-sync hooks.** Trigger: complex dependency graphs where natural Helm template ordering doesn't suffice.
- **Argo Rollouts (canary / blue-green) layered on stateless tier.** Trigger: traffic-impacting changes need staged rollout within a single environment.
- **Matrix generator for multi-cluster, multi-environment fan-out.** Trigger: platform scales to multiple regional clusters with the same env shape.
- **Promotion automation via PR bot.** Trigger: promotion cadence becomes the bottleneck.

## Stage 3 questions

1. CI platform preference — does the team operate GitLab CI or Jenkins for the legacy stack? The four-workflow architecture and the validation tooling port to any platform; only the YAML changes.
2. Branching and release cadence — trunk-based with feature flags, or GitFlow with long-lived release branches? Drives trigger lists for `helm-release.yml` and `terraform-plan.yml`.
3. Apply posture for Terraform — manual on all stateful, manual with two-person approval, or auto-apply for dev cluster with manual on prod? An `infrastructure-apply.yml` with environment protection rules can encode multi-reviewer requirements.
4. K8s LTS target — does the team standardise on 1.29, 1.28 (enterprise upgrade lag), or 1.30 (ahead-of-curve)? Drives the kubeconform `-kubernetes-version` pin.
5. Anonymisation expectation for the public submission — is the customer comfortable with the company name in the public repo, or does the Boundary Rule stay mandatory? Default is anonymised: safer, and preserves architecture portability.
6. Existing GitOps tooling — Flux already in production? Switch to Flux for zero onboarding friction; the architectural benefits are equivalent.
7. Existing environment promotion model — dev / staging / prod cadence, soak windows, change-management gates? The ApplicationSet generator and the PR template adjust to match; the principle (explicit revision pinning per env, PR-based promotion, manual sync for stateful prod) is invariant.

## Cross-references

- ADR-01 — architecture & topology; the 3-tier flow this pipeline deploys (ALB → API → Envoy → StatefulSet) is what the `helm template | kubeconform` step validates against.
- ADR-02 — storage; EBS-as-treasure is the reason §3 keeps Terraform apply manual and §6 keeps stateful sync manual.
- ADR-03 — routing; Helm chart values for the Envoy router and consistent-hash override delta are gated by §4's kubeconform step.
- ADR-04 — backup, DR & HA; the quarterly DR drill in §2 rehearses the cold-DR-via-Velero recovery path; the manual sync gate for stateful prod in §6 protects against accidental config push during failover.
- ADR-05 — migration; Strangler Fig migration manifests promote through the same dev → staging → prod sequence in §7.
- ADR-06 — observability; the OutOfSync > 24h alert in §6 lives in the alert tier from ADR-06; dashboards deployed via the Terraform Grafana provider promote through the same pipeline.
- ADR-07 — security; SHA-pinned actions, signed Helm artifacts (cosign in §2), and read-only plan credentials in §3 are the supply-chain hygiene surface.
- ADR-09 — supply chain; SHA pinning, image scanning (Trivy in §2), and SBOM generation extend the §1 / §2 / §5 disciplines.
- ADR-10 — FinOps; DR drill cluster cost (~$30-50/quarter), GitHub Actions free-tier ceiling, and `infracost` in plan comments (upgrade trigger) are the cost-architecture surface for CI/CD.
- Originally split across private ADR-033..ADR-038, ADR-041; consolidated 2026-05-09.
