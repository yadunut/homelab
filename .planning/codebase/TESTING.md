# Validation And Testing Practices

## What "Testing" Means In This Repo

This repository does not contain a checked-in unit test suite, integration test harness, or CI workflow definition. Validation is mostly:

- local render checks against `cluster/`
- live Flux reconcile/status checks against the cluster
- service-specific smoke tests and debugging commands captured in `docs/`

The baseline commands are documented in `AGENTS.md` and `Readme.md`.

## Tooling

- `flake.nix` defines the recommended dev shell and includes `fluxcd`, `kubectl`, `kubernetes-helm`, `cilium-cli`, and `kanidm_1_8`.
- Standard entrypoint: `nix develop`
- If you are not using the shell, the repo still assumes `kubectl` and `flux` are available for verification.

## Required Baseline Check

The one validation step that is explicitly required before finalizing manifest changes is:

```sh
kubectl kustomize cluster
```

Why it matters here:

- `cluster/kustomization.yaml` is the render root for the whole GitOps tree.
- `AGENTS.md` lists successful render of `cluster/` as part of the final change checklist.
- This catches broken references, malformed YAML, and invalid Kustomize assembly before Flux sees the change.

## Standard Flux Verification

After render succeeds, the repo’s normal operational verification is to check Flux state on-cluster:

```sh
flux reconcile kustomization -n flux-system infrastructure
flux get kustomizations
```

Notes:

- `cluster/infrastructure.yaml` is the primary reconcile target called out in repo docs.
- App-level Flux objects such as `cluster/apps/forgejo.yaml` and `cluster/apps/immich.yaml` depend on infrastructure, so infrastructure health is the first gate.
- For app-specific work, the same pattern can be applied to the relevant Flux `Kustomization` after the infrastructure layer is healthy.

## Service-Specific Smoke Tests And Debugging

This repo keeps practical verification steps in component runbooks instead of a centralized test framework.

### HTTP proxy

`docs/http-proxy-guide.md` contains the main smoke test:

```sh
kubectl run test-proxy --rm -it --image=nicolaka/netshoot -- \
  curl -x "http://http-proxy.kube-system.svc.k8s.internal:8888" -I https://github.com
```

Follow-up checks in the same document:

- `kubectl -n kube-system get pods -l app=http-proxy`
- `kubectl -n kube-system logs -l app=http-proxy --tail=50`

Use these when changing `cluster/infrastructure/http-proxy/http-proxy.yaml` or when adding proxy configuration to workloads such as `cluster/apps/immich/helmrelease.yaml` or `cluster/apps/jellyfin/copyparty-deployment.yaml`.

### NVIDIA GPU support

`docs/nvidia-gpu.md` documents a direct runtime validation path:

- create or run a pod that requests `nvidia.com/gpu`
- inspect output with `kubectl logs gpu-test`
- inspect device plugin state with `kubectl get pods -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin`
- inspect plugin logs with `kubectl logs -n kube-system -l app.kubernetes.io/name=nvidia-device-plugin`

These checks are relevant after changes under `cluster/infrastructure/nvidia-device-plugin/`.

### Woodpecker CI

`docs/woodpecker-ci-debug-summary.md` shows how this repo handles app-specific verification when behavior is subtle:

- apply or reconcile the changed manifest
- observe the HelmRelease revision/runtime state
- capture transient job pod logs quickly
- inspect pod environment with `kubectl get pod ... -o jsonpath=...`

That document is effectively a worked example of the repo’s debugging style for `cluster/apps/woodpecker/helmrelease.yaml`.

## Repo-Specific Validation Heuristics

Before considering a manifest change complete, check the conventions in `AGENTS.md` against the component you touched:

- Reconciliation ordering still makes sense, especially if you changed `cluster/infrastructure.yaml` or any `cluster/apps/*.yaml` wrapper.
- IPv4-dependent workloads include proxy configuration and a correct `NO_PROXY` list.
- Public DNS changes use `DNSEndpoint` resources and keep paired `A` and `AAAA` records where that pattern already exists.
- Storage class selection matches workload behavior, especially when choosing between `longhorn` and `longhorn-local-1r`.
- Secrets remain 1Password-backed via manifests like `onepassworditem.yaml`; no plaintext credentials were added.
- Generated Flux files under `cluster/flux-system/gotk-*.yaml` were not edited by hand.

## What Is Not Present

There is no evidence in the checked-in repo of:

- a CI job that automatically runs `kubectl kustomize cluster`
- YAML lint configuration
- schema validation tooling such as `kubeconform` or `kubeval`
- Helm unit tests or chart tests
- application unit/integration tests

That means contributors should treat manual render and live-cluster verification as the current source of truth, not assume hidden automation exists.

## Practical Validation Sequence

For most manifest changes in this repository, the lowest-friction sequence is:

1. Enter the tool environment with `nix develop`.
2. Render everything with `kubectl kustomize cluster`.
3. Reconcile and inspect Flux with `flux reconcile kustomization -n flux-system infrastructure` and `flux get kustomizations`.
4. Run the relevant service smoke test or log inspection from `docs/http-proxy-guide.md`, `docs/nvidia-gpu.md`, or another component-specific runbook if the change affects runtime behavior.

This matches the repository’s current operating model better than generic Kubernetes advice.
