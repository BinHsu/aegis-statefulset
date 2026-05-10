# Submission-day runbooks

Operations Bin executes personally — outside the Claude trust boundary.
The architecture, manifests, and CI workflows are in the repo; these runbooks
are the human-side operations that touch credentials, AWS billing, and
external accounts.

Run order on submission day:

| # | Runbook | Time | Cost (USD) | Prereq |
|---|---|---|---|---|
| 01 | [Docker build + push + digest update](01-docker-build-push.md) | ~15 min | ~$0 | Docker, ECR (or chosen registry) |
| 02 | [AWS bootstrap + chaos demo](02-aws-bootstrap-and-chaos-demo.md) | ~3 h | ~$50–100 | AWS account, terraform, kubectl |
| 03 | [GitHub Actions OIDC trust](03-github-actions-oidc.md) | ~30 min | $0 | AWS IAM admin, GitHub repo admin |
| 04 | [Grafana Cloud setup](04-grafana-cloud-setup.md) | ~30 min | $0 (free tier) | Email |
| 05 | [Submission email to Sebastian Weikart](05-submission-email.md) | ~10 min | — | Items 01–04 done; SUBMISSION.pdf rendered |

**Recommended sequencing:** 01 → 03 → 04 in any order (they're independent
preparation steps), then 02 (the live demo, last because it spends money),
then 05 (after 02 produces dashboard screenshots / chaos evidence).

**Hard prerequisites — do these BEFORE anything in this folder:**
- Repo cloned to working tree, no uncommitted Wave 4 changes
- `aws --version` ≥ 2.13
- `terraform --version` ≥ 1.6
- `kubectl version --client` ≥ 1.28
- `helm version` ≥ 3.13
- `docker --version` ≥ 24
- `gh --version` ≥ 2.40 (for OIDC runbook)

**Cost honest framing (Mittelstand grade — no surprises):**
- Item 02 is the only paid item. Estimated US$50–100 for a 2–4 hour
  EKS run (control plane + 3–4 nodes + EBS + NAT). Tear down immediately
  after demo via `terraform destroy` per Item 02 § 7.
- All other items use free-tier services (GitHub free, Grafana Cloud free,
  Docker Hub free for distroless pulls).

**Trust boundary reminder:** Claude wrote these runbooks. Bin runs them.
No step here is automatable from Claude's session — every step touches a
credential, billing surface, or external system that the AI agent has no
business holding.
