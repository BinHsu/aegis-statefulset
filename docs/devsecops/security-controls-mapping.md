# Security Controls Mapping

This document maps the platform's implemented security controls to the compliance frameworks customers and auditors care about. It exists for two audiences:

1. **The auditor / customer DPO / regulator** asking *"which of your controls satisfy clause X of framework Y?"*. This document is the answer; each row points at the actual implementation artifact (ADR, Helm template, Terraform module, GitHub workflow).
2. **The platform team** building or evolving controls — when a new framework lands (e.g. NIS2 enforcement in 2026, DORA in 2025), the gap is visible by inspection.

The pattern is deliberately **control-centric, not framework-centric**. Each control is implemented once; the mapping rows are projections onto the frameworks that need it. We do not duplicate work to satisfy multiple checklists.

---

## Why control mapping matters

Audit cycles, customer due-diligence questionnaires (CAIQ, SIG, custom RFP appendices), and regulator inquiries all share a common shape: "demonstrate control X, point us at the evidence." Without an explicit mapping, each cycle becomes a re-derivation exercise — engineers reading their own commit history to reconstruct what is implemented and why. With an explicit mapping, the mapping itself is the evidence and the implementation pointer is one click away.

The mapping is also the platform team's own forcing function: a row that says "Implemented? No" with no compensating control is an item for the next quarterly planning round.

---

## Frameworks covered

| Framework | Scope | Why we map |
|---|---|---|
| **SOC 2 Type II** | US-rooted but globally-consumed. Customers' procurement teams ask for it. | Common-denominator request from US enterprise customers; basis of "we have a SOC 2" in sales motion |
| **ISO/IEC 27001:2022** | International ISMS standard | Common-denominator request from German Mittelstand and EU enterprise customers |
| **CIS Kubernetes Benchmark v1.8** | Technical controls baseline for K8s | Operational hardening reference; CIS controls map cleanly to specific Kyverno policies and node configs |
| **NIST CSF 2.0** | Cyber-security functions framework (Govern / Identify / Protect / Detect / Respond / Recover) | High-level posture mapping; useful for board / exec reporting |
| **GDPR Article 32** | EU data protection — security of processing | Mandatory for any system processing EU personal data |
| **NIS2 Directive (EU 2022/2555)** | EU cyber-security baseline for "essential / important entities" | Enforcement transposition through 2024-2026 across member states |
| **DORA (EU 2022/2554)** | EU financial-sector resilience | Applies if customer is a financial entity; influences architecture even if not directly applicable |

---

## Control matrix

Format: `Control` × `Framework reference(s)` × `Implemented?` × `Evidence pointer`.

### Identity, access, and authentication

| Control | SOC 2 | ISO 27001 | NIST CSF | GDPR | Implemented? | Evidence |
|---|---|---|---|---|---|---|
| Pod-level workload identity (no shared secrets to AWS) | CC6.1 | A.5.15, A.8.2 | PR.AA-01 | Art. 32(1)(b) | Yes | `helm/aegis-statefulset/templates/serviceaccount.yaml` (IRSA), ADR-07 |
| Secrets centralised, rotated, never in repo | CC6.1 | A.5.15, A.8.24 | PR.AA-05 | Art. 32(1)(a) | Yes | ADR-07 (Secrets Manager + ESO), `gitops/policies/kyverno/...`, secret scanning workflow |
| Per-tier KMS keys for encryption at rest | CC6.1 | A.8.24 | PR.DS-01 | Art. 32(1)(a) | Yes | ADR-07, `infrastructure/terraform/kms.tf` |
| Cluster-wide network default-deny | CC6.6 | A.8.20, A.8.22 | PR.IR-01 | Art. 32(1)(b) | Yes | ADR-07, `helm/aegis-statefulset/templates/networkpolicy.yaml` |

### Supply chain and image integrity

| Control | SOC 2 | ISO 27001 | NIST CSF | GDPR | Implemented? | Evidence |
|---|---|---|---|---|---|---|
| Image vulnerability scanning at build | CC7.1 | A.8.8, A.8.30 | DE.CM-08 | Art. 32(1)(d) | Yes | ADR-07, `.github/workflows/pr-validation.yml` (Trivy step) |
| Image signing (Cosign keyless) | CC7.1 | A.8.30 | PR.DS-08 | Art. 32(1)(b) | Yes | ADR-07, `.github/workflows/helm-release.yml` |
| Image signature enforced at admission | CC7.1 | A.8.30 | PR.DS-08 | Art. 32(1)(b) | Yes | `gitops/policies/kyverno/supply-chain/image-signature-required.yaml` |
| SLSA L3 build provenance attestation | CC7.1 | A.8.30 | PR.DS-08 | — | Yes | ADR-09, `.github/workflows/sbom-attestation.yml` |
| CycloneDX SBOM published per artifact | CC7.1 | A.8.8 | ID.SC-04 | — | Yes | ADR-09, `.github/workflows/sbom-attestation.yml` |
| SBOM verified at admission | CC7.1 | A.8.8 | ID.SC-04 | — | Audit mode (Enforce after 14d green) | `gitops/policies/kyverno/supply-chain/sbom-required.yaml` |
| Third-party action SHA pinning | CC7.1 | A.8.30 | PR.DS-08 | — | Yes | ADR-09, all workflows in `.github/workflows/` |
| Secret scanning in repo | CC6.1 | A.5.15 | PR.DS-01 | Art. 32(1)(a) | Yes | `.github/workflows/secret-scanning.yml` |

### Pod security and runtime

| Control | SOC 2 | ISO 27001 | CIS K8s | NIST CSF | Implemented? | Evidence |
|---|---|---|---|---|---|---|
| Pod Security Standards "restricted" baseline | CC6.6 | A.8.22 | 5.2.x | PR.PS-01 | Yes | ADR-07, namespace label on `aegis-app` |
| Disallow privileged containers (Kyverno) | CC6.6 | A.8.22 | 5.2.1, 5.2.5 | PR.PS-01 | Yes | `gitops/policies/kyverno/supply-chain/disallow-privileged.yaml` |
| Disallow `:latest` tag | CC7.1 | A.8.30 | 5.1.4 | PR.DS-08 | Yes | `gitops/policies/kyverno/cluster-policies/disallow-latest-tag.yaml` |
| readOnlyRootFilesystem enforced | CC6.6 | A.8.22 | 5.2.6 | PR.PS-01 | Yes | ADR-07 (Kyverno require-readonly-root-fs) |
| runAsNonRoot enforced | CC6.6 | A.8.22 | 5.2.5 | PR.PS-01 | Yes | ADR-07 (Kyverno require-runasnonroot) |
| Runtime threat detection (eBPF) | CC7.2 | A.8.16 | — | DE.CM-01, DE.CM-09 | Yes | ADR-07, `gitops/runtime-security/falco-rules.yaml`, `tetragon-tracing-policies.yaml` |

### Audit logging and SIEM

| Control | SOC 2 | ISO 27001 | NIST CSF | GDPR | Implemented? | Evidence |
|---|---|---|---|---|---|---|
| K8s API audit logging | CC7.2 | A.8.15 | DE.CM-09 | Art. 32(1)(b) | Yes | EKS audit log -> CloudWatch Logs (ADR-07) |
| AWS API audit logging (CloudTrail) | CC7.2 | A.8.15 | DE.CM-09 | Art. 32(1)(b) | Yes | `infrastructure/terraform/cloudtrail.tf` |
| Audit log integrity validation | CC7.2 | A.8.15 | PR.DS-06 | Art. 32(1)(b) | Yes | CloudTrail `enable_log_file_validation = true` |
| Audit log tamper-protected storage | CC7.2 | A.8.15 | PR.DS-06 | Art. 32(1)(b) | Yes | S3 Object Lock COMPLIANCE-mode 7y, ADR-07 |
| Centralised SIEM aggregation | CC7.2 | A.8.16 | DE.AE-03 | Art. 32(1)(b) | Yes | ADR-07 (Wazuh + GuardDuty) |
| Audit log retention 7y | CC7.2 | A.8.15 | DE.CM-09 | Art. 32(2) | Yes | S3 Object Lock retention=2555d, ADR-07 |
| Network flow logs (rejected only — cost-tier) | CC7.2 | A.8.16 | DE.CM-01 | Art. 32(1)(b) | Yes | VPC Flow Logs config, ADR-07 |

### Backup, recovery, resilience

| Control | SOC 2 | ISO 27001 | NIST CSF | GDPR | Implemented? | Evidence |
|---|---|---|---|---|---|---|
| Automated periodic backup | A1.2, CC9.2 | A.8.13 | RC.RP-03 | Art. 32(1)(c) | Yes | ADR-04 (1h cadence default), backup pipeline |
| DR runbook + recovery paths documented | CC9.2 | A.5.30 | RC.RP-04 | Art. 32(1)(c) | Yes | ADR-04 (three recovery paths) |
| DR drills (periodic, automated) | CC9.2 | A.5.30 | RC.RP-04 | Art. 32(1)(d) | Yes | `.github/workflows/dr-drill.yml` |
| Backup encryption at rest | CC6.1 | A.8.24 | PR.DS-01 | Art. 32(1)(a) | Yes | ADR-07 (kms-backup), S3 SSE-KMS |
| Backup tamper protection | CC9.2 | A.8.13 | PR.DS-06 | Art. 32(1)(c) | Yes | S3 Object Lock on cold tier |

---

## High-priority CIS Kubernetes Benchmark controls

Full benchmark scan runs weekly via `.github/workflows/cis-benchmark.yml`. The high-priority controls are tracked here as the policy evolves.

| CIS ID | Title | Implementation |
|---|---|---|
| 1.1.x | Master node configuration files | EKS-managed control plane — AWS attestation (Stage 3 conversation: integrate AWS EKS CIS attestation into compliance dashboard) |
| 4.1.1 | kubelet authentication | EKS launch template config — node-groups-stateful.tf |
| 4.2.1 | Anonymous-auth disabled on kubelet | Default in EKS-managed AMI |
| 5.1.1 | Cluster-admin role minimised | RBAC review per ADR-07 (read-only by default; role-based escalation only) |
| 5.1.4 | Image tags pinned (not :latest) | `gitops/policies/kyverno/cluster-policies/disallow-latest-tag.yaml` |
| 5.2.1 | Privileged containers minimised | `gitops/policies/kyverno/supply-chain/disallow-privileged.yaml` |
| 5.2.5 | Privilege escalation disallowed | ADR-07 (PSS restricted) + Kyverno disallow-privileged.yaml |
| 5.2.6 | Root filesystem read-only | ADR-07 (Kyverno require-readonly-root-fs) |
| 5.3.x | NetworkPolicy in use across namespaces | ADR-07, default-deny + targeted allow-rules |
| 5.7.x | Container image vulnerability scanning | ADR-07 (Trivy in CI), `pr-validation.yml` |

---

## GDPR Article 32 — security of processing

| Article | Requirement | Implementation |
|---|---|---|
| Art. 32(1)(a) | Pseudonymisation and encryption of personal data | Per-tier KMS encryption at rest (ADR-07); TLS in transit (ADR-07); secrets centralised (ADR-07) |
| Art. 32(1)(b) | Confidentiality, integrity, availability, resilience | NetworkPolicy zero-trust (ADR-07), audit log integrity (ADR-07), HA active-passive (ADR-04), runtime detection (ADR-07) |
| Art. 32(1)(c) | Restore availability after incident | Backup cadence (ADR-04), three recovery paths (ADR-04), DR drills (ADR-04 + dr-drill.yml) |
| Art. 32(1)(d) | Regular testing of effectiveness | DR drills, CIS benchmark scans, DAST scans, SBOM verification — all automated and scheduled |
| Art. 32(2) | Risk-appropriate measure of security | This document + threat model (`threat-model.md`); risk register evolves with threat landscape |

---

## NIS2 / DORA readiness

NIS2 (EU 2022/2555) and DORA (EU 2022/2554) are the EU's converging cyber-resilience baselines. Most concrete obligations overlap with SOC 2 / ISO 27001 / GDPR Art. 32 — but two NIS2/DORA-specific requirements are worth surfacing:

### NIS2 Article 23 — incident reporting

NIS2 imposes specific incident-reporting timelines:

- **24 hours** — early warning to the competent authority
- **72 hours** — incident notification with severity assessment
- **1 month** — final report

Implication for this platform: incident-classification automation must be **fast enough to support 24h timelines**. Wazuh detection latency (ADR-07) is sub-minute; the bottleneck is human triage. Operational requirement, not architectural — but the architecture must not introduce latency (e.g., audit log not yet ingested).

### DORA — supply-chain due diligence

DORA Article 28 imposes due diligence obligations on the supply chain of financial entities. For platform vendors, this translates to: provide SBOMs to financial-sector customers; disclose the upstream dependency surface; report material vulnerabilities affecting the customer.

Implementation: ADR-09 publishes CycloneDX SBOMs as standard artefacts. Customer can ingest into their dependency-track / Anchore / Xray for ongoing monitoring. The CRA (Cyber Resilience Act) makes this universal across EU "products with digital elements" by ~2027.

---

## Continuous compliance

This is not a "scan once, file the report" posture. Compliance evidence is generated continuously:

| Mechanism | Cadence | What it produces |
|---|---|---|
| `pr-validation.yml` (Trivy + kubeconform + tflint + tfsec + anonymization gate) | Every PR | Build-time gate; failures block merge |
| `cis-benchmark.yml` | Weekly | CIS findings report; FAIL items auto-open issues |
| `dast.yml` (OWASP ZAP baseline) | Weekly | DAST findings report |
| `secret-scanning.yml` (gitleaks + trufflehog) | Every PR + daily | Verified-secret detection |
| `dr-drill.yml` | Quarterly | DR recovery path validation |
| `sbom-attestation.yml` | Every release | SBOM + SLSA L3 provenance per release |
| AWS Config rules | Continuous | Configuration drift detection |
| GuardDuty | Continuous | AWS-layer threat detection (ADR-07) |
| Falco / Tetragon | Continuous | Runtime detection (ADR-07) |

Drift between expected control state and actual control state is itself a finding — surfaced via the same SIEM pipeline.
