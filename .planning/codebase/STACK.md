# Repository Stack

## What This Repository Is

This repository is a Flux-managed GitOps source for a Kubernetes homelab. It does not contain application source code in the usual sense. The primary "runtime" here is Kubernetes reconciliation driven by Flux from `./cluster`, as configured in `cluster/flux-system/gotk-sync.yaml`.

The practical stack is therefore a combination of:

- declarative Kubernetes manifests under `cluster/`
- Flux custom resources and controllers under `cluster/flux-system/`
- Helm charts consumed through `HelmRepository` and `HelmRelease` resources
- a small amount of Nix used only for local contributor tooling in `flake.nix`
- Markdown operational docs under `docs/`

## Languages And File Types

The codebase is mostly configuration, with a few consistent file types:

- YAML for Kubernetes resources and Kustomize assemblies, for example `cluster/apps/immich/helmrelease.yaml` and `cluster/infrastructure/traefik/ingressroute.yaml`
- Markdown for runbooks and operational notes, for example `docs/http-proxy-guide.md`, `docs/storage.md`, and `docs/nvidia-gpu.md`
- Nix for the contributor dev shell in `flake.nix`

There are no application-language directories such as `src/`, no build system for an internal app, and no repo-local test suite.

## Core GitOps Toolchain

The main platform technologies in use are:

- Flux source-controller, kustomize-controller, helm-controller, image-reflector-controller, and image-automation-controller, assembled through `cluster/flux-system/gotk-components.yaml` and customized in `cluster/flux-system/kustomization.yaml`
- Kustomize as the composition layer, with root assembly in `cluster/kustomization.yaml`
- Flux `Kustomization` resources to define reconciliation boundaries in `cluster/infrastructure.yaml` and `cluster/apps/*.yaml`
- Flux Helm support through `HelmRepository` and `HelmRelease` resources spread across `cluster/infrastructure/*/` and `cluster/apps/*/`
- Flux image automation for Immich via `cluster/apps/immich/image-repository.yaml`, `cluster/apps/immich/image-policy.yaml`, and `cluster/apps/immich/image-update-automation.yaml`

The repo currently contains at least:

- 17 `HelmRelease` manifests
- 15 `HelmRepository` manifests
- 7 Flux `Kustomization` resources at the top reconciliation boundaries

## Cluster Platform Components

Shared platform services are installed from `cluster/infrastructure/` and form most of the runtime stack:

- DNS: CoreDNS in `cluster/infrastructure/coredns/coredns.yaml`
- CNI/networking: Cilium under `cluster/infrastructure/cilium/`
- IPv4 egress bridge for IPv6-only workloads: Squid proxy in `cluster/infrastructure/http-proxy/http-proxy.yaml`
- Secret sync: 1Password Connect and operator in `cluster/infrastructure/1password/helmrelease.yaml`
- PKI/ACME: cert-manager in `cluster/infrastructure/cert-manager/helmrelease.yaml`
- External DNS management: external-dns in `cluster/infrastructure/external-dns/helmrelease.yaml`
- Ingress: Traefik in `cluster/infrastructure/traefik/helmrelease.yaml`
- Storage: Longhorn in `cluster/infrastructure/longhorn/helmrelease.yaml`
- Object storage: Garage in `cluster/infrastructure/garage/`
- Registry: Harbor in `cluster/infrastructure/harbor/helmrelease.yaml`
- Identity provider: Kanidm in `cluster/infrastructure/kanidm/deployment.yaml`
- Metrics API support: metrics-server in `cluster/infrastructure/metrics-server/helmrelease.yaml`
- PostgreSQL operator: CloudNativePG in `cluster/infrastructure/cloudnative-pg/helmrelease.yaml`
- GPU scheduling support: NVIDIA device plugin in `cluster/infrastructure/nvidia-device-plugin/`

This is a controller-heavy repo. Most "application behavior" comes from external operators and Helm charts rather than custom code.

## Application Stack

The app layer is small and service-oriented. Current app directories are:

- `cluster/apps/forgejo/`
- `cluster/apps/immich/`
- `cluster/apps/jellyfin/`
- `cluster/apps/woodpecker/`

Those applications add the following technologies on top of the shared platform:

- Forgejo from `oci://code.forgejo.org/forgejo-helm` in `cluster/apps/forgejo/helmrepo.yaml`
- Immich from `https://immich-app.github.io/immich-charts` in `cluster/apps/immich/helmrepo.yaml`
- Jellyfin from its chart repo in `cluster/apps/jellyfin/helmrelease.yaml`
- Woodpecker CI from its chart repo in `cluster/apps/woodpecker/helmrelease.yaml`
- Copyparty as a hand-written `Deployment` in `cluster/apps/jellyfin/copyparty-deployment.yaml`
- Per-app PostgreSQL clusters via CloudNativePG in `cluster/apps/forgejo/database.yaml` and `cluster/apps/immich/database.yaml`
- Built-in Valkey/Redis-equivalent state for Immich through chart values in `cluster/apps/immich/helmrelease.yaml`

## Kubernetes API Surface

The repository uses a broad but consistent set of Kubernetes APIs:

- core resources such as `Deployment`, `Service`, `ConfigMap`, `PersistentVolumeClaim`, and `Namespace`
- Kustomize assemblies via `kustomize.config.k8s.io/v1beta1`
- Flux APIs via `source.toolkit.fluxcd.io/v1`, `kustomize.toolkit.fluxcd.io/v1`, `helm.toolkit.fluxcd.io/v2`, and image automation resources in the Immich app
- Traefik CRDs such as `IngressRoute`, `IngressRouteTCP`, and `Middleware`
- cert-manager resources such as `Certificate` and `ClusterIssuer`
- ExternalDNS CRDs via `DNSEndpoint`
- 1Password operator resources via `OnePasswordItem`
- CloudNativePG resources via `postgresql.cnpg.io/v1`
- Runtime classes such as `RuntimeClass` for NVIDIA in `cluster/infrastructure/nvidia-device-plugin/runtimeclass.yaml`

## Storage And Runtime Assumptions

Persistent data is standardized around Longhorn:

- default replicated storage via the `longhorn` class
- node-local single-replica storage via `longhorn-local-1r` in `cluster/infrastructure/longhorn/storageclass.yaml`

Stateful components explicitly select storage classes in app manifests, for example:

- `cluster/apps/forgejo/database.yaml`
- `cluster/apps/immich/database.yaml`
- `cluster/apps/immich/pvc.yaml`
- `cluster/apps/jellyfin/media-pvc.yaml`

The repo also assumes:

- IPv6-only cluster networking with `k8s.internal` DNS
- IPv4 egress mediated by the in-cluster proxy
- ingress nodes that run Traefik with `hostNetwork: true`

## Versioning And Pinning Style

Version management is mixed between floating chart ranges and selectively pinned images:

- Helm charts are generally version-ranged, for example `16.0.*` in `cluster/apps/forgejo/helmrelease.yaml` and `v38.0.*` in `cluster/infrastructure/traefik/helmrelease.yaml`
- some container images are pinned directly, for example `kanidm/server:1.8.5` in `cluster/infrastructure/kanidm/deployment.yaml`
- some images are pinned by digest, for example the Squid image in `cluster/infrastructure/http-proxy/http-proxy.yaml`
- Immich image tags are updated through Flux automation, with the live tag reference embedded in `cluster/apps/immich/helmrelease.yaml`

This gives the repo a moderate amount of drift tolerance, but it also means behavior depends on upstream chart release streams unless tighter pinning is added.

## Local Tooling

Contributor tooling is intentionally minimal:

- `flake.nix` provides `fluxcd`, `kubectl`, `cilium-cli`, `kubernetes-helm`, and `kanidm_1_8`
- the common validation loop in `Readme.md` is `nix develop` followed by `kubectl kustomize cluster`
- the repo guidance in `AGENTS.md` prefers `jj` for commit workflow

There is no repo-local package manager such as `npm`, `poetry`, `cargo`, or `go mod`.

## Working Mental Model

The easiest way to understand the stack is:

- Flux and Kustomize decide what gets rendered and in what high-level order
- Helm charts provide most shared services and several apps
- raw YAML fills the gaps where exact control is needed, such as `cluster/infrastructure/http-proxy/http-proxy.yaml`, `cluster/infrastructure/kanidm/deployment.yaml`, and `cluster/apps/jellyfin/copyparty-deployment.yaml`
- docs in `docs/` capture operational context that is critical to using the manifests correctly
