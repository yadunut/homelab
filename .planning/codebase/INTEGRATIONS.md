# External Integrations

## Git And Source Of Truth

Flux pulls this repository from Git and treats it as the cluster source of truth:

- `cluster/flux-system/gotk-sync.yaml` points the `GitRepository` named `flux-system` at `https://github.com/yadunut/homelab.git`
- the tracked branch is `main`
- the reconciled path is `./cluster`

That GitHub integration is foundational. If Git access, proxying, or branch conventions change, the whole cluster reconciliation path changes with it.

## Helm Registries And Chart Sources

The repo integrates with multiple upstream chart sources through `HelmRepository` resources. Key examples:

- Forgejo OCI registry in `cluster/apps/forgejo/helmrepo.yaml`
- Immich chart repo in `cluster/apps/immich/helmrepo.yaml`
- oauth2-proxy chart repo in `cluster/infrastructure/oauth2-proxy/helmrepo.yaml`
- Longhorn chart repo in `cluster/infrastructure/longhorn/helmrepo.yaml`
- cert-manager chart repo in `cluster/infrastructure/cert-manager/helmrepo.yaml`
- external-dns chart repo in `cluster/infrastructure/external-dns/helmrepo.yaml`
- CloudNativePG chart repo in `cluster/infrastructure/cloudnative-pg/helmrepo.yaml`
- NVIDIA device plugin chart repo in `cluster/infrastructure/nvidia-device-plugin/helmrepo.yaml`

This repo is therefore dependent on both GitHub and several third-party Helm sources being reachable from the cluster.

## 1Password Secret Delivery

Secrets are not committed directly. The repo integrates with 1Password through the Connect server and operator:

- operator install in `cluster/infrastructure/1password/helmrelease.yaml`
- secret references through `OnePasswordItem` resources such as `cluster/infrastructure/external-dns/onepassworditem.yaml`, `cluster/infrastructure/harbor/onepassworditem.yaml`, and `cluster/apps/woodpecker/onepassworditem.yaml`

Operationally, many workloads depend on 1Password-backed Kubernetes secrets existing before they start successfully.

## Cloudflare

Cloudflare is used in at least two separate ways:

- ACME DNS-01 solving through cert-manager, configured in `cluster/infrastructure/cert-manager/clusterissuer.yaml`
- public DNS record management through external-dns, configured in `cluster/infrastructure/external-dns/helmrelease.yaml`

Cloudflare tokens are sourced through 1Password-backed secrets in:

- `cluster/infrastructure/cert-manager/secret.yaml`
- `cluster/infrastructure/external-dns/onepassworditem.yaml`

Explicit DNS records are managed through `DNSEndpoint` resources because external-dns is set to `sources: [crd]`. Examples:

- `cluster/infrastructure/external-dns/dnsendpoint.yaml`
- `cluster/infrastructure/garage/dnsendpoint.yaml`

## TLS And Certificates

The repo uses cert-manager as the certificate automation layer. Certificates are declared per service, for example:

- `cluster/apps/forgejo/certificate.yaml`
- `cluster/apps/immich/certificate.yaml`
- `cluster/apps/jellyfin/certificate.yaml`
- `cluster/infrastructure/garage/certificate.yaml`
- `cluster/infrastructure/kanidm/certificate.yaml`

Traefik, Harbor, Kanidm, Forgejo, Jellyfin, and Immich all depend on that certificate issuance flow.

## Ingress And Identity

Ingress is standardized on Traefik:

- controller install in `cluster/infrastructure/traefik/helmrelease.yaml`
- HTTP routing via `Ingress` or `IngressRoute`
- TCP TLS passthrough for Kanidm in `cluster/infrastructure/kanidm/ingressroute.yaml`
- TCP SSH exposure for Forgejo in `cluster/apps/forgejo/ingressroutetcp.yaml`

Identity and access control are centered on Kanidm and oauth2-proxy:

- Kanidm deployment in `cluster/infrastructure/kanidm/deployment.yaml`
- Traefik admin protection in `cluster/infrastructure/traefik/oauth2-proxy-helmrelease.yaml`
- Longhorn UI protection in `cluster/infrastructure/longhorn/oauth2-proxy-helmrelease.yaml`
- Jellyfin Copyparty upload protection in `cluster/apps/jellyfin/copyparty-oauth2-proxy-helmrelease.yaml`

Group restrictions are encoded directly in oauth2-proxy values, for example:

- `allowed-group: "traefik_admin@idm.yadunut.dev"` in `cluster/infrastructure/traefik/oauth2-proxy-helmrelease.yaml`
- `allowed-group: "jellyfin_upload@idm.yadunut.dev"` in `cluster/apps/jellyfin/copyparty-oauth2-proxy-helmrelease.yaml`

## Storage And Data Services

The repo integrates with several stateful subsystems:

- Longhorn for block storage in `cluster/infrastructure/longhorn/helmrelease.yaml`
- Garage for object storage and S3-compatible endpoints in `cluster/infrastructure/garage/`
- CloudNativePG for PostgreSQL clusters in `cluster/infrastructure/cloudnative-pg/helmrelease.yaml`

App-level dependencies on those services are direct:

- Forgejo uses CloudNativePG in `cluster/apps/forgejo/database.yaml`
- Immich uses CloudNativePG in `cluster/apps/immich/database.yaml`
- Longhorn backups reference Garage credentials in `cluster/infrastructure/longhorn/backup.yaml`

## Image Registries And Automation

Harbor is the internal registry integration point:

- Harbor install in `cluster/infrastructure/harbor/helmrelease.yaml`
- Woodpecker CI includes Harbor in `NO_PROXY` and build environment settings in `cluster/apps/woodpecker/helmrelease.yaml`

Flux image automation is currently used for Immich:

- image repository in `cluster/apps/immich/image-repository.yaml`
- image policy in `cluster/apps/immich/image-policy.yaml`
- image update automation in `cluster/apps/immich/image-update-automation.yaml`

That means the repo integrates with GHCR at least for `ghcr.io/immich-app/immich-server`.

## Proxy-Mediated Internet Access

The cluster is IPv6-only, so several integrations rely on the in-cluster HTTP proxy:

- proxy implementation in `cluster/infrastructure/http-proxy/http-proxy.yaml`
- Flux controllers patched to use it in `cluster/flux-system/kustomization.yaml`
- Immich machine-learning downloads proxied in `cluster/apps/immich/helmrelease.yaml`
- Harbor egress proxied in `cluster/infrastructure/harbor/helmrelease.yaml`
- Copyparty and Woodpecker build environments proxied in `cluster/apps/jellyfin/copyparty-deployment.yaml` and `cluster/apps/woodpecker/helmrelease.yaml`

This proxy is not an optional optimization. It is part of the integration contract for any workload that must reach IPv4-only endpoints.

## Hardware And Host-Level Dependencies

Not every integration endpoint is inside this repo. Some important dependencies live in adjacent systems:

- node-level Kubernetes and NixOS configuration are maintained in a separate repo referenced by `AGENTS.md`
- NVIDIA runtime setup is documented in `docs/nvidia-gpu.md` and depends on host configuration outside this repository
- storage capacity assumptions are documented in `docs/storage.md` and depend on actual node disks

This means a successful manifest change may still fail operationally if the external host configuration repo has not been kept in sync.

## Application-Specific External Services

Several apps integrate directly with one another:

- Woodpecker authenticates against Forgejo using OAuth credentials from `cluster/apps/woodpecker/onepassworditem.yaml` and server values in `cluster/apps/woodpecker/helmrelease.yaml`
- Forgejo publishes at `https://git.yadunut.dev` and is used as Woodpecker’s Forgejo backend
- Copyparty trusts auth headers from oauth2-proxy in `cluster/apps/jellyfin/copyparty-deployment.yaml`
- Traefik middlewares forward auth decisions to oauth2-proxy services over internal `*.svc.k8s.internal` addresses

These are cross-component integrations even though they are all declared inside the same GitOps repo.

## Operational Reading List

When changing integrations, the highest-value reference files are:

- `AGENTS.md`
- `docs/http-proxy-guide.md`
- `docs/storage.md`
- `docs/nvidia-gpu.md`
- `cluster/flux-system/kustomization.yaml`
- `cluster/infrastructure/external-dns/helmrelease.yaml`
- `cluster/infrastructure/cert-manager/clusterissuer.yaml`
