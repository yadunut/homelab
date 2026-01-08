# Repository Guidelines

## Project Structure & Module Organization
This repo is a Flux GitOps layout for a homelab Kubernetes cluster. Core manifests live in `cluster/`, with `cluster/kustomization.yaml` assembling the tree. `cluster/flux-system/` contains the Flux bootstrap manifests, while `cluster/infrastructure/` groups infra components by service (for example `cluster/infrastructure/traefik/`). Each component directory typically includes `helmrepo.yaml`, `helmrelease.yaml`, `namespace.yaml`, and `kustomization.yaml` plus any service-specific resources. Operational notes live in `docs/` (see `docs/http-proxy-guide.md`). The Nix dev shell is defined in `flake.nix`.

## Build, Test, and Development Commands
- `nix develop`: enter the dev shell with `flux`, `kubectl`, `helm`, and `cilium-cli`.
- `kubectl kustomize cluster`: render the full manifest tree locally for review.
- `flux reconcile kustomization -n flux-system infrastructure`: trigger a reconcile (requires cluster access).

## Coding Style & Naming Conventions
- YAML uses 2-space indentation; keep structure consistent with existing Flux and HelmRelease patterns.
- Component directories are named after the service (`cluster/infrastructure/external-dns`).
- Use predictable filenames: `helmrepo.yaml`, `helmrelease.yaml`, `namespace.yaml`, `kustomization.yaml`.
- Resource names should match the component name (`metadata.name: traefik`).
- Keep `spec.values` edits focused to the service you are changing.

## Testing Guidelines
There is no automated test suite in the repo. Validate changes by rendering manifests (`kubectl kustomize cluster`) and, if you have cluster access, by reconciling with Flux and reviewing status (`flux get kustomizations`).

## Commit & Pull Request Guidelines
Commits are short, lowercase, and imperative (examples: "add traefik", "migrate cilium to flux"). Keep one topic per commit and mention the component early in the message. PRs should include a brief summary, affected components/paths, and validation notes (render commands or reconcile output). Link related issues when applicable; screenshots are only needed for UI-facing changes.

## Security & Configuration Tips
Secrets are referenced via 1Password items (see `cluster/infrastructure/1password/` and `cluster/infrastructure/cert-manager/secret.yaml`); do not commit plaintext secrets. The cluster is IPv6-only, so external access may require the HTTP proxy described in `docs/http-proxy-guide.md`.
