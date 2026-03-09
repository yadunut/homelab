# Repository Conventions

## Scope

This repository is a Flux GitOps source for a homelab cluster. The authoritative operator guidance is in `AGENTS.md`, and the rendered root is `cluster/`.

## Layout And Assembly

- `cluster/kustomization.yaml` is the top-level Kustomize entrypoint. It assembles `flux-system`, `infrastructure.yaml`, and `apps`.
- `cluster/infrastructure.yaml` is the Flux `Kustomization` that reconciles `./cluster/infrastructure`.
- Each app wrapper such as `cluster/apps/forgejo.yaml`, `cluster/apps/immich.yaml`, `cluster/apps/jellyfin.yaml`, and `cluster/apps/woodpecker.yaml` is a Flux `Kustomization` pointing at its component directory under `cluster/apps/`.
- App wrappers use `spec.dependsOn` to wait for `infrastructure`; that ordering is a repo rule, not an incidental detail.
- `cluster/apps/kustomization.yaml` and `cluster/infrastructure/kustomization.yaml` are plain Kustomize aggregators that list child resources/directories.

## Component Directory Pattern

Most components follow a small, predictable directory shape:

- `cluster/infrastructure/<service>/kustomization.yaml` or `cluster/apps/<service>/kustomization.yaml`
- `helmrepo.yaml` for the upstream chart source when Helm is used
- `helmrelease.yaml` for deployed chart values
- `namespace.yaml` when the component owns its namespace
- Optional supporting objects such as `certificate.yaml`, `onepassworditem.yaml`, `database.yaml`, `pvc.yaml`, `ingressroute.yaml`, `ingressroutetcp.yaml`, or `dnsendpoint.yaml`

Examples:

- `cluster/apps/forgejo/kustomization.yaml` lists namespace, repo, release, database, secret source, certificate, and TCP route.
- `cluster/apps/immich/kustomization.yaml` keeps image automation resources beside the workload manifests.
- `cluster/infrastructure/http-proxy/kustomization.yaml` is minimal and points at a single hand-written manifest file.

## YAML Style And Resource Ordering

- YAML uses 2-space indentation, matching `AGENTS.md` and every manifest under `cluster/`.
- File names are literal and functional. The repo prefers one resource class per file, with names like `helmrelease.yaml`, `namespace.yaml`, and `dnsendpoint.yaml`.
- `kustomization.yaml` files usually list foundational resources first. Typical order is namespace, source, workload, then satellites. See `cluster/apps/forgejo/kustomization.yaml` and `cluster/apps/immich/kustomization.yaml`.
- Resource names usually match the component name. Examples: `metadata.name: forgejo` in `cluster/apps/forgejo/helmrelease.yaml`, `metadata.name: traefik` in `cluster/infrastructure/traefik/helmrelease.yaml`, and `metadata.name: http-proxy` in `cluster/infrastructure/http-proxy/http-proxy.yaml`.

## Flux And Helm Conventions

- Flux-managed `Kustomization` objects use `apiVersion: kustomize.toolkit.fluxcd.io/v1` and usually set `interval: 10m0s`, `prune: true`, and `sourceRef.name: flux-system`. See `cluster/infrastructure.yaml` and `cluster/apps/jellyfin.yaml`.
- Helm releases use `apiVersion: helm.toolkit.fluxcd.io/v2`.
- `helmrelease.yaml` files consistently define `chart.spec`, pin a version range, and set retry-based remediation for both install and upgrade. See `cluster/apps/forgejo/helmrelease.yaml`, `cluster/apps/immich/helmrelease.yaml`, and `cluster/infrastructure/traefik/helmrelease.yaml`.
- `spec.values` edits are expected to stay scoped to the component being changed; this is called out explicitly in `AGENTS.md`.

## Overlay And Patch Usage

- Hand-edited overlays belong in `cluster/flux-system/kustomization.yaml`, not in generated Flux bootstrap files.
- `cluster/flux-system/gotk-components.yaml` and `cluster/flux-system/gotk-sync.yaml` are generated and should not be edited directly.
- JSON6902-style inline patches are already used in `cluster/flux-system/kustomization.yaml` to inject proxy environment variables into Flux controllers. That file is the pattern to extend when generated Flux components need customization.

## Cluster-Specific Manifest Rules

- The cluster domain is `k8s.internal`. Internal service URLs and `NO_PROXY` values use that suffix, as shown in `cluster/infrastructure/traefik/middleware.yaml`, `cluster/apps/jellyfin/copyparty-deployment.yaml`, and `cluster/flux-system/kustomization.yaml`.
- IPv4 egress from IPv6-only pods goes through the in-cluster HTTP proxy. Workloads that need internet access usually carry explicit proxy environment variables. Good examples are `cluster/apps/immich/helmrelease.yaml`, `cluster/apps/jellyfin/helmrelease.yaml`, `cluster/apps/jellyfin/copyparty-deployment.yaml`, and `cluster/apps/woodpecker/helmrelease.yaml`.
- Public DNS is managed by `DNSEndpoint` resources because ExternalDNS is configured for CRD sources. Follow the paired-record style in `cluster/infrastructure/external-dns/dnsendpoint.yaml` and `cluster/infrastructure/garage/dnsendpoint.yaml`.
- Secrets are not stored inline. Components reference 1Password-backed `OnePasswordItem` resources such as `cluster/infrastructure/cert-manager/secret.yaml`, `cluster/infrastructure/traefik/oauth2-proxy-onepassworditem.yaml`, and `cluster/apps/forgejo/onepassworditem.yaml`.
- Storage class choice is intentional. `longhorn-local-1r` is used for node-local stateful data in files like `cluster/apps/forgejo/database.yaml`, `cluster/apps/immich/pvc.yaml`, and `cluster/infrastructure/longhorn/storageclass.yaml`.
- Traefik exposure patterns are split by protocol: HTTP uses `Ingress` or `IngressRoute`, while TCP passthrough uses `IngressRouteTCP`. See `cluster/infrastructure/traefik/ingressroute.yaml` versus `cluster/infrastructure/kanidm/ingressroute.yaml` and `cluster/apps/forgejo/ingressroutetcp.yaml`.

## Documentation Conventions

- Operational knowledge is stored under `docs/` rather than hidden in commit history. `docs/http-proxy-guide.md`, `docs/storage.md`, `docs/nvidia-gpu.md`, and `docs/woodpecker-ci-debug-summary.md` are examples of repo-specific runbooks.
- `Readme.md` is short and points contributors at the core commands and structure instead of duplicating all of `AGENTS.md`.
- Repo guidance prefers concrete file references over abstract descriptions. When documenting a pattern, point at the manifest that already implements it.

## Change Hygiene

- Do not add plaintext secrets.
- Do not edit generated `gotk-*` files.
- Preserve reconciliation order so infrastructure lands before dependent apps.
- Keep new manifests inside the existing directory and file naming scheme unless there is a strong reason to introduce a new pattern.
