# Environment Promotion Model

This runbook documents how a change moves from developer's laptop to production. The model is **PR-based promotion** through a fixed sequence — `main` (dev) → staging → prod — with soak windows between environments and a manual sync gate at the production boundary. ADR-08 is the architectural decision; this file is the operator's manual.

## Why PR-based promotion

A promotion is a deliberate, audited event. Every step lives in git: author, reviewer, timestamp, diff, CI gate results. There is no shell-history-only promotion path.

Three properties drop out of the PR model:

- **Audit trail.** `git log gitops/argocd/applicationsets/aegis-statefulset.yaml` is the canonical record of "what shipped to which env when." Operator laptops have no audit trail; PRs do.
- **Diff review is forced.** Every promotion PR shows the SHA delta and (if values files changed) the configuration delta. The reviewer sees what's about to ship before merge, not after.
- **CI gates run on the promotion PR.** The same gates that protected the underlying change (anonymization per ADR-08, helm lint per ADR-08, terraform validate per ADR-08, tfsec) re-run on the PR that promotes it. This catches the case where a late edit slipped in via direct push between the original feature PR and the promotion PR.

The cost is lead time — a CLI bump takes 30 seconds; a PR cycle takes 5-15 minutes. The trade is intentional. Production is stateful; latency on bad changes hitting customer data is more expensive than latency on the promotion happy path.

## The four states

| State | `targetRevision` | Sync mode | Soak window | Source |
|---|---|---|---|---|
| **dev** | `main` | auto | n/a (continuous) | every merge to `main` |
| **staging** | specific SHA | auto | 24h before prod-bump | promotion PR from dev |
| **prod** | specific SHA | manual | 24-48h before next bump | promotion PR from staging |
| **emergency hotfix** | specific SHA | manual | post-merge post-mortem | bypass procedure (below) |

Soak window definitions:

- **dev soak**: 24 hours after the merge to `main`, with no SLO regression and no unresolved alerts. Calendar time, not engineering time — a Friday-night merge starts the soak clock at merge time, but the human review of the staging promotion PR happens during business hours.
- **staging soak**: 24-48 hours under production-shaped synthetic load. Lower bound for low-risk changes (helm template touchups, observability tweaks); upper bound for stateful or schema-touching changes.

## Promotion PR template

A promotion PR is a one-line YAML edit. The PR description carries the substance — what's promoting, why now, what tests passed, who approved.

### Example: promote dev SHA → staging

```diff
# gitops/argocd/applicationsets/aegis-statefulset.yaml
   generators:
     - list:
         elements:
           - env: dev
             targetRevision: main
             ...
           - env: staging
-            targetRevision: 4f3a2b1c8e9d7f6a5b4c3d2e1f0a9b8c7d6e5f4a   # 2026-04-30 release
+            targetRevision: 7c2e9f1a3b5d8e2f4a6c8b0d2f4a6c8e0a2c4e6f   # 2026-05-08 release
             valuesFile: values-staging.yaml
             ...
```

PR description must include:

```markdown
## What's being promoted

- **From:** dev @ `4f3a2b1c...` (current staging pin)
- **To:**   dev @ `7c2e9f1a...` (proposed new pin)
- **Diff:** [link to GitHub compare URL between the two SHAs]

## Soak summary

- Dev soak start:   2026-05-08 14:00 CET (merge of feature PR #234)
- Dev soak end:     2026-05-09 14:00 CET (24h, completed)
- SLO check:        all green (error budget unchanged)
- Open alerts:      none

## Risk class

- [ ] Low (template, observability, docs)
- [x] Medium (chart values, RBAC, network policy)
- [ ] High (StatefulSet template, PVC schema, storage class)

## Reviewer checklist

- [ ] Diff between SHAs reviewed
- [ ] No anonymization-gate failures (CI re-run)
- [ ] No helm-lint failures (CI re-run)
- [ ] If touching infra: terraform plan reviewed
- [ ] On-call engineer named and informed: @<handle>
```

### Example: promote staging SHA → prod

Same shape; the diff edits the `prod` element instead of `staging`. The reviewer checklist adds:

```markdown
- [ ] Backup completed within last `backup.cadence_minutes` window
- [ ] Maintenance window confirmed: <YYYY-MM-DD HH:MM> CET
- [ ] Manual sync planned for: <YYYY-MM-DD HH:MM> CET
- [ ] Rollback plan: revert this PR + `argocd app sync aegis-statefulset-prod`
```

## Manual sync procedure for prod

After the prod promotion PR merges, the prod Application is `OutOfSync` until an operator runs:

```bash
# 1. Check what will change (diff against rendered manifests).
argocd app diff aegis-statefulset-prod

# 2. Dry-run the sync if the diff is non-trivial.
argocd app sync aegis-statefulset-prod --dry-run

# 3. Real sync. Use `--prune` only when the PR explicitly intends pruning.
argocd app sync aegis-statefulset-prod

# 4. Wait for completion (10-min timeout).
argocd app wait aegis-statefulset-prod --timeout 600
```

Cross-link: the existing manual-sync gate documentation lives in `gitops/argocd/README.md` § "Manual sync procedure for prod" — this runbook is the promotion-PR side; that runbook is the post-merge side.

## Rollback via revert PR

The promotion PR is the rollback handle. Revert the PR; ArgoCD reconciles back to the prior SHA.

```bash
# 1. Identify the bad promotion PR.
gh pr list --search "promote staging to prod" --state merged --limit 5

# 2. Revert it.
gh pr create --title "revert: <bad PR title>" \
  --body "Reverting promotion PR #<N> due to <reason>." \
  --head "revert-promotion-<N>"

# 3. Merge the revert PR (CI gates re-run).

# 4. For prod: the revert restores the previous SHA in the manifest, but
#    prod stays OutOfSync until manual sync. Run `argocd app sync` per
#    the manual procedure above.

# 5. For dev/staging: auto-sync picks up the revert and rolls forward
#    (which, in this case, rolls back) within the next reconcile cycle.
```

**Stateful caveat.** Git revert covers configuration rollback only. If the bad change ran a one-way data migration (schema bump, on-disk format change), the GitOps revert won't undo the data side — that's ADR-04 territory (Path A: restart from snapshot; Path B: rebuild). The PR description's "Risk class: High" flag exists to make the reviewer ask "is this a one-way change?" before merge.

## Emergency hotfix path

Reserved for security-impacting bugs and customer-facing outages where standard promotion lead time is unacceptable.

**Required:**
- A `CHANGE_NUMBER` from the incident ticket.
- The on-call engineer initiates; a second platform-team engineer reviews the PR (even if review is post-merge).
- Post-mortem within 5 business days, posted to the platform team's runbook repo.

**Procedure:**

```bash
# 1. Create the fix PR against `main`. CI runs; merge to dev.
# 2. After dev verifies the fix (smoke test, not a 24h soak), open a
#    bypass-promotion PR labelled `emergency-hotfix` that bumps staging
#    AND prod to the same SHA in one commit.
# 3. The label `emergency-hotfix` lets the PR template skip the soak-summary
#    section but REQUIRES the CHANGE_NUMBER and post-mortem owner fields.
# 4. After merge, run the prod manual sync per the procedure above.
# 5. File the post-mortem within 5 business days.
```

The bypass exists; using it is itself a tracked event (PRs labelled `emergency-hotfix` show up in the platform-team metrics dashboard). Repeated use signals a process problem upstream — either the soak windows are wrong for the actual risk profile, or feature PRs are landing without sufficient pre-merge validation.

## CI gates that run on promotion PRs

Every promotion PR runs the full PR validation suite (per ADR-08). Specifically:

| Gate | ADR | What it checks |
|---|---|---|
| Anonymization | ADR-08 | No company-name leaks across the diff. Especially relevant on promotion PRs because the target file (`gitops/argocd/applicationsets/aegis-statefulset.yaml`) is a public artifact. |
| Helm lint + kubeconform | ADR-08 | Chart still parses + manifests still validate against K8s 1.29 schema. Catches the case where the new SHA includes a manifest that the cluster will reject. |
| Terraform validate + tfsec | ADR-08 | If the promoted SHA touches `infrastructure/terraform/`, plan + security scan run as PR comments. |
| SHA-pin lint | ADR-09 | New `targetRevision` must be a 40-char SHA for staging and prod elements. Branch references (`main`, `release-*`) fail the gate for those elements. |

The SHA-pin lint is implemented as a regex check inside `pr-validation.yml` that scans the ApplicationSet generator block and requires staging + prod elements to match `[a-f0-9]{40}`. Dev is allowed to remain on `main`.

## Future work

- **Templated automated block via Go-template `if/else` over `syncPolicyMode`.** The current ApplicationSet template doesn't render the `automated{}` block per-element; per-env auto-sync is enforced via post-creation patching or via the dedicated `aegis-statefulset-prod.yaml` Application (Wave 1, manual sync). The unified path is `{{- if eq .syncPolicyMode "auto" }} automated: { prune: true, selfHeal: true } {{- end }}` inside the template — straightforward but defers until the per-env split has more than three list elements.
- **Promotion bot.** A bot that opens promotion PRs automatically once soak criteria pass (error budget green, SLO check, smoke test pass). The PR template above is bot-friendly — fields are mechanical. Out of POC scope.
- **Per-env Slack notifications via Argo Notifications.** Promotion PR merge → "Sync started" → "Sync completed" → "Healthy" pings to the platform-team channel. Pairs with ADR-08's out-of-POC list and ADR-08 trade-offs.

## Related

- ADR-08 (GitOps via ArgoCD — sync policy split, manual prod gate)
- ADR-08 (ApplicationSet + PR-based promotion — architectural decision behind this runbook)
- ADR-09 (SHA pinning — staging and prod `targetRevision` MUST be SHA)
- ADR-04 (Recovery paths — data-side rollback when GitOps revert is insufficient)
- ADR-08 / ADR-08 / ADR-08 / ADR-08 (CI gates that run on promotion PRs)
- `gitops/argocd/README.md` (manual sync procedure for prod)
- `docs/gitops/drift-remediation.md` (drift detection + remediation)
