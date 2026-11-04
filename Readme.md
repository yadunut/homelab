# Homelab Kubernetes

This repo holds the NixOS host modules and Flux GitOps configuration for my
homelab Kubernetes cluster. Host modules live in `modules/kubernetes/` and are
imported by the separate nix repository. Core manifests live in `cluster/`,
and `cluster/kustomization.yaml` assembles the full tree. Infrastructure components are grouped under
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
- `docs/`: operational notes.
- `modules/kubernetes/`: Kubernetes services, cluster topology, host networking,
  storage prerequisites, and GPU integration.
- `modules/kubernetes.nix`: the `flakeModules.kubernetes` export consumed by nix.

See [host module integration](docs/host-modules.md) for the import contract,
local validation, and deployment workflow. Hardware, encrypted host secrets,
and Clan deployment remain in the nix repository.

## Notes
- Secrets are referenced via 1Password items (see
  `cluster/infrastructure/1password/` and
  `cluster/infrastructure/cert-manager/secret.yaml`); do not commit plaintext
  secrets.
- The cluster is IPv6-only; CoreDNS DNS64 and per-node Jool NAT64 provide access to IPv4-only internet endpoints.

## Todo
- [x] traefik
- [x] longhorn
- [x] external dns
- [x] cert-maanger
- [x] longhorn backups
- [x] kanidm
- [x] expose longhorn website
- [x] expose traefik website
- [x] oauth proxy
- [x] harbor
- [x] forjego
- [x] immich
- [ ] pastebin of some kind
- [ ] kanidm operator
- [x] woodpecker
- [ ] monitoring
- [ ] website
- [ ] figure out why metrics not being reported in lens
