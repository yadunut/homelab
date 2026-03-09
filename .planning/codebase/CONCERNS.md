# Repository Concerns

This document captures repo-specific technical debt, operational risks, validation gaps, and fragile implementation areas in the current GitOps tree. It focuses on concerns that are directly visible in the checked-in manifests and docs.

## 1. Infrastructure reconciliation is a single blast radius

- `cluster/infrastructure.yaml` defines one Flux `Kustomization` for all shared services under `./cluster/infrastructure`.
- `cluster/infrastructure/kustomization.yaml` then fans that single reconcile into CoreDNS, Cilium, the HTTP proxy, Longhorn, 1Password, cert-manager, ExternalDNS, Traefik, Garage, Harbor, Kanidm, metrics-server, the NVIDIA device plugin, and CloudNativePG.
- There is no per-component Flux boundary inside infrastructure, so a bad change in one infrastructure directory can block or muddy reconcile status for unrelated components.
- This also makes rollout ordering coarse. Controller installs, CRDs, secrets, ingress, storage, and dependent manifests are grouped into one layer instead of isolated reconciles with narrow health reporting.

Practical follow-up:
- Split high-risk infrastructure components into separate Flux `Kustomization` resources when they have different failure domains or readiness needs.
- At minimum, isolate foundational operators and storage/networking components from user-facing infrastructure.

## 2. Flux readiness gates are thin

- The app wrappers in `cluster/apps/forgejo.yaml`, `cluster/apps/immich.yaml`, `cluster/apps/jellyfin.yaml`, and `cluster/apps/woodpecker.yaml` only declare `dependsOn: infrastructure`.
- None of those Flux `Kustomization` resources define `wait`, `healthChecks`, or tighter timeouts.
- `cluster/infrastructure.yaml` also lacks `wait` and explicit health checks for the infrastructure layer.
- In practice this means Flux ordering is mostly "apply after infrastructure object exists", not "apply after the infrastructure workloads are healthy".

Operational risk:
- Secrets from the 1Password operator, CRDs from operators, ingress routes, and storage-backed resources can all be applied before their backing controllers are actually ready.
- Failures are likely to surface as transient reconcile noise or stuck app rollouts instead of clean dependency failures.

## 3. Version drift is intentionally loose in several critical places

- Helm chart versions are open-ended in multiple files:
  - `cluster/apps/forgejo/helmrelease.yaml`
  - `cluster/apps/woodpecker/helmrelease.yaml`
  - `cluster/apps/jellyfin/helmrelease.yaml`
  - `cluster/infrastructure/1password/helmrelease.yaml`
  - `cluster/infrastructure/cloudnative-pg/helmrelease.yaml`
  - `cluster/infrastructure/external-dns/helmrelease.yaml`
  - `cluster/infrastructure/harbor/helmrelease.yaml`
  - `cluster/infrastructure/metrics-server/helmrelease.yaml`
  - `cluster/infrastructure/nvidia-device-plugin/helmrelease.yaml`
  - `cluster/infrastructure/traefik/helmrelease.yaml`
- Several of those use wildcard or major-only ranges such as `0.x`, `2.x`, `3.5.*`, `1.18.*`, or `>=... <...`.
- Image pinning is inconsistent. `cluster/apps/immich/helmrelease.yaml` is wired to Flux image automation, but `cluster/apps/jellyfin/copyparty-deployment.yaml`, `cluster/apps/jellyfin/helmrelease.yaml`, `cluster/infrastructure/kanidm/deployment.yaml`, and `cluster/apps/immich/database.yaml` still rely on mutable tags without digests.

Operational risk:
- Changes can land from upstream without a repo change to the workload itself.
- Rollbacks and incident reconstruction become harder because the repo does not always fully describe the exact runtime artifact set.

## 4. Proxy behavior is a repeated hand-maintained config surface

- Proxy env vars are hand-written in multiple places:
  - `cluster/flux-system/kustomization.yaml`
  - `cluster/apps/immich/helmrelease.yaml`
  - `cluster/apps/jellyfin/helmrelease.yaml`
  - `cluster/apps/jellyfin/copyparty-deployment.yaml`
  - `cluster/apps/woodpecker/helmrelease.yaml`
  - `cluster/infrastructure/harbor/helmrelease.yaml`
- `docs/http-proxy-guide.md` documents a reusable ConfigMap pattern, but the repo does not use one shared manifest for these values.
- `docs/woodpecker-ci-debug-summary.md` shows this is already an operationally fragile area: proxy routing and `NO_PROXY` contents had to be tuned per workload, and proxying some destinations remained flaky.

Why this is debt:
- Every new IPv4-dependent workload has to rediscover the same env contract.
- Small `NO_PROXY` mistakes can break internal service traffic or external fetches.
- The current setup invites drift between workloads because there is no single source of truth for proxy env.

## 5. Some core services still have obvious single points of failure

- `cluster/infrastructure/coredns/coredns.yaml` runs CoreDNS with `replicas: 1`, even though cluster DNS is a hard dependency and the service IP is intentionally fixed.
- `cluster/infrastructure/kanidm/deployment.yaml` runs Kanidm with `replicas: 1` and no rollout safety around identity availability.
- `cluster/apps/forgejo/helmrelease.yaml` sets `replicaCount: 1`.
- `cluster/apps/immich/database.yaml` runs the Immich database with `instances: 1`.

Operational risk:
- Node failure, drain, or a bad rollout on any of these workloads can cause immediate service loss rather than degraded service.
- The repo has some replication where it matters, but critical identity, DNS, and app control planes are still concentrated on single instances.

## 6. Ingress availability is weaker than the replica count suggests

- `cluster/infrastructure/traefik/helmrelease.yaml` sets `deployment.replicas: 2`, but it also sets `updateStrategy.type: Recreate`.
- The same manifest runs Traefik on `hostNetwork: true` and constrains it to ingress-labeled nodes.

Operational risk:
- During upgrades, the repo is configured for replacement rather than rolling handoff, so the second replica does not buy as much upgrade safety as it appears to.
- This is especially sensitive because Traefik fronts multiple public services from this repo.

## 7. Storage behavior for `longhorn-local-1r` is easy to misunderstand

- `AGENTS.md` describes `longhorn-local-1r` as strict-local storage where the pod and volume stay on the same node.
- `cluster/infrastructure/longhorn/storageclass.yaml` actually sets `numberOfReplicas: "1"` and `dataLocality: "best-effort"`, with `volumeBindingMode: Immediate`.
- That is not the same thing as a strict-local, wait-for-consumer storage class.

Why this matters here:
- The repo leans on `longhorn-local-1r` for stateful workloads in `cluster/apps/forgejo/database.yaml`, `cluster/apps/immich/database.yaml`, `cluster/apps/immich/pvc.yaml`, `cluster/apps/jellyfin/helmrelease.yaml`, `cluster/apps/jellyfin/media-pvc.yaml`, and parts of `cluster/apps/woodpecker/helmrelease.yaml`.
- If operators assume the storage class is stricter or more predictable than it really is, failure handling and scheduling expectations will be wrong.

This is both documentation debt and an operational ambiguity that should be resolved one way or the other.

## 8. Capacity coupling on `nut-gc2` creates a hidden shared failure domain

- `docs/storage.md` explicitly notes that Longhorn and Garage both use the same `/srv` filesystem on `nut-gc2`.
- `cluster/infrastructure/garage/service.yaml` exposes Garage as an external service, while `cluster/infrastructure/longhorn/helmrelease.yaml` and `cluster/infrastructure/longhorn/storageclass.yaml` keep Longhorn as the default storage backend for the cluster.

Operational risk:
- Object storage growth and block volume growth compete on the same underlying filesystem.
- A capacity incident on `nut-gc2` can affect both cluster storage and the backup/object-storage layer at once.

## 9. Garage reachability is pinned to static network coordinates

- `cluster/infrastructure/garage/service.yaml` uses manually defined `EndpointSlice` objects with a hard-coded IPv6 address instead of a workload selected by labels.
- `cluster/infrastructure/garage/ingressroute.yaml` and `cluster/infrastructure/garage/dnsendpoint.yaml` then build public exposure on top of that static endpoint mapping.

Operational risk:
- If the backend node address changes, this repo will not self-heal through normal Kubernetes service discovery.
- Service health depends on keeping the checked-in endpoint address current.

This is a reasonable pattern for an external service, but it is still a maintenance hotspot and deserves explicit runbook coverage.

## 10. Validation is mostly manual, and the repo shows no checked-in automation for it

- `Readme.md` and `AGENTS.md` both center validation around manual `kubectl kustomize cluster` and Flux reconcile commands.
- `flake.nix` provides a dev shell, but there is no checked-in CI workflow or lint/schema-validation configuration in the repo root.
- The repo also documents debugging in ad hoc runbooks such as `docs/http-proxy-guide.md`, `docs/nvidia-gpu.md`, and `docs/woodpecker-ci-debug-summary.md`.

Validation gap:
- Render success is the main guaranteed pre-merge check, but it does not validate schema correctness, CRD presence, controller-specific fields, or rollout health.
- Subtle problems in Traefik CRDs, Helm values, Flux image automation, and ExternalDNS records can therefore survive until runtime.

Practical follow-up:
- Add at least one automated render/schema pass for `cluster/`.
- Add a small set of component-specific smoke checks for the most failure-prone areas: proxy egress, ingress, DNS, storage, and secret-backed apps.

## 11. Some bespoke manifests have less operational hardening than the Helm-managed components

- `cluster/apps/jellyfin/copyparty-deployment.yaml` defines a raw `Deployment` with no liveness probe, no readiness probe, no resource requests/limits, and an unpinned image tag.
- `cluster/infrastructure/kanidm/deployment.yaml` also lacks liveness and readiness probes.
- These workloads sit outside the stronger defaults that some Helm charts may provide, so the repo itself owns more of their operational correctness.

Operational risk:
- Bad startup, partial readiness, or performance regression is harder for Kubernetes to detect and recover from automatically.
- These are exactly the places where repo-local validation and runbooks need to be better than average, because there is less chart-level safety net.
