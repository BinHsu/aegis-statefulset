# Contributing

This is a portfolio / submission repository — external contributions are not solicited, but the validation discipline below is the same any maintainer should run before pushing a change.

## Local validation before commit

The quickest path is the `make` targets, which mirror the CI gates in `pr-validation.yml`:

```bash
make precommit   # fast gate: anonymisation + secrets + kubeconform
make prepush     # full gate: precommit + Go app + helm + terraform
```

The two targets back the `pre-commit` and `pre-push` git hooks (see [Anonymisation rule](#anonymisation-rule)). To run the individual checks by hand:

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

This repo contains no organisation-specific names. The Public/Private Boundary Rule (`CLAUDE.md`, gitignored) requires that public files refer only to "the application", "the platform", "the team", "the customer", or generic concepts (tenant, workspace, pod). Git hooks enforce this gate locally; the same rule runs in CI per ADR-08.

Install the hooks once per clone:

```bash
make hooks-install
```

This points `git config core.hooksPath` at `scripts/git-hooks/`, activating both hooks in one step. The repo uses a two-tier hook design that mirrors the CI layering:

- **`pre-commit` — fast gate.** Runs on every commit; finishes in seconds.
- **`pre-push` — full gate.** Runs `make prepush` (whole-repo anonymisation re-scan + the Go app suite + golangci-lint + helm lint + terraform fmt) — the last gate before code leaves the machine.

The `pre-commit` hook runs five checks in sequence:

1. **Anonymisation word-boundary scan** (Public/Private Boundary Rule per ADR-08)
2. **Wave 1 stale-content scan** (legacy flat-schema backup-schedule patterns retired in the Wave 4 dual-cadence migration)
3. **Credential leak scan** (key material patterns + suspicious `.env` content)
4. **helm template + kubeconform** (CRD-aware schema validation)
5. **Hallucination defense** (claim-attribution + free-floating-quantitative, two-tier severity — BLOCK on historical fabrication patterns; WARN on general attribution patterns; suppress per-line via `<!-- ci:verified -->` after manual review)

CI runs the same checks on every PR — discipline drift is real, and a single leaked organisation-name commit (or fabricated quantitative claim) is permanent (git history is forever).

## ADR workflow

To propose a new architectural decision, add a new file to `docs/adr/` following the existing 9-section format:

1. **Status** — proposed / accepted / superseded by ADR-NN
2. **Date**
3. **Context** — what problem are we solving, what constraints apply
4. **Decision** — what we are going to do
5. **Alternatives considered** — what we evaluated and rejected, with reasoning
6. **Consequences** — positive, negative, and neutral effects
7. **Cross-references** — related ADRs
8. **Open questions** — what we are deferring or want to validate
9. **References** — external docs, RFCs, vendor pages

ADRs are numbered sequentially (`ADR-NN-short-slug.md`, two-digit since the public 10-mega consolidation) and never renumbered after merge. Superseding an ADR creates a new one referencing the old; the old keeps its number.

## CI checks

Eleven workflows total — four primary plus seven supporting (per ADR-08):

### Primary workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `pr-validation.yml` | every PR | Fast feedback — Helm lint + kubeconform, Terraform fmt + validate + tflint + tfsec, shellcheck, anonymisation gate (ADR-08), Trivy filesystem scan (ADR-032), Go app gate (gofmt / vet / test -race / build / govulncheck) |
| `helm-release.yml` | git tag `v*` | Package chart, sign with Cosign (ADR-07), push OCI artifact to GitHub Container Registry |
| `terraform-plan.yml` | PR with `infrastructure/**` changes | `terraform plan` with read-only IAM, post plan as PR comment, manual `apply` outside CI |
| `dr-drill.yml` | quarterly cron | Exercise ADR-04 recovery paths (Path A / B / C) against a disposable cluster, post results as a GitHub issue |

### Supporting workflows

| Workflow | Trigger | Purpose |
|---|---|---|
| `cis-benchmark.yml` | weekly cron + manual | CIS Kubernetes Benchmark scan against the deployed cluster (kube-bench) |
| `dast.yml` | weekly cron + manual | Dynamic application security testing against the staging endpoint (OWASP ZAP) |
| `sbom-attestation.yml` | every release | Generate CycloneDX SBOM, sign + attach to OCI artifact (in-toto provenance per SLSA v1.0) |
| `secret-scanning.yml` | every PR + push to main | gitleaks scan for accidentally committed credentials (defense-in-depth alongside the pre-commit credential leak check) |
| `codeql.yml` | PR + push to main | CodeQL static application security testing (SAST) for the Go workload — logic flaws the dependency scanners cannot see (ADR-07, ADR-09) |
| `dependency-review.yml` | every PR | Diff-scoped supply-chain gate — blocks a PR that introduces a dependency with a known HIGH+ vulnerability or incompatible licence (ADR-09) |
| `teardown.yml` | manual dispatch | Destructive environment teardown, guarded by a typed confirmation string |

External references (Helm charts, container images, GitHub Actions, Terraform modules) are pinned to immutable identifiers (commit SHA or chart digest) per ADR-09. Renovate handles bumps via PR.
