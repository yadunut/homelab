# Kubernetes host modules

Homelab owns both `modules/kubernetes/` and the Flux manifests in `cluster/`.
The nix repository consumes `flakeModules.kubernetes` in its existing
flake-parts module graph. Homelab does not import nix.

## Consumer contract

The consuming flake provides:

- `inputs.import-tree` to discover the Kubernetes feature modules.
- The flake-parts `flake.modules` support and `configurations.nixos` machine registry.
- `make-shells` for the existing certificate tooling in the development shell.
- The `secretLib.mkGenerated` module argument and agenix/agenix-rekey NixOS integration.
- `homelab.kubernetes.adminAddress`, the control-plane Yggdrasil address.
- `homelab.kubernetes.publicAddresses`, keyed by `nut-gc1`, `nut-gc2`, and
  `penguin`, with null for nodes without a public endpoint.
- `homelab.kubernetes.wireguardPublicKeys`, keyed by the same node names.

The adapter in nix's `modules/homelab.nix` supplies these values from its host
inventory and existing public secret companions. Private keys, encrypted
secrets, rekeyed host copies, and generator identities remain in nix. The
module evaluates against the consumer's nixpkgs and secret helper.

The exported module includes this cluster's topology and machine role
assignments; it is intentionally specific to this homelab.

## Local validation

Before a homelab change is published, evaluate the nix checkout with an input
override. From the nix checkout, for each affected machine:

```sh
nix eval --raw --no-write-lock-file \
  --override-input homelab git+file:///absolute/path/to/homelab \
  path:.#nixosConfigurations.nut-gc1.config.system.build.toplevel.drvPath
```

Use `nut-gc2` and `penguin` for the other Kubernetes machines. The Git source
must include newly added files (a `jj status` snapshot tracks them in a jj
checkout). A clean directory containing `flake.nix`, `flake.lock`, and
`modules/` can instead be passed as `path:/absolute/path/to/source`; this also
avoids copying Git metadata or filesystem-monitor sockets.

Render Flux manifests from homelab with `kubectl kustomize cluster`.

## Publishing and deployment

1. Commit and publish the homelab module changes.
2. In nix, run `nix flake update homelab` to pin the published revision in
   `flake.lock`, then evaluate the affected machines without an input override.
3. Commit the nix adapter/input changes and updated lockfile.
4. Deploy host changes with Clan from nix. Run `agenix rekey` if secrets or
   recipients change; moving module code alone does not require key rotation.

Flux continues to reconcile `cluster/` from homelab's `main` branch. Host
deployment and Flux reconciliation remain separate operations, so coordinate
their order when changing both sides of a networking or storage interface.
