# Repository Structure

## Top-Level Layout

The repo is organized around one deployable tree, one documentation area, and two workflow-specific metadata areas.

| Path | Role in this repo |
| --- | --- |
| `cluster/` | Deployable Flux/Kustomize manifests for the homelab cluster |
| `docs/` | Operational notes tied to repo behavior, such as proxying and storage |
| `openspec/` | OpenSpec change artifacts and archived change history |
| `.planning/codebase/` | Generated codebase mapping documents like this one |
| `.codex/skills/` | Repo-local Codex skills used by agents working in this repository |
| `Readme.md` | Short operator-facing repo overview and common commands |
| `AGENTS.md` | Repository-specific constraints for agents editing manifests |
| `flake.nix` | Nix development shell for tool setup |

`spec/` currently exists but has no files, so it is not part of the active GitOps layout today.

## Deployable Tree: `cluster/`

`cluster/` is the only tree rendered by Flux from `cluster/flux-system/gotk-sync.yaml`. Its internal shape is:

- `cluster/kustomization.yaml`
- `cluster/flux-system/`
- `cluster/infrastructure.yaml`
- `cluster/infrastructure/`
- `cluster/apps/`

Those paths serve different roles:

- `cluster/kustomization.yaml` is the root plain Kustomize assembly.
- `cluster/flux-system/` contains Flux bootstrap YAML plus repo-specific overlays.
- `cluster/infrastructure.yaml` is a Flux `Kustomization` resource that points at `cluster/infrastructure/`.
- `cluster/infrastructure/` is the shared platform manifest tree.
- `cluster/apps/` contains both the app Flux entrypoints and the app manifest directories.

## `cluster/flux-system/`

This directory is small but special:

- `cluster/flux-system/gotk-components.yaml`
- `cluster/flux-system/gotk-sync.yaml`
- `cluster/flux-system/kustomization.yaml`

Use it like this:

- Treat `cluster/flux-system/gotk-components.yaml` and `cluster/flux-system/gotk-sync.yaml` as generated Flux output.
- Put repo-specific overlays in `cluster/flux-system/kustomization.yaml`.

In this repo, `cluster/flux-system/kustomization.yaml` is used to patch Flux controllers with HTTP proxy environment variables for IPv4 egress.

## `cluster/infrastructure/`

This directory is a flat collection of shared components. The aggregator file is `cluster/infrastructure/kustomization.yaml`, and each child directory is a component boundary:

- `cluster/infrastructure/1password/`
- `cluster/infrastructure/cert-manager/`
- `cluster/infrastructure/cilium/`
- `cluster/infrastructure/cloudnative-pg/`
- `cluster/infrastructure/coredns/`
- `cluster/infrastructure/external-dns/`
- `cluster/infrastructure/garage/`
- `cluster/infrastructure/harbor/`
- `cluster/infrastructure/http-proxy/`
- `cluster/infrastructure/kanidm/`
- `cluster/infrastructure/longhorn/`
- `cluster/infrastructure/metrics-server/`
- `cluster/infrastructure/nvidia-device-plugin/`
- `cluster/infrastructure/oauth2-proxy/`
- `cluster/infrastructure/traefik/`

Most component directories follow the same small-file pattern:

- `kustomization.yaml` to list local resources
- `namespace.yaml` when the component owns a namespace
- `helmrepo.yaml` and `helmrelease.yaml` when the component is Helm-managed
- extra resource files for component-specific objects

Examples:

- `cluster/infrastructure/cert-manager/` includes `secret.yaml`, `clusterissuer.yaml`, and `certificate.yaml` in addition to its Helm resources.
- `cluster/infrastructure/http-proxy/` is a single-file raw-manifest component using `http-proxy.yaml`.
- `cluster/infrastructure/coredns/` is also a raw-manifest component with `coredns.yaml`.
- `cluster/infrastructure/longhorn/` extends beyond the usual Helm files with `storageclass.yaml`, `backup.yaml`, oauth2-proxy resources, and ingress middleware.

## `cluster/apps/`

`cluster/apps/` has two distinct file types in one directory:

1. Flux app entrypoints:
   - `cluster/apps/forgejo.yaml`
   - `cluster/apps/immich.yaml`
   - `cluster/apps/jellyfin.yaml`
   - `cluster/apps/woodpecker.yaml`
2. App manifest directories:
   - `cluster/apps/forgejo/`
   - `cluster/apps/immich/`
   - `cluster/apps/jellyfin/`
   - `cluster/apps/woodpecker/`

`cluster/apps/kustomization.yaml` is only a plain Kustomize list of the Flux entrypoint files. The deployable app manifests are inside the matching subdirectories.

Each app directory owns all supporting resources needed by that app, not just the Helm release. Representative layouts:

- `cluster/apps/forgejo/` contains `database.yaml`, `onepassworditem.yaml`, `certificate.yaml`, and `ingressroutetcp.yaml` next to `helmrelease.yaml`.
- `cluster/apps/immich/` contains persistence, database, and Flux image automation files: `pvc.yaml`, `database.yaml`, `image-repository.yaml`, `image-policy.yaml`, and `image-update-automation.yaml`.
- `cluster/apps/jellyfin/` contains both the main app and the Copyparty sidecar service resources such as `copyparty-deployment.yaml` and `copyparty-ingressroute.yaml`.
- `cluster/apps/woodpecker/` contains a smaller app bundle with `serviceaccount.yaml`, `onepassworditem.yaml`, and `certificate.yaml`.

## `docs/`

`docs/` is not rendered by Flux; it is operator documentation that explains repo-specific runtime assumptions.

Current files include:

- `docs/http-proxy-guide.md`
- `docs/storage.md`
- `docs/nvidia-gpu.md`
- `docs/jellyfin-lectures.md`
- `docs/woodpecker-ci-debug-summary.md`
- `docs/copyparty/README.md`

The most architecture-relevant documents today are:

- `docs/http-proxy-guide.md` for the IPv6-only to IPv4 egress pattern
- `docs/storage.md` for Longhorn and Garage capacity notes

## Workflow and Planning Areas

These paths support engineering workflow rather than cluster reconciliation:

- `.planning/codebase/` is for generated repository maps and analysis artifacts.
- `openspec/changes/archive/` stores completed OpenSpec change records.
- `.codex/skills/openspec-*/SKILL.md` contains repo-local agent workflows for OpenSpec tasks.

They are useful context when working in the repo, but none of them are applied to the cluster.

## Common Editing Targets

When deciding where a change belongs, this repo’s directory structure implies the following:

- Add or change shared platform services under `cluster/infrastructure/<component>/`.
- Add or change app-owned resources under `cluster/apps/<app>/`.
- Add a new app by creating both `cluster/apps/<app>.yaml` and `cluster/apps/<app>/`.
- Adjust Flux bootstrap behavior in `cluster/flux-system/kustomization.yaml`, not in generated `gotk-*` files.
- Put operator notes in `docs/` when a manifest change introduces a non-obvious runtime requirement.

## File Naming Conventions Already In Use

The repository is consistent enough that common filenames are meaningful:

- `kustomization.yaml` means local composition, not Flux reconciliation.
- top-level `cluster/apps/*.yaml` and `cluster/infrastructure.yaml` are Flux `Kustomization` resources.
- `helmrepo.yaml` and `helmrelease.yaml` indicate Helm-managed components.
- `namespace.yaml` usually appears when the component owns its namespace lifecycle.
- `onepassworditem.yaml` marks 1Password-backed secret sourcing.
- `certificate.yaml`, `ingressroute.yaml`, `ingressroutetcp.yaml`, `middleware.yaml`, and `dnsendpoint.yaml` signal exposure and networking resources colocated with the owning component.

That naming consistency is what makes the repo easy to scan: once you know the component directory, the likely resource files are predictable.
