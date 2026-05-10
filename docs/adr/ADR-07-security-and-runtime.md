# ADR-07 — Security & Runtime: Defense in Depth From Edge to Audit

## Status

Proposed (POC submission scope; subject to confirmation in Stage 3 conversation).

## Thesis

Security on this stateful platform is not a single control — it is a deliberately layered argument that no single failure can compromise the customer's data. Each layer mitigates a named threat the layer above cannot see; each is mapped to a recognised standard so an auditor can read the architecture without our help. The unified posture is defense in depth from the AWS edge inward, anchored by per-tier KMS isolation and a tamper-evident audit trail that survives the platform itself.

## Context

The platform runs a per-tenant stateful tier holding customer data. Following the design's `P1` principle — "EBS is treasure" — customer data on EBS is the only asset whose loss the platform cannot recover from. Every other component (cluster, nodes, control plane, even the AWS account itself) is recoverable; tenant data is not. The security architecture is calibrated against that asymmetry.

**Threat model framing.** We do not pretend pod compromise is hypothetical. Known CVEs in the stateful workload, supply-chain attacks against base images, leaked operator kubeconfigs, exploited zero-days in application code — any of these eventually produces a compromised pod. The security question is not "can we prevent compromise?" but "given a compromise, what is the blast radius, and what evidence will the auditor have?" Default Kubernetes networking is open: a compromised pod reaches every other pod, every service, every AWS endpoint the node can reach. Default `kubectl apply` permits `privileged: true` + `hostPath: /` — a one-step path from cluster credential to node host. Default Secrets are base64-encoded in etcd. Default AWS-managed KMS shares one key across every encrypted resource. Each default sets the blast radius to "the entire system." Every decision below pulls one such default tighter.

**Blast-radius framing.** Three concentric perimeters define the architecture. The outermost is the AWS edge — the public-internet boundary. The middle is the cluster — the L4/L7 surface where pods, services, and admission controllers operate. The innermost is the host — the kernel and the EBS volume on which customer LevelDB data lives. Each perimeter has a primary control (TLS termination, NetworkPolicy + admission, eBPF runtime detection) and a complementary audit channel (ALB access logs, EKS audit, kernel-level event capture). The argument is not that any single layer is sufficient; it is that an attacker who breaches one layer is observed by the next, and the audit trail survives even an attacker who compromises the SIEM itself.

**Topology constraints that the security design must respect.** The platform runs workloads concentrated in a single master AZ at any moment — standby AZs hold node groups at `desiredSize=0` until a rotation event. The security architecture must not assume multi-AZ runtime presence; controls that depend on cross-AZ workload distribution (e.g. quorum-based admission, multi-AZ Wazuh manager) are designed around master-AZ-only execution with standby capacity. Disaster recovery is cold (Velero) rather than hot, so backup-pipeline security — KMS isolation of the BSL, audit logging of every backup object — covers a code path that runs once per backup window rather than continuously. Production deployment is manual-sync GitOps, not auto-sync; security gating fires at PR / merge time (Trivy, Cosign, Kyverno admission) rather than at runtime promotion, which means the supply-chain controls have to be the binding policy, not a deploy-time afterthought.

**ISO 27001 mapping.** The control surfaces touched here map to ISO 27001:2022 Annex A controls including A.5.15 (Access control), A.8.9 (Configuration management), A.8.15 (Logging), A.8.16 (Monitoring activities), A.8.23 (Web filtering), A.8.24 (Cryptography), A.8.28 (Secure coding), and A.13 (Communications security). Where an individual decision below names a more specific standard (NIST SP 800-57, CIS Kubernetes Benchmark v1.8+, MITRE ATT&CK for Containers, SLSA Levels, NIST SSDF, OWASP LLM Top 10) we cite it inline with the threat it addresses. **Citation accuracy disclaimer:** these standard references signal the *category* of control each decision implements; the architecture's audit-readiness depends on the customer's actual auditor walking each citation against their interpretation of the specific control. The submission does not warrant that every citation maps to a given auditor's preferred control number 1:1 — verify against your own audit framework before relying on any specific mapping.

## Decisions

### 1. The defense-in-depth premise — why no single layer is sufficient

The entire architecture below rests on one claim: any single control will eventually fail or be bypassed, and the system's correctness depends on the next control catching what the previous one missed. Edge TLS protects ciphertext on the wire but not what an authenticated client does after the handshake. NetworkPolicy contains a compromised pod's lateral reach but not the syscalls the pod issues to the host kernel. Pod Security Standards forbid privileged containers but not what a non-privileged container does within its allowed surface. Image signing verifies provenance at admission but not what the image does once it runs. Each layer is necessary but none is sufficient. The right question for every decision is: *what threat does this layer name, and what threat does it leave for the next layer to handle?* That framing — explicit handoff between layers — is what we mean by defense in depth, and it is what an experienced security reviewer reads first.

### 2. Edge layer — TLS termination at ALB (ACM-managed) with Caddy as documented alternative

**Threat addressed:** passive on-path interception of customer data in transit; cipher-suite downgrade; certificate mis-issuance.
**Standard:** ISO 27001 A.13.1 (Network controls), A.8.24 (Cryptography); TLS 1.2+ baseline per common audit baselines.

The platform terminates TLS at the AWS ALB using AWS Certificate Manager (ACM) certificates as the default path. ACM provisions and rotates certificates transparently — auto-renewal fires 60 days before expiry, no key material lands in the cluster, no manual rotation runbook is needed. The ALB is configured to `ELBSecurityPolicy-TLS13-1-2-2021-06`: TLS 1.2 minimum, TLS 1.3 preferred, RC4 / SSLv3 / weak ciphers explicitly excluded by the named policy rather than by hand. HSTS is enforced at the application layer behind the ALB — the ALB itself does not inject HSTS headers, so the application is the binding source.

**Caddy is named as a documented alternative for non-AWS edges.** Where the platform is deployed in a hybrid topology — on-prem appliance, customer-side demo environment, edge node where Route 53 DNS-01 validation is unavailable — Caddy with Let's Encrypt (or ZeroSSL) ACME provides the same auto-renewal property in a single binary:

```caddy
# Caddyfile sketch — on-prem edge
example-tenant.app.local {
    tls customer-ops@example.com   # ACME via Let's Encrypt
    reverse_proxy upstream-host:8080
    encode gzip
    log {
        output file /var/log/caddy/access.log
    }
}
```

The decision rule is unambiguous: if TLS terminates inside AWS, ACM + ALB; if TLS terminates outside AWS, Caddy. Mixing them in the same edge is rejected — the operational complexity of two TLS endpoints inside one perimeter is not worth the marginal coverage. The reason Caddy is the right choice for the non-AWS path rather than nginx + certbot is the same operational argument that makes ACM right for the AWS path: bundled auto-renewal, sane TLS defaults, no manual cipher tuning, single binary deployable as a Packer-built AMI or a Debian package. Nginx + certbot is the comparable pattern but requires more glue, and the glue is exactly the kind of thing that breaks silently when nobody is watching it.

**What this layer does *not* claim.** It does not protect against an authenticated client behaving maliciously, against a compromised application within the perimeter, or against an attacker who has already obtained a valid session. Those are downstream layers. Cluster-internal mTLS is named as an explicit upgrade trigger when the threat model demands zero-trust at internal hops — it is a service-mesh-sized decision not folded into the edge layer.

### 3. Network layer — default-deny NetworkPolicy with a 3-tier flow model

**Threat addressed:** lateral movement from a compromised pod; unconstrained egress to attacker-controlled C2 endpoints; cross-namespace pivot.
**Standard:** ISO 27001 A.13.1 (Network controls), zero-trust segmentation; CIS Kubernetes Benchmark v1.8 §5 (Policies).

We adopt **default-deny NetworkPolicy** across all application namespaces — `app` (stateful tier), `api-tier` (stateless API), and `envoy` (request router) — with explicit allows organised around the actual request-flow topology:

```
ALB (public ENI) → api-tier (stateless API) → envoy (router) → app (StatefulSet)
```

Each tier lives in its own namespace and gets its own NetworkPolicy. Default-deny is the namespace-level baseline:

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: app           # repeat for api-tier, envoy
spec:
  podSelector: {}
  policyTypes: [Ingress, Egress]
```

On top of that baseline, the explicit allow rules walk the 3-tier flow:

- **`api-tier` ingress** — from the VPC public-subnet CIDR (the ALB's ENIs); from the Prometheus scrape endpoint in `monitoring`.
- **`api-tier` egress** — to the `envoy` namespace; to kube-dns (UDP/TCP 53); to kube-apiserver (sidecar / controller hooks).
- **`envoy` ingress** — from `api-tier`; from Prometheus.
- **`envoy` egress** — to the `app` namespace (route to StatefulSet pod); to the DynamoDB Gateway Endpoint (placement-table lookup); to kube-dns; to kube-apiserver.
- **`app` ingress** — from `envoy` (data-plane request path); from Prometheus; from the Velero namespace (backup hooks).
- **`app` egress** — to the S3 Gateway Endpoint (Velero backup metadata; EBS Snapshot operations indirectly via the CSI driver); to kube-dns; to kube-apiserver.

Anything else — public internet, other AWS services, other namespaces — is denied. Exceptions are added explicitly with an inline comment justifying the flow.

We deliberately use **the native Kubernetes NetworkPolicy resource** rather than introducing a Cilium- or Calico-Enterprise-level identity-aware policy engine. The CNI (AWS VPC CNI with NetworkPolicy enabled, or Calico-as-CNI selected at cluster bootstrap) enforces L3/L4 policy at the data plane. L7 / identity-based policy is named as an upgrade trigger — when the attacker model includes intra-cluster lateral movement at HTTP method or path level, or when compliance demands mTLS everywhere, the upgrade to Cilium or to a service mesh becomes architecturally justified. At POC scope the L4 policy already removes the dominant blast-radius gift, and we are not paying CNI swap cost for a marginal gain.

The NetworkPolicy story is also the cheapest defense-in-depth slot in the system. A few tens of lines of YAML, version-controlled in Helm, render the answer to "what stops a compromised pod from reaching the database?" into a one-sentence reply with a YAML reference. That is the audit story the cost-benefit ratio is built on.

### 4. Pod runtime layer — Pod Security Standards `restricted` + Kyverno enforcement

**Threat addressed:** privileged-container escape, host-namespace pivot, root-process escalation, "deploy a malicious image from a random registry."
**Standard:** CIS Kubernetes Benchmark v1.8 §5 (Policies); ISO 27001 A.8.9 (Configuration management); MITRE ATT&CK for Containers TA0004 (Privilege Escalation), T1611 (Escape to Host).

Admission policy is layered into two tiers. The first is the built-in **Pod Security Standards (PSS) "restricted" profile**, applied as a namespace label on every namespace running tenant data:

```yaml
metadata:
  labels:
    pod-security.kubernetes.io/enforce: restricted
    pod-security.kubernetes.io/audit: restricted
    pod-security.kubernetes.io/warn: restricted
```

This blocks the obvious escape primitives at admission time without any third-party engine: `privileged: true`, `hostPath`, `hostNetwork`, `hostPID`, `hostIPC`, root processes without explicit override, dangerous capabilities (`SYS_ADMIN`, `NET_ADMIN`, etc.), and `procMount: Unmasked`. It is the K8s-version-aligned baseline that catches most of the realistically attempted escalation paths.

The second tier is **Kyverno** for the rules PSS does not cover. Representative policy set:

```yaml
# require-resource-limits          — every pod declares CPU + memory limits
# require-readonly-root-fs         — securityContext.readOnlyRootFilesystem: true
# require-runasnonroot             — securityContext.runAsNonRoot: true
# require-trusted-image-registry   — image must come from <account>.dkr.ecr.<region>.amazonaws.com
# require-image-signature          — image must be Cosign-signed (§5)
# block-default-service-account    — pods must use a named ServiceAccount, not "default"
# require-network-policy-coverage  — namespace must have at least one default-deny NetworkPolicy
```

Each of these closes a specific gap PSS leaves open. Required CPU/memory limits is the answer to noisy-neighbour OOM attacks — a pod without a memory limit can OOM-kill the node. `readOnlyRootFilesystem: true` makes malware persistence harder because an attacker on a compromised pod cannot write to `/usr/bin` or drop binaries onto the root filesystem; legitimate scratch space lives in writable `emptyDir` volumes. Trusted-registry policy combined with image signing (§5) enforces "only images we built and signed run in this cluster" — a registry compromise that lands a malicious image in our own ECR fails the signature check. Default-ServiceAccount blocking forces every pod to use a named SA, which is the precondition for IRSA-scoped IAM (§6) — a pod using `default` SA inherits the namespace's default token, which is the worst possible blast-radius default.

Kyverno was chosen over OPA Gatekeeper deliberately — its YAML-native policy language is operationally simpler for a small SRE team than Rego, and the expressiveness gap does not bite at our scale. If the operating organisation already runs Gatekeeper, the same architectural slot accepts that engine; the layered model (PSS baseline + custom-policy engine) is the load-bearing decision, not the specific policy language. Custom admission webhooks were considered and rejected — Kyverno is exactly the generalised version of that, with maintained policy-library churn we do not have to absorb.

New Kyverno policies enter `audit` mode for one week before promotion to `enforce` — a buggy `enforce`-mode policy can block all pod deploys, so we accept the one-week observation window as the cost of catching policy bugs before they cause outages. Legitimate exceptions — the Wazuh DaemonSet (§9), Falco and Tetragon DaemonSets (§8) — run in dedicated `privileged`-labelled namespaces with a Kyverno `PolicyException` scoped to those exact pods. The exception is not a concession; it is a documented control. An auditor sees: "yes, these specific pods are privileged, here is the explicit exception, here is the rationale, here is what we monitor on them."

### 5. Image supply chain — Trivy CVE scan + Cosign signature verification

**Threat addressed:** known CVE in base image or dependency; image tampering between build and registry; typo-squat in the registry; "we deploy whatever lands in our ECR."
**Standard:** SLSA Level 2 (provenance + signed artifacts) at POC scope, with SLSA L3 named as an upgrade trigger; NIST SSDF SP 800-218 PW.4.4 (verify third-party components for vulnerabilities); CycloneDX SBOM format.

The supply-chain pipeline runs in three CI stages and one admission stage, with each stage's output feeding the next:

```
CI build (GitHub Actions)
   ├─ docker build → image tagged
   ├─ Trivy scan
   │    └─ HIGH/CRITICAL CVE → fail build (with .trivyignore allowlist + expiry date)
   ├─ Cosign sign (Sigstore keyless via GitHub OIDC, or KMS-backed key for air-gapped)
   ├─ Push to ECR (image + signature + Rekor log entry)
   │
ECR registry
   ├─ ECR continuous scan (defense-in-depth against post-build CVE drops)
   ├─ Cosign signature stored alongside image
   │
K8s admission (Kyverno + Cosign verifier)
   └─ verifyImages → image must verify against trusted GitHub OIDC issuer
```


1. **Build & Trivy scan in CI.** `docker build` produces the image; Trivy scans against NVD / OSV / GitHub Advisory Database; HIGH or CRITICAL CVE severity fails the build. False-positive CVEs go into `.trivyignore` with a mandatory expiry date and a named review owner — no permanent mute. Trivy also generates the CycloneDX SBOM, which is pushed alongside the image so we can answer "do we ship anything affected by CVE-XXXX-YYYY?" without re-scanning every image.
2. **Cosign sign in CI.** Sigstore keyless signing via the GitHub OIDC token — no long-lived signing key to manage, no HSM, no leaked-key incident response. The cryptographic identity is the GitHub Actions workflow identity itself, anchored to the Rekor transparency log. For environments where keyless signing is unavailable (regulated, air-gapped), KMS-backed Cosign signing using the `kms-secrets` key (§7) is the fallback path.
3. **ECR push & native scan.** ECR's continuous scanning runs alongside Trivy as a defense-in-depth layer — Trivy catches issues at build time when fixing is cheapest; ECR re-scans against an updated CVE feed afterwards.
4. **Admission verification.** Kyverno's `verifyImages` policy refuses pod creation unless the image signature verifies against the trusted issuer (our GitHub OIDC identity). This is the binding step. Without it, the chain reduces to "we hope our CI signed it"; with it, only signed images run.

This layered chain is what closes the gap between ADR-031's "image must come from our ECR registry" and the realistic threat that a compromised CI or registry push lands a malicious image in our own registry. CVE scan and signing address different threats; either alone is incomplete. The combined control is what the SLSA threat model addresses.

### 6. Secrets — AWS Secrets Manager + External Secrets Operator (ESO) with IRSA

**Threat addressed:** plaintext secrets in git, in Helm values, in Terraform state; "compromise of one kubeconfig = exposure of every secret"; rotation paralysis on long-lived API keys.
**Standard:** ISO 27001 A.5.15 (Access control), A.8.24 (Cryptography); CIS Kubernetes Benchmark v1.8 §5.4 (Secrets management).

AWS Secrets Manager is the source of truth. External Secrets Operator (ESO) with an IRSA-bound `ClusterSecretStore` syncs secrets into Kubernetes Secret resources with periodic refresh (default 1h):

```
AWS Secrets Manager (source of truth, KMS-encrypted with kms-secrets)
    ↓ ESO ClusterSecretStore (IRSA-bound IAM role)
    ↓ ExternalSecret CRD (per-secret declaration in Helm chart)
    ↓ K8s Secret resource (target, refreshed every 1h)
    ↓ Pod (envFrom / volumeMount)
```

No raw secret material ever lands in Helm values, Terraform state, or git — `ExternalSecret` CRDs reference secret names, not values, which means the entire Helm chart is auditable end-to-end without hidden values overrides.

Per-component IRSA scoping is what makes this layer load-bearing rather than cosmetic. Each component gets its own IAM role limited to specific secret ARNs: the stateful pod's IRSA can read the Restic encryption password, not the Grafana Cloud API key. The relocation service's IRSA can read placement-table KMS but not other-tier KMS. The Velero server's IRSA scope (representative):

```hcl
# velero-server IAM role (IRSA-bound)
permissions:
  # EBS Snapshot operations (in-region backup)
  - ec2:CreateSnapshot / CopySnapshot / DescribeSnapshots / DescribeVolumes
  - ec2:CreateTags / DeleteSnapshot                  # retention rollover

  # S3 backup metadata (Velero BSL — Backup Storage Location)
  - s3:PutObject / GetObject / ListBucket / DeleteObject
    Resources: <backup-bsl-bucket>/* and <backup-bsl-bucket>

  # KMS for backup encryption (kms-backup only; not stateful-data, secrets, placement)
  - kms:Decrypt / GenerateDataKey
    Resources: arn:aws:kms:*:account:key/<kms-backup-id>
```

Velero can read backup-tier KMS for BSL metadata and inherits stateful-tier KMS for EBS Snapshot operations transparently (the snapshot inherits the volume's existing encryption), but cannot reach secrets-tier or placement-table KMS. The operator role — assumed via SSO + MFA, not a workload IRSA — has time-boxed access to all tier keys for incident response, with every assumption logged in CloudTrail. The blast radius of any single compromised IRSA role is bounded by the IAM policy, not by the cluster boundary.

Rotation works in this model. AWS Secrets Manager handles native rotation schedules where supported (RDS, Redis); ESO refresh picks up new versions within one hour; workloads consume the new secret on next pod restart, or via a reloader controller for hot-reload. Native Kubernetes Secrets make rotation a manual cross-cluster propagation problem; ESO makes it a configuration property.

Kubernetes Secret resources still land in etcd as the downstream cache of Secrets Manager. We rely on EKS's built-in KMS envelope encryption of etcd to harden that cache. The source of truth in Secrets Manager remains under IAM control, so a leaked kubeconfig with `secrets/get` exposes only a refresh-window's worth of cached values — Secrets Manager rotation invalidates the leak within one cycle.

HashiCorp Vault is named as an upgrade trigger when dynamic secrets (per-request DB credentials with 5-minute TTL) or PKI-as-a-service become requirements. ESO's backend-pluggable architecture means migrating from Secrets Manager to Vault later is a configuration swap, not a re-architecture.

### 7. Encryption at rest — five per-tier KMS keys, separate IAM

**Threat addressed:** "compromise of one IAM role exposes every encrypted resource"; conflated audit signal across resource classes; one-size-fits-all rotation cadence.
**Standard:** NIST SP 800-57 Part 1 Rev. 5 (Recommendation for Key Management); ISO 27001 A.8.24 (Cryptography).

Five customer-managed KMS keys, each scoped to one tier of data:

| Key | Purpose | Used by |
|---|---|---|
| `kms-stateful-data` | EBS volumes (per-pod LevelDB); EBS Snapshots inherit transparently | EBS CSI driver via IRSA; Velero EBS Snapshot operations inherit |
| `kms-backup` | Velero S3 BSL — Kubernetes YAML and manifest metadata | Velero IRSA |
| `kms-logs` | CloudWatch Logs and Loki / log-archive S3 buckets | Logging agents, log archival |
| `kms-secrets` | Secrets Manager entries (§6) | ESO IRSA |
| `kms-placement-table` | DynamoDB encryption-at-rest for the routing placement table | Relocation-service IRSA, stream-fanout Lambda |

The argument for per-tier keys is the argument against AWS-managed `aws/ebs` / `aws/s3` defaults: a compromised IRSA role with `kms:Decrypt` on `kms-stateful-data` cannot read backup buckets, log buckets, secrets, or placement-table data — those are under different keys with different IAM grants. AWS-managed keys do not give that isolation. Per-tier blast radius matches the architecture's existing tier boundaries — stateful data, backup data, log data, secrets, routing state are already separate concerns in the design; the key boundary mirrors them.

Annual automatic key-material rotation is enabled on all five keys (the AWS-managed rotation rotates material without changing the key ARN, so resources do not need re-tagging):

```hcl
resource "aws_kms_key" "stateful_data" {
  description             = "EBS encryption for app stateful tier"
  deletion_window_in_days = 30
  enable_key_rotation     = true   # annual automatic material rotation
  policy                  = data.aws_iam_policy_document.kms_stateful_data.json
}
# Repeat with separate IAM policy documents for backup / logs / secrets / placement_table.
```

CloudTrail is per-key, which means "show me every decrypt of `kms-backup` in the last 24 hours" is a clean Athena query — with one shared key, the noise overwhelms the signal. Manual key rotation (new ARN, re-encrypt data) is reserved for incident response and named as an upgrade trigger.

The placement-table key is separated from `kms-secrets` deliberately. The placement table is critical routing state — losing or corrupting the key takes the data plane down for every tenant. Sharing it with secrets would mean a single compromised role with `kms:Decrypt` on the secrets key could read both API tokens and routing state. Splitting them aligns with the same per-tier blast-radius argument that motivates the original four keys.

Cost is negligible — five keys at $1/key/month + $0.03 per 10K requests is single-digit dollars at POC scope. The audit improvement is dramatically larger than the dollar cost.

### 8. Runtime detection — Falco + Tetragon eBPF DaemonSets on stateful nodes

**Threat addressed:** runtime exploitation of a freshly compromised container — exploited zero-day in app code, supply-chain compromise inside a CVE window, lateral movement from a compromised neighbour, container-runtime escape.
**Standard:** MITRE ATT&CK for Containers — T1611 (Escape to Host), T1612 (Build Image on Host), T1613 (Container and Resource Discovery); CIS Kubernetes Benchmark v1.8 §5 (runtime security controls); NIST SP 800-190 §4.4 (Application Container Security — Runtime Threats).

Pre-deployment defenses (Trivy, Cosign, NetworkPolicy, PSS + Kyverno) reduce the *probability* of a compromised container reaching production. They do not detect a container that becomes compromised at runtime. The stateful tier holds customer data — a runtime-detection blind spot here is the highest-impact gap that pre-deployment controls leave open. eBPF is the modern answer because it gives kernel-level introspection without requiring kernel modules, with Kubernetes pod / namespace / label context joined in by the agent. One DaemonSet pod per node observes every container.

We deploy two eBPF tools, on the stateful node pool only:

- **Falco for detection breadth.** CNCF Graduated, large rules ecosystem. Userspace rule engine evaluates kernel events. Default ruleset covers container runtime escapes (CVE-2019-5736 runc, CVE-2024-21626 runc `/proc/self/fd`, CVE-2022-0185 legacy filesystem), unexpected outbound destinations (data exfiltration with explicit allowlist for ALB ingress, DNS, S3/STS), privilege escalation (`setuid`, capability gain inside container), file integrity on `/etc/passwd` / `/etc/shadow` / `/etc/sudoers`, cryptominer indicators, and reverse-shell patterns (`sh -i`, `bash -i`, `nc -e`, `socat exec:`).
- **Tetragon for high-confidence enforcement.** CNCF Incubating; younger but stable. Kernel-level filtering with the ability to `Sigkill` an offending process at the kernel — turning detection into prevention for the narrow set of behaviours we are confident are non-noisy. We start with a small, conservative TracingPolicy set (sensitive syscalls in stateful pods — `ptrace`, `mount`, `unshare`, raw `sys_*`) and expand iteratively.

Used together, Falco gives the broad detection net at manageable false-positive rate after tuning; Tetragon gives the narrow, kill-on-sight perimeter for behaviours we never want. They share the same kernel data plane; they have complementary policy planes.

Both DaemonSets need to mount host paths (`/proc`, `/sys/kernel/debug`, `/var/run/containerd`, kernel BPF programs), which the `restricted` PSS profile (§4) forbids. We resolve this the same way we resolve the Wazuh DaemonSet exception — dedicated `falco` and `tetragon` namespaces labelled `pod-security.kubernetes.io/enforce: privileged`, with a Kyverno `PolicyException` scoped to those exact DaemonSets. The exception is documented, scoped, and image-pinned via the §5 signing chain.

Operational cost is roughly 2-5% CPU per node, which the stateful tier already absorbs given its 1:1 pod:node ratio with sidecar headroom. First-30-day false-positive volume requires tuning — that cost is the standard SIEM rollout cost and is included in the operating budget. ML / anomaly-based detection layered on top of eBPF events is named as an explicit upgrade trigger.

### 9. SIEM correlation — Wazuh for cluster/app, GuardDuty for AWS

**Threat addressed:** correlation gap between AWS-tier events (CloudTrail, VPC flow, EKS audit) and in-cluster runtime events; vendor lock-in on the data-heavy tier; sub-processor exposure from commercial SaaS SIEMs.
**Standard:** ISO 27001 A.8.16 (Monitoring activities); SOC 2 CC7.2 / CC7.3 (System Operations / Evaluation of security events).

The architectural question is not "which SIEM" but "what kind of signal do we need, and where does it come from?" Two distinct event-source layers exist: the cluster + application layer (pod runtime events, FIM on nodes, K8s audit log, suspicious process trees) and the AWS layer (VPC flow logs, CloudTrail, S3 data events, EKS audit, IAM credential anomalies). Picking only one leaves a structural blind spot.

**Wazuh covers the cluster + app layer.** Self-hosted on EC2 in the workload AWS account; agents run as a DaemonSet on every node:

```
                  Wazuh manager (EC2, dedicated, master AZ; cold-DR via Velero)
                       ↑
          ┌────────────┼────────────┐
          │            │            │
    Wazuh agent   Wazuh agent   Wazuh agent
    (DaemonSet on each node — host + pod runtime + audit)

                  AWS GuardDuty (managed)
                       ↑
          ┌────────────┼────────────┐
          │            │            │
       VPC flow    CloudTrail   EKS audit
                  S3 events    EBS anomaly
```

Wazuh provides File Integrity Monitoring on `/etc`, `/var/log`, and container runtime configs; process anomaly detection inside containers; K8s audit log ingestion; rule-based correlation across application logs; and out-of-the-box compliance reporting for CIS Kubernetes, ISO 27001, and PCI-DSS. The data-residency story matters: open-source self-hosted means no SaaS sub-processor relationship, which is the right answer for European customers under GDPR.

**GuardDuty covers the AWS layer.** Managed; ingests VPC flow logs, CloudTrail, S3 data events, and EKS audit at the AWS layer with AWS-tier threat intel (known-malicious IPs, Tor exit nodes, AWS-specific TTPs) that no self-hosted tool can replicate. Cost scales with VPC flow volume, bounded at our scale to $50-100/month — trivially worth it for the signal.

The two-source split is the load-bearing decision: a compromised IAM credential used for cross-region S3 enumeration shows up in GuardDuty (CloudTrail-fed); a compromised pod running `chmod +s /bin/bash` shows up in Wazuh (FIM). One layer catches what the other misses. Both feed the same on-call channel — severity routing happens at the alerting layer (PagerDuty or equivalent), not at the SIEM layer, so on-call does not have to watch two consoles.

Falco and Tetragon events from §8 also feed Wazuh, which is what unifies in-cluster runtime detection with the rest of the SIEM correlation. Wazuh's DaemonSet itself runs privileged (host-path access for FIM) under the same Kyverno `PolicyException` pattern as Falco and Tetragon.

### 10. Logging & audit — multi-source, tamper-protected, 90d hot / 7y cold

**Threat addressed:** the auditor question — "prove that every administrative action against the customer's data was logged, attributable, and tamper-protected for at least seven years"; an attacker deleting the log of their own attack.
**Standard:** SOC 2 Type II CC7.2 / CC7.3; ISO 27001:2022 A.8.15 (Logging), A.8.16 (Monitoring activities); GDPR Article 32 (Security of processing); NIST SP 800-53 Rev. 5 AU-2 / AU-3 / AU-9 / AU-11; NIS2 Directive Article 21.

Application logs are not audit logs. The audit pipeline is a separate stream with stricter requirements — coverage of every privileged action, cryptographic integrity, multi-year retention, and convergence into the SIEM so an auditor can reconstruct an incident.

**Source matrix:**

| Source | What it captures | Destination | Retention |
|---|---|---|---|
| EKS audit log | Every K8s API call (verb, user, object, allowed/denied) | CloudWatch Logs → Wazuh | 90d CW / 7y S3 |
| AWS CloudTrail (multi-region) | Every AWS API call across all regions | S3 (Object Lock) + CloudWatch → Wazuh | 7y (Object Lock COMPLIANCE) |
| VPC Flow Logs | **Rejected connections only** (cost calibration) | CloudWatch Logs → Wazuh | 30d hot / 90d cold |
| ALB access logs | Every HTTP request + response code | S3 (partitioned by date) → Athena | 90d hot / 1y cold |
| CloudTrail data events on backup S3 | Object-level read/write/delete on backup buckets | S3 (Object Lock) | 7y |
| Falco / Tetragon (§8) | eBPF runtime security events | Wazuh manager | 90d; escalated alerts indefinite |
| Wazuh manager itself | All ingested events, normalised | Wazuh indexer + S3 archive | 7y |

The cost-calibration choices are deliberate. Rejected-connections-only VPC flow logs preserve the security signal — denied policy actions, unexpected egress attempts — without the volume of uninteresting accepted traffic that a busy stateful node would generate. The equivalence trade is "lose successful-flow forensics for normal traffic; keep all 'something tried something it shouldn't' events", which is the right cut for an audit-driven retention budget. ALB access logs go to S3 + Athena rather than CloudWatch because Athena's $5/TB scanned beats CloudWatch's $0.50/GB ingestion by an order of magnitude on high-volume request logs.

**Tamper protection comes in three layers.** (a) CloudTrail log-file integrity validation — every log file is signed with a SHA-256 hash chain on delivery to S3, and `aws cloudtrail validate-logs` detects post-delivery tampering. (b) S3 Object Lock in COMPLIANCE mode on the cold-archive bucket — even the AWS root account cannot delete an object until its retention expiry; this is the strongest tamper protection AWS offers. (c) KMS encryption with `kms-logs` (per §7), with every key access logged into CloudTrail itself — an attacker who deletes the KMS key can no longer read the audit log, but cannot modify it; that is the bounded threat we accept.

Multi-region CloudTrail is required even though the workload is single-region — account-level events (root login, IAM changes, region enablement) only show up in the home region of the calling principal. Trying to limit CloudTrail to one region after the fact is more expensive than starting global; SOC 2 expects global coverage. Object Lock COMPLIANCE mode is irreversible — we cannot shorten retention even by mistake — and that is the point. A configuration drift cannot quietly destroy retention.

Steady-state log spend lands at mid-three-figures EUR/month at POC scale. That is the price of being audit-defensible by construction rather than by retrofit at certification time. The cost calibration choices above (rejected-connections-only flow logs, Athena over CloudWatch for ALB) keep that figure bounded; the SOC 2 evidence chain remains intact.

## Trade-offs accepted

- **Operational surface is non-trivial.** Five new components — ESO, Kyverno, Wazuh manager + agents, Falco, Tetragon — each Helm-installable, each a controller to operate, each requiring tuning attention in the first 30 days. We accept this because the alternative is a smaller operational surface with a much larger blast radius. The marginal operational cost per component is bounded; the marginal security gain is layered.
- **Privileged DaemonSet exceptions widen the attack surface intentionally.** Wazuh, Falco, and Tetragon all need host-path access; all run in `privileged`-labelled namespaces; all have explicit Kyverno `PolicyException` carve-outs. We treat each exception as a documented control rather than a concession, with image-pin + signature-verification (§5) as the binding mitigation.
- **Audit log spend is real and recurring.** Mid-three-figures EUR/month at POC scale; grows linearly with traffic. We accept this as the cost of being audit-defensible from day one rather than scrambling to retrofit at certification. Cost-calibration choices (rejected-flow-only, Athena for ALB, Glacier Instant Retrieval for cold) bound the growth rate.
- **Object Lock COMPLIANCE retention is irreversible.** The retention window cannot be shortened. That is the point — configuration drift cannot quietly destroy the audit trail — but it does mean we are committing to a 7-year storage liability per object.
- **Default-deny policy debugging adds one step.** A "pod can't reach X" investigation has to check NetworkPolicy first. Operators learn this once; the runbook covers it.
- **No L7 / identity-based network policy.** A compromised pod with allowed S3 egress and IAM credentials can `aws s3 cp` data to an attacker-controlled bucket. The mitigation lives one layer down — IRSA scoping and per-tier KMS — not in NetworkPolicy. We accept the L7 gap because the cost of closing it (Cilium swap or service mesh adoption) is disproportionate at POC scope; it is the named upgrade trigger.
- **Tetragon enforcement can kill processes.** A buggy TracingPolicy can `Sigkill` a legitimate workload. We start the policy set conservatively and expand only when confident.

## Alternatives considered

**Single SIEM (Wazuh-only or GuardDuty-only)** — rejected because each alone has structural blind spots. Wazuh cannot ingest VPC flow at scale or replicate AWS-tier threat intel; GuardDuty has no in-cluster runtime visibility. The hybrid is not over-engineering — it is closing the AWS-cluster correlation gap.

**Commercial SaaS SIEM (Splunk ES / Datadog Security / Sentinel)** — rejected on cost, sub-processor relationship for European customers, and lock-in on the data-heavy tier. These shine at large enterprises with dedicated SOC; over-tooled for our scope.

**OPA Gatekeeper instead of Kyverno** — rejected on operational simplicity for our team size. Rego is a real learning investment; Kyverno's YAML-native policy is readable by any SRE without retraining. If the operating organisation already runs Gatekeeper, the architectural slot accepts that engine — the layered model (PSS baseline + custom policy) is the load-bearing decision.

**HashiCorp Vault instead of AWS Secrets Manager + ESO** — rejected at POC scope. Operating Vault is a non-trivial commitment (HA cluster, unseal ceremony, backup of Vault's own state) and the superpowers (dynamic secrets, transit encryption-as-a-service) are not needed yet. Migration to Vault later via ESO backend swap is straightforward.

**Sealed Secrets** — rejected because rotation is awkward (re-encrypt every secret on key rotation) and the source of truth fragments across git repos.

**One single customer-managed KMS key for all resources** — halfway. Better audit than AWS-managed but defeats the per-tier blast-radius argument. If we are doing customer-managed at all, the marginal cost of four more keys is trivial.

**Per-resource KMS keys (one per S3 bucket, one per EBS volume)** — rejected for operational explosion at scale. Per-tier is the right granularity for blast-radius vs operability trade-off.

**Sidecar-based runtime security agent** — rejected on resource cost and missed coverage. Per-pod sidecar is high overhead and limited to pod's namespace; eBPF DaemonSet is the modern answer with full kernel visibility.

**Skip image signing, scan only** — rejected because registry compromise delivers a "clean" but malicious image. Signing is the part that addresses that threat.

**Skip CVE scan, sign only** — rejected because known CVEs are the most common production-incident driver. Signing alone does not help if our own legitimate build pulls a vulnerable base image.

**ACM-only at the edge (no Caddy mention)** — rejected for completeness. Spec language is selected, not random; the spec's mention of Caddy alongside Wazuh signals open-source / self-hostable preference for non-AWS edges. Documenting why and when we reach for Caddy is part of the architecture.

## Out of POC scope (upgrade triggers)

- **L7 / identity-based network policy via Cilium or service mesh.** Trigger: attacker model includes intra-cluster lateral movement at HTTP method/path level, or compliance demands mTLS everywhere.
- **Cluster-internal mTLS via cert-manager + service mesh.** Trigger: zero-trust requirement at internal hops.
- **HashiCorp Vault for dynamic secrets.** Trigger: short-lived database credentials with sub-hour TTL, or PKI-as-a-service.
- **Bring-your-own-key (BYOK) per-tenant KMS.** Trigger: enterprise tenant compliance requirement. Today's per-tier model is the foundation; per-tenant is the next refinement.
- **HSM-backed CloudHSM.** Trigger: regulatory requirement (PCI-DSS, FIPS 140-2 Level 3).
- **Multi-region KMS keys.** Trigger: cross-region S3 backup replication or multi-region active-passive — KMS keys are regional by default.
- **SLSA Level 3+ provenance.** Trigger: regulatory or customer requirement for hermetic, tamper-evident builds. Requires more isolated runners and signed provenance attestation.
- **Vulnerability gating at admission (current CVE database, not just build-time scan).** Trigger: shift from "clean at build" to "clean at admission."
- **Falco SIEM forwarders to OpenSearch / Splunk.** Trigger: SIEM topology change.
- **Tetragon TracingPolicy authoring at depth.** Trigger: team capacity to maintain custom kernel-level enforcement policies.
- **AWS WAF on the ALB.** Trigger: regulatory or threat-model requirement for L7 web-app firewall.
- **HTTP/3 at the edge (CloudFront or Caddy in front of ALB).** Trigger: customer-perceived latency win is meaningful.
- **AWS Security Hub aggregation.** Trigger: multi-account organisation with central security view.
- **SOAR (TheHive / equivalent) automated incident response.** Trigger: SOC team scale where manual triage cannot keep up.
- **Customer-side audit log delivery.** Trigger: customer DPO / auditor requires direct SIEM cross-account replication.
- **Long-tail compliance (HIPAA, PCI-DSS log requirements).** Trigger: regulated-vertical customer onboarding.

## Stage 3 questions

1. **CNI choice.** AWS VPC CNI with NetworkPolicy support enabled, or Calico-as-CNI? Both satisfy the L4 policy semantics; the choice affects troubleshooting tools and `eksctl` cluster creation flags. Calico-as-CNI gives richer egress policy (CIDR-block allow-lists with FQDN matching) at the cost of one more component to operate.
2. **Existing Wazuh footprint.** Spec mention suggests Wazuh is already in use. Confirm whether the platform should attach to an existing Wazuh manager or stand up its own — affects deployment topology (workload account vs centralised security account) and dashboard access patterns.
3. **Existing CI/CD platform.** GitHub Actions, GitLab, or other? Affects exactly which Cosign keyless OIDC flow applies. Existing artifact registry — ECR, Harbor, Artifactory — affects signing format and verification method.
4. **Existing OPA Gatekeeper deployment.** If the operating organisation already runs Gatekeeper, we align with that engine rather than introducing Kyverno.
5. **Legacy application runtime profile vs `restricted` PSS.** Some legacy apps need `runAsRoot` or specific capabilities. We confirm the application's runtime profile against `restricted` early; non-fitting apps go through PSS profile relaxation per namespace or Kyverno `PolicyException` rather than dropping the baseline.
6. **Non-AWS edges in scope.** If on-prem / hybrid / customer-hosted edges exist, the Caddy section becomes load-bearing rather than alternative documentation.
7. **Audit retention horizon.** 7 years is the safe default; some regulated verticals require 10 or 20. Object Lock COMPLIANCE mode is the right fit for most cases; COMPLIANCE-with-Legal-Hold is the less restrictive alternative.
8. **Existing landing zone KMS conventions.** If there is an org-level KMS baseline (Control Tower / Account Factory), our per-tier keys live in the workload account but may need to coordinate with org-level patterns (e.g. logging keys consolidated in a security account).
9. **Existing eBPF posture.** Cilium / Hubble already deployed (Tetragon ships from the same vendor and integrates cleanly), Sysdig commercial, or greenfield? Affects operator skill cost.
10. **Secret migration from legacy.** Existing Restic password / DB credentials / API keys — migrate into Secrets Manager or start clean? Migration is straightforward (one-time `aws secretsmanager create-secret` per item) but timing affects cutover.

## Cross-references

- ADR-01 (Per-tenant pod model + topology) — security perimeters mirror the tenant boundary; the stateful tier holds the irreplaceable asset.
- ADR-02 (Single master AZ + standby AZ rotation) — security architecture does not assume multi-AZ runtime presence; controls are designed for master-AZ-only execution.
- ADR-03 (Routing — placement table + Envoy) — the 3-tier flow (ALB → API → Envoy → StatefulSet) is the spine the NetworkPolicy and admission policies bind to.
- ADR-04 (Backup + DR — Velero cold DR primary) — Velero IRSA, KMS scoping for the BSL, and CloudTrail data events on the backup S3 bucket are first-class concerns of this ADR.
- ADR-05 (Observability — OpenTelemetry, Grafana Cloud, audit-log retention) — application logs are tenant-scoped JSON with 30d/90d retention; the audit pipeline here is a separate stream with 90d hot / 7y cold.
- ADR-06 (CI/CD + GitOps — GitHub Actions, ArgoCD manual prod sync) — Trivy, Cosign, and Kyverno admission are PR/merge-time gating; security is a property of the supply chain, not a deploy-time afterthought.
- ADR-08 (FinOps as architecture discipline) — log-spend calibration choices (rejected-flow-only, Athena for ALB, Glacier Instant Retrieval for cold) are deliberate FinOps trade-offs visible in the audit pipeline.

(Originally split across private ADR-026..ADR-032 + ADR-043 + ADR-044; consolidated 2026-05-09.)
