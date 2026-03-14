# STAR Deployment Plan

## Scope

Deploy the following into the existing `jellyfin` namespace and Flux app bundle at `cluster/apps/jellyfin/`:

- Sonarr
- Radarr
- Prowlarr
- A download client recommended for TRaSH-style pathing and import behavior

This plan assumes:

- Resources stay under `cluster/apps/jellyfin/`
- UIs are exposed externally through Traefik
- Access should be protected with `oauth2-proxy` if the apps do not support native OIDC cleanly
- 1Password-backed secrets should be used for OAuth and app credentials
- TRaSH-style configuration should be reflected in storage/path design and sane defaults

## Recommendation Summary

### Auth

Plan to put Sonarr, Radarr, and Prowlarr behind `oauth2-proxy` using the same Kanidm/OIDC pattern already used elsewhere in this repo.

Reasoning:

- The Servarr apps have their own auth/API-key model, but they are not a good fit for repo-standard native OIDC integration.
- This repo already has an established `oauth2-proxy` + Kanidm pattern.
- Reusing that pattern reduces custom auth drift and keeps external access consistent.

Proposed access group:

- `jellyfin_access@idm.yadunut.dev`

If Kanidm client separation is desirable later, each app can still share the same allowed group while using distinct OAuth client credentials.

### Download client

Recommend deploying `qBittorrent`.

Reasoning:

- It is the most common TRaSH-compatible baseline for Sonarr/Radarr automation.
- It supports the category-based workflows commonly used with Prowlarr + Sonarr + Radarr.
- It works well with hardlinks and atomic imports when paths are set up correctly.

Not included in this first pass unless you want it immediately:

- Usenet stack (`SABnzbd` + indexers/providers)
- VPN sidecar or egress isolation

If you want a VPN-enforced torrent client, that should be a deliberate follow-up design step rather than an implicit default.

## Critical Storage Design

### Why this matters

TRaSH-style imports depend on hardlinks and atomic moves. That only works when the download path and library path are on the same filesystem.

If Sonarr/Radarr download to one PVC and import into another PVC, hardlinks will not work and imports will degrade into copy/delete behavior.

### Proposed storage model

Use one shared PVC for both downloads and media content, mounted into the apps with separate subpaths.

Preferred approach:

- Continue using `jellyfin-media` as the shared filesystem
- Create or standardize directory layout inside that volume:
  - `/media`
  - `/downloads`
  - `/downloads/tv`
  - `/downloads/movies`
  - `/media/tv`
  - `/media/movies`

Mount plan:

- Jellyfin:
  - existing media mount remains
- Sonarr:
  - config PVC
  - shared media/download PVC
- Radarr:
  - config PVC
  - shared media/download PVC
- Prowlarr:
  - config PVC
  - optional shared media/download PVC not required for core function
- qBittorrent:
  - config PVC
  - shared media/download PVC

Config PVCs should be separate per app and use `longhorn-local-1r`.

Open item before implementation:

- Confirm whether `jellyfin-media` should be resized before adding downloads onto it.

## Network / Exposure Design

Each app will be exposed through Traefik with TLS, matching existing repo patterns.

Planned components per externally exposed app:

- `Certificate`
- `oauth2-proxy` `HelmRelease`
- `OnePasswordItem` for OAuth client secret material
- `Middleware` for forward auth
- `IngressRoute` or chart-native `Ingress`

Preferred exposure model:

- App service remains internal
- External route goes through `oauth2-proxy`
- Allowed group is `jellyfin_access@idm.yadunut.dev`

Open item before implementation:

- Final hostnames for Sonarr, Radarr, Prowlarr, and qBittorrent

Suggested naming if you want me to choose:

- `sonarr.yadunut.dev`
- `radarr.yadunut.dev`
- `prowlarr.yadunut.dev`
- `qbittorrent.yadunut.dev`

## Secrets Design

Use `OnePasswordItem` resources for:

- OAuth2 Proxy client credentials and cookie secret for each exposed app
- qBittorrent admin credentials
- Any bootstrap API keys or app credentials that are practical to externalize

Important constraint:

- Sonarr/Radarr/Prowlarr generate API keys internally after first boot.
- The plan should not assume those API keys can be fully declared ahead of time unless the chosen charts explicitly support bootstrap injection.

Implementation consequence:

- First pass should handle externally managed secrets cleanly.
- App-generated API keys may require a post-deploy bootstrap step or manual retrieval if cross-app wiring cannot be fully declared up front.

## App Configuration Direction

### Sonarr

Plan to preconfigure the deployment around:

- TV root folder on shared media PVC
- Download path on shared downloads path
- Timezone and network basics
- External auth via proxy
- Persistent config PVC

### Radarr

Plan to preconfigure the deployment around:

- Movie root folder on shared media PVC
- Download path on shared downloads path
- Timezone and network basics
- External auth via proxy
- Persistent config PVC

### Prowlarr

Plan to preconfigure the deployment around:

- Persistent config PVC
- External auth via proxy
- Indexer manager role only

### qBittorrent

Plan to configure:

- Persistent config PVC
- Shared downloads/media PVC
- Category-friendly paths for Sonarr/Radarr
- External auth via proxy if you want the UI public

## Likely Chart / Manifest Approach

There are two viable implementation paths:

1. Reuse app-specific upstream charts where they are mature and predictable.
2. Use a common chart pattern for all four apps for consistency.

Current implementation bias:

- Prefer a consistent chart approach if it does not fight the repo.
- Prefer simple manifests over highly abstracted templating.

Before implementation I will inspect chart quality and choose the path that best fits:

- Flux maintainability
- existing repo conventions
- ability to mount shared PVCs cleanly
- ability to add proxy/TLS/auth resources without hacks

## Planned File Changes

Within `cluster/apps/jellyfin/`, add or update:

- `kustomization.yaml`
- app-specific `HelmRelease` manifests for Sonarr, Radarr, Prowlarr, and qBittorrent
- app-specific config PVC manifests
- optional shared-storage adjustments for `media-pvc.yaml`
- `Certificate` manifests for each externally exposed hostname
- `OnePasswordItem` manifests for each OAuth2 proxy and app secret set
- `oauth2-proxy` `HelmRelease` manifests
- `Middleware` manifests
- `IngressRoute` manifests

No changes should be needed to:

- generated `gotk-*` manifests
- `cluster/apps/jellyfin.yaml` Flux Kustomization object

## Validation Plan

After implementation:

1. Run `kubectl kustomize cluster`
2. Verify all new resources are included under the existing `jellyfin` Flux app
3. Check storage references for same-filesystem import compatibility
4. Confirm proxy env is added anywhere IPv4-only egress is required
5. Confirm no plaintext secrets were added
6. Confirm ingress/auth resources reference the correct namespace and group

After cluster reconcile:

1. Verify app pods come up with PVCs bound
2. Verify each UI is reachable through Traefik and gated by OAuth2 Proxy
3. Verify qBittorrent category paths align with Sonarr/Radarr import expectations
4. Verify Sonarr/Radarr can see the same library and downloads paths

## Risks / Follow-ups

### Bootstrap wiring

Full automated cross-wiring between Prowlarr, Sonarr, Radarr, and qBittorrent may not be fully declarative if app-generated API keys are required.

Possible follow-up:

- one-time bootstrap job or manual first-run setup

### Storage capacity

If the existing `jellyfin-media` PVC is too small, mixing downloads and library storage will create immediate pressure.

Possible follow-up:

- resize existing PVC
- or replace it with a larger shared PVC and migrate mounts

### Torrent networking

If you want torrent egress constrained by VPN, that needs explicit design and likely changes the qBittorrent deployment model.

## Approval Gate

If you approve this plan, I will implement with these defaults unless you override them first:

- `qBittorrent` as the in-cluster download client
- `oauth2-proxy` in front of all exposed UIs
- allowed group `jellyfin_access@idm.yadunut.dev`
- shared `jellyfin-media` filesystem for both `/media` and `/downloads`
- separate config PVC per app on `longhorn-local-1r`
- hostnames defaulting to:
  - `sonarr.yadunut.dev`
  - `radarr.yadunut.dev`
  - `prowlarr.yadunut.dev`
  - `qbittorrent.yadunut.dev`
