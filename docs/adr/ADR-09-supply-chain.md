# ADR-09: Supply chain — SHA pinning, SLSA L3, SBOM provenance

## Status
Accepted (POC submission scope)

## Decision

1. **Every external image referenced as `repo:tag@sha256:digest`.** No floating tags. No `latest`. Renovate refreshes tags weekly via PR; humans approve.
2. **Supply-chain Levels for Software Artifacts (SLSA) L3 build provenance.** Build runs in GitHub Actions on isolated, ephemeral runners. Provenance attestation generated at build time and pushed to the Rekor transparency log.
3. **CycloneDX Software Bill of Materials (SBOM) per release.** Generated at build time, signed via Cosign keyless OIDC, attached to the image as an attestation.
4. **Trivy scan + Cosign signature verification at admission time.** Kyverno cluster policy denies images that fail either check (ADR-07).
5. **Renovate auto-merge for non-breaking patch updates** (security CVE fixes); manual approval for minor and major bumps.

## Why

- **SHA pinning is the cheapest single defense against supply-chain swap attacks.** Five lines of YAML buy "the image you reviewed is the image that runs."
- **SLSA L3 + Rekor is the audit-grade chain of custody.** ISO 27001 / SOC 2 / NIST Secure Software Development Framework (SSDF) all want a machine-readable answer to "what was built, by whom, from what source." SLSA L3 gives that.
- **SBOM is the only sustainable answer to "is your supply chain affected by CVE-XXXX-YYYY".** Without SBOM, every CVE disclosure is a triage scramble; with SBOM, it's a query.
- **Cosign keyless OIDC removes the signing-key custody problem.** No long-lived signing key in an HSM; identity comes from the GitHub OIDC token at build time.

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
- ADR-08 — CI/CD: build pipeline is where provenance is generated
