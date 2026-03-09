# Repository Architecture

## What This Repo Actually Controls

This repository is the Flux GitOps source for the cluster, not the full cluster definition. The Kubernetes host and node-level setup live outside this repo; this repo starts at the point where Flux pulls `./cluster` and reconciles Kubernetes resources from there.

The root assembly is `cluster/kustomization.yaml`. It includes:

- `cluster/flux-system`
- `cluster/infrastructure.yaml`
- `cluster/apps`

That split is the main architectural boundary in this repo:

- `cluster/flux-system/` bootstraps Flux itself and patches generated Flux controller manifests.
- `cluster/infrastructure.yaml` creates a Flux `Kustomization` for the shared platform layer in `cluster/infrastructure/`.
- `cluster/apps/*.yaml` create one Flux `Kustomization` per application in `cluster/apps/<app>/`.

## Reconciliation Flow

The live reconciliation path is explicit and short:

1. `cluster/flux-system/gotk-sync.yaml` defines the `GitRepository` named `flux-system` and a Flux `Kustomization` named `flux-system` with `path: ./cluster`.
2. Flux renders `cluster/kustomization.yaml`.
3. That root kustomization applies `cluster/infrastructure.yaml`, which creates the Flux `Kustomization` named `infrastructure` for `path: ./cluster/infrastructure`.
4. The same root kustomization also applies `cluster/apps/forgejo.yaml`, `cluster/apps/immich.yaml`, `cluster/apps/jellyfin.yaml`, and `cluster/apps/woodpecker.yaml`.
5. Each app Flux `Kustomization` has `dependsOn: [{name: infrastructure}]`, so app rollout is blocked until the shared platform layer is ready.

This means the repo has two different kinds of kustomization files:

- Plain Kustomize assemblies such as `cluster/kustomization.yaml` and `cluster/infrastructure/kustomization.yaml`.
- Flux `Kustomization` resources such as `cluster/infrastructure.yaml` and `cluster/apps/immich.yaml`.

The distinction matters when changing the repo. Files under `cluster/*/kustomization.yaml` usually control YAML composition. Files like `cluster/infrastructure.yaml` control Flux reconciliation behavior.

## Flux Layering

`cluster/flux-system/gotk-components.yaml` and `cluster/flux-system/gotk-sync.yaml` are generated bootstrap artifacts. The repo-specific customization point is `cluster/flux-system/kustomization.yaml`, which wraps those generated manifests and adds JSON patches.

In this repo, `cluster/flux-system/kustomization.yaml` is used to inject proxy environment variables into:

- `source-controller`
- `image-reflector-controller`
- `image-automation-controller`

That patching is a concrete example of the intended layering:

- generated Flux bootstrap stays in `gotk-*`
- local behavior changes are applied in `cluster/flux-system/kustomization.yaml`

## Infrastructure Layer

`cluster/infrastructure/kustomization.yaml` is a plain Kustomize fan-in over the shared platform components:

- `cluster/infrastructure/coredns/`
- `cluster/infrastructure/cilium/`
- `cluster/infrastructure/http-proxy/`
- `cluster/infrastructure/oauth2-proxy/`
- `cluster/infrastructure/longhorn/`
- `cluster/infrastructure/1password/`
- `cluster/infrastructure/cert-manager/`
- `cluster/infrastructure/external-dns/`
- `cluster/infrastructure/traefik/`
- `cluster/infrastructure/garage/`
- `cluster/infrastructure/harbor/`
- `cluster/infrastructure/kanidm/`
- `cluster/infrastructure/metrics-server/`
- `cluster/infrastructure/nvidia-device-plugin/`
- `cluster/infrastructure/cloudnative-pg/`

These directories are not separate Flux objects. They are rendered together by the single Flux `Kustomization` from `cluster/infrastructure.yaml`.

The practical consequence is that intra-infrastructure ordering is mostly expressed by resource semantics, not Flux `dependsOn`. For example:

- CRD- and controller-backed services are installed under `cluster/infrastructure/*/helmrelease.yaml`.
- Cluster-wide helpers or manual resources are colocated with them, such as `cluster/infrastructure/longhorn/storageclass.yaml` and `cluster/infrastructure/cert-manager/clusterissuer.yaml`.
- Lightweight components that are not Helm-based stay as raw manifests, such as `cluster/infrastructure/http-proxy/http-proxy.yaml` and `cluster/infrastructure/coredns/coredns.yaml`.

## App Layer

Each app has two layers:

- a Flux `Kustomization` resource in `cluster/apps/<app>.yaml`
- a plain Kustomize directory in `cluster/apps/<app>/`

Examples:

- `cluster/apps/forgejo.yaml` -> `cluster/apps/forgejo/`
- `cluster/apps/immich.yaml` -> `cluster/apps/immich/`
- `cluster/apps/jellyfin.yaml` -> `cluster/apps/jellyfin/`
- `cluster/apps/woodpecker.yaml` -> `cluster/apps/woodpecker/`

Inside each app directory, the repo mixes the chart release with app-owned supporting resources. Examples:

- `cluster/apps/forgejo/database.yaml` defines a CloudNativePG `Cluster` for Forgejo inside the app directory, while the CNPG operator itself is installed from `cluster/infrastructure/cloudnative-pg/`.
- `cluster/apps/immich/image-repository.yaml`, `cluster/apps/immich/image-policy.yaml`, and `cluster/apps/immich/image-update-automation.yaml` keep Flux image automation beside the app release instead of in a separate automation area.
- `cluster/apps/jellyfin/` includes both the Jellyfin Helm release and a colocated Copyparty deployment plus its ingress and oauth2-proxy resources.

The boundary is therefore "shared platform vs app-owned resources", not "operators only in infrastructure and all stateful resources elsewhere".

## Network, DNS, and Exposure Patterns

The repo’s networking assumptions are encoded in manifests, not just docs:

- `cluster/infrastructure/coredns/coredns.yaml` hardcodes the cluster DNS domain to `k8s.internal` and pins the CoreDNS service `clusterIP`.
- `cluster/infrastructure/http-proxy/http-proxy.yaml` runs a Squid proxy as a `DaemonSet` with `hostNetwork: true`, exposing an in-cluster `Service` for IPv6-only pods that need IPv4 egress.
- `cluster/flux-system/kustomization.yaml` consumes that proxy for Flux controllers.
- `cluster/apps/immich/helmrelease.yaml` shows the same proxy pattern in an application workload for machine-learning downloads.

Ingress is centered on Traefik:

- `cluster/infrastructure/traefik/helmrelease.yaml` runs Traefik with `hostNetwork: true`, `ClusterFirstWithHostNet`, and a node selector for ingress-labeled nodes.
- HTTP exposure uses `Ingress` or `IngressRoute`, for example `cluster/apps/jellyfin/copyparty-ingressroute.yaml`.
- TCP passthrough is used where the backend must terminate TLS itself, for example `cluster/infrastructure/kanidm/ingressroute.yaml`.

Public DNS is managed through ExternalDNS CRDs rather than ingress annotations:

- `cluster/infrastructure/external-dns/helmrelease.yaml` sets `sources: [crd]`.
- DNS records therefore live in explicit `DNSEndpoint` resources such as `cluster/infrastructure/garage/dnsendpoint.yaml`.

## Identity, Secrets, and Protected UIs

Secret material is generally referenced through 1Password custom resources instead of being embedded directly in workload manifests. The pattern appears in files such as:

- `cluster/infrastructure/external-dns/onepassworditem.yaml`
- `cluster/infrastructure/harbor/onepassworditem.yaml`
- `cluster/apps/woodpecker/onepassworditem.yaml`

Protected admin surfaces are commonly fronted by oauth2-proxy and Traefik middleware pairs. Representative examples:

- `cluster/infrastructure/traefik/oauth2-proxy-helmrelease.yaml`
- `cluster/infrastructure/traefik/middleware.yaml`
- `cluster/infrastructure/traefik/ingressroute.yaml`
- `cluster/infrastructure/longhorn/oauth2-proxy-helmrelease.yaml`
- `cluster/infrastructure/longhorn/middleware.yaml`
- `cluster/infrastructure/longhorn/ingressroute.yaml`

## Storage and Stateful Workloads

Longhorn is the storage backend and also defines repo-local policy:

- `cluster/infrastructure/longhorn/helmrelease.yaml` installs the system.
- `cluster/infrastructure/longhorn/storageclass.yaml` adds the `longhorn-local-1r` storage class for node-local, single-replica workloads.
- `cluster/infrastructure/longhorn/backup.yaml` wires Longhorn backups to credentials supplied through a `OnePasswordItem`.

Stateful applications consume those platform pieces directly from their own directories. Examples:

- `cluster/apps/forgejo/database.yaml` uses `longhorn-local-1r`.
- `cluster/apps/immich/helmrelease.yaml` uses PVC-backed persistence and gives its machine-learning cache a `longhorn-local-1r` claim.
- `cluster/infrastructure/kanidm/pvc.yaml` keeps Kanidm state in the infrastructure layer because Kanidm itself is treated as shared identity infrastructure.

## Practical Change Boundaries

When editing this repo, the safest mental model is:

- Change `cluster/flux-system/` only for Flux bootstrap behavior or controller overlays.
- Change `cluster/infrastructure/` for shared services, operators, ingress platform, cluster DNS, proxying, storage, and identity.
- Change `cluster/apps/<app>/` for app-specific releases and resources owned by that app.
- Change `cluster/apps/<app>.yaml` only if the app’s Flux reconciliation settings need to change.

If a new app depends on shared services, the existing pattern is to:

- add a new Flux `Kustomization` file under `cluster/apps/`
- point it at `cluster/apps/<app>/`
- include `dependsOn: [{name: infrastructure}]`

That pattern is already established by every current app entrypoint in `cluster/apps/`.
