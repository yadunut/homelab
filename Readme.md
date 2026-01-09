# Homelab GitOps

This repo holds the Flux GitOps configuration for my homelab Kubernetes
cluster. Core manifests live in `cluster/`, and `cluster/kustomization.yaml`
assembles the full tree. Infrastructure components are grouped under
`cluster/infrastructure/<service>/`.

## Prerequisites
- `nix` for the dev shell (recommended).
- `kubectl`, `flux`, `helm`, and `cilium-cli` (available via `nix develop`).
- Cluster access for reconcile commands.

## Common commands
```sh
nix develop
kubectl kustomize cluster
flux reconcile kustomization -n flux-system infrastructure
flux get kustomizations
```

## Repository structure
- `cluster/`: main GitOps manifests and `cluster/kustomization.yaml`.
- `cluster/flux-system/`: Flux bootstrap manifests.
- `cluster/infrastructure/`: service components (each has `helmrepo.yaml`,
  `helmrelease.yaml`, `namespace.yaml`, and `kustomization.yaml`).
- `docs/`: operational notes, including `docs/http-proxy-guide.md`.

## Notes
- Secrets are referenced via 1Password items (see
  `cluster/infrastructure/1password/` and
  `cluster/infrastructure/cert-manager/secret.yaml`); do not commit plaintext
  secrets.
- The cluster is IPv6-only; external access may require the HTTP proxy guide.

## Todo
- [x] traefik
- [x] longhorn
- [x] external dns
- [x] cert-maanger
- [x] longhorn backups
- [x] kanidm
- [ ] expose longhorn website
- [ ] expose traefik website
- [ ] monitoring
- [ ] website
- [ ] figure out why metrics not being reported in lens
