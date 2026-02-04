## Context

This repository is a Flux GitOps layout for a Kubernetes homelab, but several operational constraints are nonstandard and easy for agents to miss:
- Node and Kubernetes host-level configuration is managed in a separate NixOS repository (`https://git.yadunut.dev/yadunut/nix/src/branch/main/modules/kubernetes`).
- Cluster networking is IPv6-only for pod/service traffic; IPv4 is available only through ingress nodes.
- IPv4-only external access for workloads is provided through the in-cluster HTTP proxy.
- Storage behavior differs by storage class (`longhorn` replicated vs `longhorn-local-1r` node-local non-replicated).

Current repo docs contain parts of this information (`docs/http-proxy-guide.md`, `docs/storage.md`), but agents typically do not discover and synthesize them before making edits. The design must update `AGENTS.md` so it is short, authoritative, and safe to rely on.

## Goals / Non-Goals

**Goals:**
- Replace and standardize top-level `AGENTS.md` with the minimum operational context an agent needs before changing manifests.
- Encode the networking/proxy model clearly enough that agents configure proxy env vars correctly for IPv4-dependent workloads.
- Encode storage class intent clearly enough that agents choose correct PVC storage classes for replicated vs local workloads.
- Encode non-obvious control-plane conventions (Flux scope/order, cluster DNS domain, generated Flux manifests, ingress and DNS CRD patterns).
- Link to canonical docs for detailed operational procedures instead of duplicating full runbooks.
- Provide explicit "do/don't" guidance to reduce unsafe assumptions (for example assuming direct IPv4 egress from pods).

**Non-Goals:**
- Replacing or duplicating full troubleshooting/runbook content from `docs/http-proxy-guide.md`.
- Replacing capacity reporting in `docs/storage.md` with copied static numbers in `AGENT.md`.
- Changing cluster networking, storage, or proxy implementation.

## Decisions

1. Overwrite repository-root `AGENTS.md` as the primary agent onboarding document.
- Rationale: the file already exists and is used by agent tooling, so replacement avoids split-brain guidance between `AGENT.md` and `AGENTS.md`.
- Alternative considered: create a second `AGENT.md`. Rejected because duplicate entry points increase drift and ambiguity.

2. Keep `AGENTS.md` concise and policy-oriented; reference docs for detail.
- Rationale: concise guidance is more likely to be followed and less prone to drift.
- Alternative considered: embed full proxy and storage guides in `AGENTS.md`. Rejected due to duplication and stale-data risk.

3. Include normative proxy configuration defaults in `AGENTS.md`.
- Content includes proxy endpoint and required env var pattern (`HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`) with cluster-internal exclusions.
- Rationale: proxy configuration is a common source of broken deployments in IPv6-only clusters.
- Alternative considered: only mention "use proxy" without examples. Rejected because ambiguity increases incorrect implementations.

4. Capture storage-class selection rules as intent, not full capacity tables.
- `longhorn`: default replicated class (3 replicas).
- `longhorn-local-1r`: no replication, keep volume and pod on same node.
- Rationale: selection intent is stable and actionable for agents; absolute capacity numbers are operational data that belongs in `docs/storage.md`.
- Alternative considered: include current per-node capacity in `AGENTS.md`. Rejected because these values change over time.

5. Add maintenance rule in `AGENTS.md` to treat `docs/http-proxy-guide.md` and `docs/storage.md` as canonical detail sources.
- Rationale: this makes ownership explicit and reduces divergence between guidance files.
- Alternative considered: no maintenance guidance. Rejected because future edits may drift across files.

6. Include control-plane and networking invariants that agents frequently miss.
- Required invariants:
  - Flux sync source is `main` and reconciliation scope is `./cluster`.
  - App reconciliations depend on infrastructure reconciliation.
  - Cluster domain is `k8s.internal` and CoreDNS service IP is fixed by kubelet config.
  - Traefik runs on ingress nodes with `hostNetwork`, and Kanidm uses TCP TLS passthrough ingress.
  - ExternalDNS consumes `DNSEndpoint` CRDs and records are typically managed in A+AAAA pairs.
  - Flux bootstrap files under `cluster/flux-system/gotk-*.yaml` are generated and not directly edited.
- Rationale: these invariants are high-impact and easy to violate when generating changes.
- Alternative considered: keep these only in scattered manifests. Rejected because discovery cost is too high for agents.

7. Include secret and identity conventions as mandatory context.
- Required conventions:
  - Use 1Password operator plus `OnePasswordItem` references; avoid plaintext secret manifests.
  - Reuse Kanidm/OIDC and group-based authorization patterns for protected UIs.
- Rationale: security and auth consistency are cross-cutting and sensitive.
- Alternative considered: omit auth/secret details from agent guidance. Rejected due to high risk of insecure or incompatible changes.

## Risks / Trade-offs

- [Risk] `AGENTS.md` drifts from canonical docs over time. -> Mitigation: keep procedural detail in `docs/*` and keep `AGENTS.md` high-level with links and short invariants.
- [Risk] Agents may still miss proxy env var requirements in edge cases. -> Mitigation: include explicit default env var block and internal `NO_PROXY` exclusions in `AGENTS.md`.
- [Risk] Storage guidance oversimplifies workload placement needs. -> Mitigation: include selection criteria and point to `docs/storage.md` for topology/capacity context.
- [Risk] Guidance becomes too long and gets ignored. -> Mitigation: structure `AGENTS.md` into short sections with hard requirements first and references second.

## Migration Plan

1. Overwrite `AGENTS.md` at repo root with sections for cluster model, reconciliation model, networking/proxy, DNS, ingress/auth, storage classes, and source-of-truth references.
2. Validate links and paths (Nix repo path, docs references, Flux proxy patch location).
3. Keep existing docs unchanged; only add cross-references from `AGENTS.md`.
4. Review the final text for actionable language and absence of stale operational numbers.

Rollback strategy:
- Revert `AGENTS.md` to previous content if guidance is incorrect or harmful; no runtime cluster impact because this is documentation-only.

## Open Questions

- Should `AGENTS.md` include a short checklist section (for example, "before adding new controllers") to enforce proxy/storage/DNS checks?
- Should we also add a brief pointer in `/Users/yadunut/dev/src/git.yadunut.dev/yadunut/homelab/Readme.md` to `AGENTS.md` for discoverability outside agent tooling?
