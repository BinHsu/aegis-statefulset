# ADR-09: Supply chain — SHA pinning, SLSA L3, SBOM provenance

## Status
Accepted (POC submission scope)

## Decision

1. **Every external image referenced as `repo:tag@sha256:digest`.** No floating tags. No `latest`. Renovate refreshes tags weekly via PR; humans approve.
2. **Supply-chain Levels for Software Artifacts (SLSA) L3 build provenance.** Build runs in GitHub Actions on isolated, ephemeral runners. Provenance attestation generated at build time and pushed to the Rekor transparency log.
3. **CycloneDX Software Bill of Materials (SBOM) per release.** Generated at build time, signed via Cosign keyless OIDC, attached to the image as an attestation.
4. **Trivy scan + Cosign signature verification at admission time.** Kyverno cluster policy denies images that fail either check (ADR-07).
5. **Renovate auto-merge for non-breaking patch updates** (security CVE fixes); manual approval for minor and major bumps.
6. **GHA action SHA-pinning** (parallel to image-SHA-pinning above). Every `uses:` reference in `.github/workflows/*.yml` pins to a 40-char commit SHA; `.gitleaks.toml` allowlists `uses: owner/action@<sha40>` so the SHAs themselves don't false-positive on entropy detection. Renovate refreshes via weekly PR.
7. **Defense in depth — external scanner layer** (the meta-trust layer). The in-repo CI defenses (Trivy / gitleaks / trufflehog / Kyverno / `.gitleaks.toml`) can be neutralised by a malicious PR that modifies them. Mitigation: enable GitHub-native secret scanning (Settings → Code security → Secret scanning, zero-config, free for public repos) and Dependabot security alerts — both run OUTSIDE the repo's CI surface and CANNOT be disabled by a PR. CODEOWNERS routes all security-config changes to the security owner; branch protection (per `docs/operations/branch-protection.md`) enforces CODEOWNER approval before merge. The three layers (in-repo CI / CODEOWNERS+branch-protection / GitHub-native+Dependabot) compose: an attacker would need to compromise GitHub's account-level controls AND get CODEOWNER approval AND disable native scanning to fully bypass.

## Why

- **SHA pinning is the cheapest single defense against supply-chain swap attacks.** Five lines of YAML buy "the image you reviewed is the image that runs."
- **SLSA L3 + Rekor is the audit-grade chain of custody.** ISO 27001 / SOC 2 / NIST Secure Software Development Framework (SSDF) all want a machine-readable answer to "what was built, by whom, from what source." SLSA L3 gives that.
- **SBOM is the only sustainable answer to "is your supply chain affected by CVE-XXXX-YYYY".** Without SBOM, every CVE disclosure is a triage scramble; with SBOM, it's a query.
- **Cosign keyless OIDC removes the signing-key custody problem.** No long-lived signing key in an HSM; identity comes from the GitHub OIDC token at build time.
- **In-repo defenses are self-policing and therefore insufficient on their own.** `.gitleaks.toml` allowlist, `.github/workflows/secret-scanning.yml`, Kyverno policies — every one of these is a repo file. A malicious PR can modify them. The branch-protection + CODEOWNER review layer closes that gap inside the repo; the GitHub-native scanner layer closes it OUTSIDE the repo. Both are needed; either alone has a structural blind spot.

## Trade-offs accepted

- **Build pipeline is materially more complex.** Build → SBOM → Sign → Attest is 4 stages instead of 1. Worth it for the audit story.
- **Cosign keyless attestations land in the public Rekor log.** Fine for POC mock images; production sensitive images may want a private Rekor instance (separate ADR-sized decision).
- **Renovate PR noise.** Weekly digest refresh = many small PRs. Mitigated by auto-merge for patch + grouped PRs by component.

## Out of POC scope (upgrade triggers)

- **Private Rekor / private Sigstore.** Trigger: image content sensitive enough that public attestations leak business intelligence.
- **Reproducible builds (SLSA L4).** Trigger: regulator demands bit-for-bit identical artefacts on rebuild.

## Stage 3 questions

- Image registry choice (ECR / Harbor / Artifactory). Affects exactly which Cosign verification flow.
- Existing SBOM convention (CycloneDX vs SPDX vs proprietary). Mostly equivalent for ingestion.
- Renovate rules tuning per the customer's risk appetite.

## Cross-references

- *(originally split across private ADR-039 + ADR-042; consolidated 2026-05-09)*
- ADR-07 — security: Kyverno admission policy enforces signature + scan
- ADR-08 — CI/CD: build pipeline is where provenance is generated; CODEOWNERS routes security-file changes for explicit review
- [`docs/operations/branch-protection.md`](../operations/branch-protection.md) — declarative description of GitHub branch protection rules (the gap-closer for CODEOWNERS); also names what GitHub-native scanners and external services (Dependabot) to enable.
- [`.github/CODEOWNERS`](../../.github/CODEOWNERS) — paths requiring CODEOWNER approval; includes `.gitleaks.toml`, `.github/workflows/`, security-critical scripts.
- [`.gitleaks.toml`](../../.gitleaks.toml) — repo-specific gitleaks allowlist; CODEOWNER-protected.
