# Runbook 05 — Submission email to Sebastian Weikart

**Goal:** Compose and send the submission email with the right
attachments + repo link + chaos-demo evidence.

**Time:** ~10 min (after Runbooks 01–04 are done)  
**Cost:** —  
**Trust boundary:** Bin owns the email account and the recruiter
relationship; Claude drafts the body.

---

## 0. Prerequisites

- [ ] Runbook 01 done — image pushed, digests in `values.yaml`
- [ ] Runbook 02 done — chaos demo executed, `chaos-evidence/` populated
- [ ] Runbook 03 done — CI workflows green on main branch
- [ ] Runbook 04 done — Grafana dashboards screenshotted
- [ ] `docs/SUBMISSION.pdf` rendered (Claude already produced this)
- [ ] Repo committed + pushed to GitHub (verify with `gh repo view`)
- [ ] Sebastian's email address on hand (from earlier Stage 2 invitation
      thread)

---

## 1. Decide attachment vs link strategy

| Approach | When to use | Effort |
|---|---|---|
| **Public GitHub repo + SUBMISSION.pdf** | If repo is anonymised cleanly and OK to be public | Low — just paste link |
| **Private GitHub repo + grant collaborator access** | If you want gating but no zip | Medium — invite Sebastian by GH handle (he'll send) |
| **Zip + email attachment** | If GitHub is off-table | High — exclude `.git`, `node_modules`, `terraform.tfstate` |

**Recommended:** Public GitHub repo. The architecture is anonymised
(ADR-08 anonymisation gate green); making it public costs nothing and
gives Sebastian a proper code-review surface. Mention it's a
personal-portfolio version, not a production-ready deliverable.

---

## 2. Pre-flight checks before sending

```bash
# (a) Repo on GitHub, main is up to date
git status                 # expect: clean
git log -1 --oneline       # expect: latest Wave 4 commit
gh repo view --web         # opens browser to verify public visibility

# (b) Anonymisation gate is clean
./scripts/git-hooks/pre-commit
# expect: zero brand-name word-boundary leaks

# (c) helm lint + terraform fmt
helm lint helm/aegis-statefulset/
terraform -chdir=infrastructure/terraform fmt -check -recursive
# expect: both green

# (d) docs/SUBMISSION.pdf exists
ls -la docs/SUBMISSION.pdf
# expect: a recent PDF, ~200-400 KB
```

If any of these fail, stop. Fix first.

---

## 3. Email body draft

**Subject:**

```
Aegis-StatefulSet take-home submission — Pin-Feng (Bin) Hsu
```

**Body (paste-ready, replace placeholders):**

```
Hi Sebastian,

Attached is my submission for the stateful Kubernetes take-home — a
reference architecture for hosting LevelDB-backed stateful applications
on single-master-AZ EKS with cold DR via Velero.

Submission pack:
  • Repo (public, anonymised): https://github.com/<OWNER>/aegis-statefulset
  • SUBMISSION.pdf (attached) — one-page architecture summary +
    10-ADR index + cost breakdown
  • Chaos demo evidence — screenshots/recordings inline below

What I'd flag for the conversation:

  1. The submission's § 0 section grounds every architectural choice
     against your published commitments — 99.5% uptime SLA on Team and
     Business plans, daily automatic backup as the implicit RPO baseline.
     The 5-minute cadence default delivers about 480× tighter RPO than
     the current public commitment; the over-delivery is deliberate to
     expose the cost-RPO curve, not just hit the spec's 6-hour ceiling.
     Stage 3 conversation should establish your aspirational SLA target
     so the operator picks the right cadence given actual operational
     tolerance.

  2. The architecture deliberately decouples three concerns that are
     often conflated in stateful K8s discussions: capacity expansion
     (ADR-01), per-tenant relocation (ADR-01), and DR failover
     (ADR-04). Each has a distinct runbook and SLI.

  3. I picked cold DR (Velero + EBS Snapshot) over multi-region
     active-passive after working through the trade-off three times.
     Reasoning is in docs/operations/why-cold-dr.md — short version:
     LevelDB has zero native sync APIs, so any "warm" replica is a
     snapshot copy. The cost delta (~€1,500/month) buys ~40 minutes of
     RTO. The spec is silent on RTO; I set the architecture's target at
     ~25 min AZ failure / ~50 min region as a Mittelstand-grade design
     judgment. I'd want to validate this RTO target against your team's
     actual operational tolerance — if it's tighter than 25 min, the
     trade-off shape changes; if it's looser, even Restic-grade restore
     becomes acceptable. The architecture supports either posture via
     the values.yaml lever.

  4. You mentioned in our first call that observability is a topic the
     team wants to improve. ADR-06 is one of the heavier sections in the
     submission for that reason — OpenTelemetry first-day instrumentation,
     eight dashboards, a ninety-second debug-path target, tiered alerting
     with hysteresis. If observability is the layer you want to dig into
     during the technical interview, that's where I have the most receipts
     to share.

  5. Two questions where I'd want a Stage 3 conversation rather than
     pre-deciding:
       • LDB layout — Pattern 1 (shared LDB with key prefix) vs Pattern
         2 (per-tenant folder). Capability matrix in ADR-04. The POC
         mock uses Pattern 2 for clean chaos demo; production usually
         runs Pattern 1.
       • Per-tenant pod model — confirm legacy is per-tenant rather
         than hash-sharded. The migration path in ADR-05 assumes per-
         tenant, which matches LevelDB physics; sharded would be a
         different conversation.

The implementation is skeletal by design — the submission covers
structural depth (10 thematic ADRs (originally split across 50 private predecessors), FinOps + GitOps +
DevSecOps three-pillar discipline) over surface coverage. The chaos
demo evidence is the receipt that the architecture actually stands up.

Practical bits:
  • I'm based in Berlin with a Germany Opportunity Card (Chancenkarte);
    Anmeldung complete. Routine Blue Card conversion on offer signing,
    typically 2–4 weeks.
  • Available for a Stage 3 conversation any weekday 09:00–13:00 CET
    or 15:30–18:00 CET (I keep 14:00–14:30 for a daily family video
    call with my wife and daughter in Taiwan).
  • Portfolio: https://binhsu.org

Happy to walk through any of the architecture decisions or run the
chaos demo live.

Thanks,
Pin-Feng (Bin) Hsu
```

---

## 4. Adapt the body before sending

Three things to verify before pressing send:

| Field | What to check |
|---|---|
| `<OWNER>` in repo URL | Replace with your actual GitHub username/org |
| Time-zone availability | Adjust if you have known calendar conflicts that week |
| Portfolio link | Confirm `binhsu.org` is reachable and recent |
| Greeting | "Hi Sebastian" is right per Stage 2 invitation tone (verify in original thread; if formal, switch to "Dear Sebastian") |

**Tone calibration check (from canonical-tone Redcare prep doc):**
- Quiet confidence over bravado ✓
- Evidence-based, not pitch-based ✓ (each claim has an ADR # or doc link)
- No solo-hero framing ✓ ("drove the design", not "single-handedly built")
- No "10% coding" — but coding percentage doesn't naturally come up here

---

## 5. Attachments

| File | Path |
|---|---|
| `SUBMISSION.pdf` | `docs/SUBMISSION.pdf` |

**Don't attach:**
- Terraform state — sensitive
- `chaos-evidence/` zip — too large for email; link to repo instead, or
  upload to a public Drive folder and link
- `_context/` private ADRs — anonymised public versions are in `docs/adr/`

**If you go the zip route instead of GitHub link:**

```bash
git archive --format=zip --output=aegis-statefulset.zip HEAD \
  -- $(git ls-files | grep -v -E '^(_context|terraform\.tfstate|chaos-evidence)')
ls -lh aegis-statefulset.zip   # expect < 5 MB
```

---

## 6. Send

Use the email account you've been using for the customer thread (so the
mail threads correctly). Reply to the most recent Sebastian message
rather than starting a new thread.

**Click send time consideration:** Tuesday–Thursday 09:00–11:00 CET
lands well in HR inboxes. Avoid Friday afternoon (sits over weekend);
avoid Monday morning (drowned in catch-up email). If you finish demo
on a Sunday, send Tuesday 09:30 CET.

---

## 7. Post-send tracking

```bash
# Log the send to applications/customer/<role>/README.md
echo "$(date +%Y-%m-%d) — Stage 2 take-home submitted via email to Sebastian Weikart" \
  >> /Users/bin.hsu/Documents/2026Job/applications/customer/<role>/README.md
```

Per the `feedback_wait_for_written_confirmation` memory: do **not**
start Stage 3 prep until you receive an explicit written acknowledgement
from Sebastian. Verbal "looks great, expect to hear from us" doesn't
count.

---

## 8. Failure modes

| Symptom | Fix |
|---|---|
| Repo link 404 from Sebastian | Repo private — invite him as collaborator, or make public |
| PDF attachment rejected (size cap) | Compress: `gs -sDEVICE=pdfwrite -dPDFSETTINGS=/prepress -o SUBMISSION-compressed.pdf SUBMISSION.pdf` |
| GitHub Actions failing on the public repo | Set `AWS_ROLE_ARN` repo variable per Runbook 03; confirm `terraform-plan.yml` runs |
| Anonymisation gate flags a hit | Re-run `./scripts/git-hooks/pre-commit`; fix and re-commit before public push |
| Sebastian replies asking for Stage 3 scheduling | Acknowledge; do NOT start prep until time slot is in writing (memory: `feedback_wait_for_written_confirmation`) |

---

## 9. Tie-back to project context

This runbook closes Wave 4 of the aegis-statefulset POC submission.
After send:
- Memory `project_session_state_0507_EOD` may need to be updated to
  reflect Wave 4 + submission complete
- Memory `project_relocation_stop_loss_timeline` — submission is one
  data-point along the 2026-08-15 stop-loss / 2026-09-25 cutoff curve

---

## 10. Done criteria

- [ ] All Runbook 01–04 done criteria green
- [ ] Pre-flight checks (Step 2) all green
- [ ] Email body adapted (placeholders replaced, tone reviewed)
- [ ] PDF attached, < 5 MB
- [ ] Repo public + anonymisation clean (or zip < 5 MB if going that route)
- [ ] Send-time picked thoughtfully (Tue–Thu 09:00–11:00 CET preferred)
- [ ] applications/customer/<role>/README.md log line appended
