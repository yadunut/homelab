## Why

New agents do not currently get critical operating context for this homelab, which leads to incorrect assumptions (for example IPv4 availability, DNS behavior, or storage behavior). We need the repository agent guidance to capture nonstandard cluster constraints so future automation and changes are safe and accurate.

## What Changes

- Replace the existing repository `AGENTS.md` with expanded, authoritative agent guidance for this homelab.
- Document that Kubernetes node configuration source of truth is in the NixOS repo at `modules/kubernetes`.
- Document Flux reconciliation scope and ordering:
  - Flux Git source tracks branch `main` and reconciles `./cluster`.
  - App kustomizations depend on the `infrastructure` kustomization.
- Document cluster networking constraints: IPv6-only cluster networking, with IPv4 only at ingress nodes.
- Include proxy guidance from `docs/http-proxy-guide.md`, including:
  - Proxy endpoint: `http://http-proxy.kube-system.svc.k8s.internal:8888`.
  - Standard `HTTP_PROXY`/`HTTPS_PROXY` and `NO_PROXY` usage for workloads that need IPv4 egress.
  - Internal-domain exclusions in `NO_PROXY` (for example `.k8s.internal`, `.svc`, `fd00::/8`) to keep cluster traffic off the proxy.
  - Pointer to existing Flux proxy patch location in `cluster/flux-system/kustomization.yaml`.
- Document cluster DNS assumptions:
  - Cluster domain is `k8s.internal` (not `cluster.local`).
  - CoreDNS service uses fixed IPv6 ClusterIP aligned with kubelet DNS config.
- Document ingress and exposure patterns:
  - Traefik runs `hostNetwork: true` on ingress-labeled nodes.
  - Some services use Traefik CRDs (`IngressRoute`, `IngressRouteTCP`), including TCP TLS passthrough for Kanidm.
- Document DNS management patterns:
  - ExternalDNS uses Cloudflare and watches `DNSEndpoint` CRDs (`sources: [crd]`).
  - Public records are commonly managed as both `AAAA` and `A` targets.
- Document storage class semantics and intended usage:
  - `longhorn` as replicated (3-node) default storage.
  - `longhorn-local-1r` as non-replicated, node-local storage intended to keep pod and volume on the same node.
- Include storage context from `docs/storage.md`, including:
  - Current Longhorn capacity summary and node disk path context.
  - Shared-filesystem caveat on `nut-gc2` (`/srv` is shared by Longhorn and Garage; avoid double counting).
- Document secret and identity conventions:
  - Secrets are sourced through the 1Password operator and namespace-scoped `OnePasswordItem` manifests.
  - OAuth2 Proxy integrations use Kanidm OIDC with group-based access control for admin surfaces.
- Document generated-manifest handling:
  - `cluster/flux-system/gotk-components.yaml` and `cluster/flux-system/gotk-sync.yaml` are generated and should not be edited directly.

## Capabilities

### New Capabilities
- `agent-repository-context`: Provide agents with authoritative repo and infrastructure context so generated changes match the homelab's NixOS, networking, proxy, and storage realities.

### Modified Capabilities
- None.

## Impact

- Affected code/docs: overwrite existing `AGENTS.md` at repository root.
- Source references: `docs/http-proxy-guide.md` and `docs/storage.md` will be cited as canonical operational detail.
- Affected systems: agent workflows and automation behavior when editing Kubernetes GitOps manifests.
- Dependencies: no runtime dependency changes; documentation and workflow guidance only.
