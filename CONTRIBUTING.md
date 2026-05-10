# Contributing

This is a portfolio / submission repository — external contributions are not solicited, but the validation discipline below is the same any maintainer should run before pushing a change.

## Local validation before commit

```bash
# Helm chart
helm lint helm/aegis-statefulset/
helm template helm/aegis-statefulset/ --debug \
  | kubeconform -summary -strict -schema-location default -schema-location \
    'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main/{{.Group}}/{{.ResourceKind}}_{{.ResourceAPIVersion}}.json' -

# Terraform
cd infrastructure/terraform
terraform fmt -check -recursive
terraform validate
tflint --recursive
tfsec .
cd -

# Shell scripts
shellcheck scripts/**/*.sh

# Markdown links + style (optional but recommended)
markdownlint '**/*.md' --ignore node_modules

# ArgoCD manifests render-check (optional)
for f in gitops/argocd/applications/*.yaml; do
  kubectl apply --dry-run=client -f "$f"
done
```

All four CI workflows (see ADR-08) run the equivalent of these checks on PR. Running them locally first avoids round-tripping through CI.

## Anonymisation rule

This repo contains no organisation-specific names. The Public/Private Boundary Rule (`CLAUDE.md`, gitignored) requires that public files refer only to "the application", "the platform", "the team", "the customer", or generic concepts (tenant, workspace, pod). A pre-commit hook enforces this gate locally; the same rule runs in CI per ADR-08.

Install the local hook:

```bash
cp scripts/git-hooks/pre-commit .git/hooks/pre-commit
chmod +x .git/hooks/pre-commit
```

The hook runs `grep -ri` against the substitution table for any tracked file. CI runs the same check on every PR — discipline drift is real, and a single leaked organisation-name commit is permanent (git history is forever).

## ADR workflow

To propose a new architectural decision, add a new file to `docs/adr/` following the existing 9-section format:

1. **Status** — proposed / accepted / superseded by ADR-NNN
2. **Date**
3. **Context** — what problem are we solving, what constraints apply
4. **Decision** — what we are going to do
5. **Alternatives considered** — what we evaluated and rejected, with reasoning
6. **Consequences** — positive, negative, and neutral effects
7. **Cross-references** — related ADRs
8. **Open questions** — what we are deferring or want to validate
9. **References** — external docs, RFCs, vendor pages

ADRs are numbered sequentially (`ADR-NNN-short-slug.md`) and never renumbered after merge. Superseding an ADR creates a new one referencing the old; the old keeps its number.

## CI checks

The four workflows (per ADR-08):

| Workflow | Trigger | Purpose |
|---|---|---|
| `pr-validation.yml` | every PR | Fast feedback — Helm lint + kubeconform, Terraform fmt + validate + tflint + tfsec, shellcheck, markdownlint, anonymisation gate (ADR-08), Trivy image scan (ADR-07) |
| `helm-release.yml` | git tag `v*` | Package chart, sign with Cosign (ADR-07), push OCI artifact to GitHub Container Registry |
| `terraform-plan.yml` | PR with `infrastructure/**` changes | `terraform plan` with read-only IAM, post plan as PR comment, manual `apply` outside CI |
| `dr-drill.yml` | quarterly cron | Exercise ADR-04 recovery paths (Path A / B / C) against a disposable cluster, post results as a GitHub issue |

External references (Helm charts, container images, GitHub Actions, Terraform modules) are pinned to immutable identifiers (commit SHA or chart digest) per ADR-09. Renovate handles bumps via PR.
