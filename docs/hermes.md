# Hermes Agent

Hermes runs one gateway with Telegram and a dashboard at
https://hermes.yadunut.dev. Inference uses the named `custom:litellm` provider at
`http://litellm.litellm.svc.k8s.internal:4000/v1`. A dedicated virtual key is
injected from 1Password. No default model is set in the manifests; select the
model through the UI. Saved UI selections persist across restarts. The dashboard uses
native OIDC with Kanidm; no oauth2-proxy is needed. Its public PKCE client uses
ES256 verification and does not require a client secret.

## Prerequisites

Create a Secure Note named `hermes` in the 1Password `cluster` vault with these
custom fields (field labels must match exactly):

| Field | Value |
| --- | --- |
| `LITELLM_API_KEY` | Dedicated LiteLLM virtual key; use a concealed field |
| `TELEGRAM_BOT_TOKEN` | Token issued by Telegram's `@BotFather` when creating the bot; use a concealed field |
| `TELEGRAM_ALLOWED_USERS` | Your numeric Telegram user ID, or comma-separated numeric IDs; not usernames or group/chat IDs |

The operator creates the `hermes` Kubernetes Secret. All three keys are required
by the Deployment. An empty user allowlist is not a substitute for configuring
your ID. Keep a copy of provider keys in 1Password and never commit them to Git.
The LiteLLM provider reads `LITELLM_API_KEY` through `key_env`, which supports
both inference and model-picker discovery. `discover_models: true` loads the
gateway's available catalog instead of limiting the picker to the active model.
The key is not written into the provider configuration.
Environment-injected secrets take precedence over
the persisted `.env`. Restart the Deployment after secret rotations.

As a Kanidm administrator, register the application and its access group:

```sh
kanidm group create hermes_access
kanidm group add-members hermes_access yadunut
kanidm system oauth2 create-public hermes "Hermes Agent" https://hermes.yadunut.dev
kanidm system oauth2 add-redirect-url hermes https://hermes.yadunut.dev/auth/callback
kanidm system oauth2 update-scope-map hermes hermes_access openid profile email
kanidm system oauth2 prefer-short-username hermes
```

These are initial provisioning commands; inspect existing entries before running
them again. Grant the requested scopes only to `hermes_access`. Kanidm enforces
membership at authorization time; Hermes does not apply its own group allowlist.
All admitted users have access to the shared agent dashboard and credentials.
Do not use `scripts/create-oauth-item.ts` for this client: that script creates a
confidential client, while Hermes requires a public PKCE client.

## Deployment and storage

`cluster/apps/hermes.yaml` depends on infrastructure and LiteLLM. The existing wildcard
`DNSEndpoint` already supplies A and AAAA records for this hostname. Traefik
terminates TLS using a dedicated cert-manager certificate.

The dashboard listens on IPv6 port 9119. Its proxy trust list contains the
internal and CiliumInternalIP addresses of the three ingress nodes, whose Traefik
pods use host networking. Host-to-pod traffic was observed arriving from the
CiliumInternalIP. If these addresses change, update `trusted_proxies` in
`bootstrap-config.yaml`; the init container reconciles that setting on startup.
Only these exact node addresses are trusted, not the entire pod network.

`HERMES_DASHBOARD_WS_HOST=::1` makes the embedded TUI reach the dashboard gateway
over IPv6 loopback. Without it Hermes maps the wildcard `::` listener to
`127.0.0.1`, which refuses connections and produces repeated WebSocket 1006
errors and a "gateway exited" message in dashboard chat.

The official desktop image (`v0.22.7-desktop`, upstream `b200f5bc`) is pinned by
multi-architecture digest in all three containers:
`sha256:e655ce57374faca9404db91c96893a05df18904e508cb98786d59a9c80ee8ecf`.
Update these references together. Docker Hub tag metadata and registry manifest
bytes were independently checked on November 4, 2026; the index includes Linux
amd64 and arm64. This is the desired image, not a claim that it is deployed.
Its s6 entrypoint starts and
supervises the dashboard and gateway and drops application processes to the
`hermes` user. HTTP probes check dashboard availability; they do not prove that
Telegram polling or inference works.

The 10 GiB replicated Longhorn PVC stores `/opt/data`, including memories,
sessions, skills, configuration, and workspace. The single replica uses Recreate
updates to avoid concurrent gateway writers. Do not scale this Deployment above
one replica. Longhorn replication is not a backup.

`bootstrap-config.yaml` seeds `/opt/data/config.yaml` on the first start. The init
container reconciles `dashboard.trusted_proxies`, `providers.litellm`,
`bot_desktop`, and `browser.headed` on later starts. It also enables `computer_use`
and `browser` for CLI/dashboard and Telegram, preserving other tool selections.
Changes to other seed settings do not update an existing
installation: apply subsequent settings through the dashboard or
`hermes config set`. OIDC issuer/client/scopes and the public URL are supplied
through environment overrides on each start.

The seed selects the `custom:litellm` provider without a default model. The init
container migrates legacy direct OpenRouter/llama selections to LiteLLM, adding
the `openrouter/` prefix to an existing OpenRouter model. It removes the obsolete
managed llama provider and the saved `OPENROUTER_API_KEY` from `.env`, preserving
that file's permissions and ownership. Later model choices under LiteLLM persist
across restarts. The deployment neither injects an OpenRouter key nor mounts the
direct llama credential. Terminal tools run locally in the container under
`/opt/data/workspace`; no Docker daemon is mounted. Kubernetes diagnostics use
an explicitly scoped service account and projected credentials as described below.
Egress uses direct IPv6 and the cluster's DNS64/NAT64 path. The legacy
HTTP proxy described in AGENTS.md is absent; do not configure Hermes to use it.
Telegram, OpenRouter, and Kanidm were verified reachable directly from the pod.
`HERMES_TELEGRAM_DISABLE_FALLBACK_IPS=true` selects the standard Telegram HTTP
transport. Hermes's custom fallback transport prioritizes IPv4 literals, which
bypass DNS64 and cannot connect from this IPv6-only pod; it also showed repeated
polling and delivery failures while standard hostname requests succeeded.
There is no external gateway API service or Telegram webhook ingress.

## Tailnet access for remote BB

Kernel-networking Tailscale and a loopback split-DNS sidecar provide the shared
Pod network path for `BB_SERVER_URL=https://yadunut-grep-bb.tail8dce03.ts.net`.
Public egress still uses cluster DNS64/NAT64. This does not install `bb` or
change application credentials. Complete the [tailnet prerequisites and merge
/ rollout gate](hermes-tailscale.md) before merging; enrollment, TUN/nftables,
ACLs and end-to-end remote CLI access require operator validation.

## Bot Screen

The desktop image includes TigerVNC, Xfce and headed Chromium. The screen starts
on the first computer-use or headed-browser call, at 1440×900, and stops after
30 idle minutes. The browser profile persists under `/opt/data/bot-desktop/` on
the existing PVC. The pod requests 2 GiB memory and has a 4 GiB limit; Chromium
also gets a 512 MiB memory-backed `/dev/shm`, counted against that limit.

A separate init container downloads cua-driver 0.28.2 for the node architecture,
verifies its SHA-256, and places the executable in a shared ephemeral volume.
`HERMES_CUA_DRIVER_CMD` selects that binary explicitly. Both amd64 and arm64
archives are pinned; a replacement pod needs GitHub release-download access.
This retains the independently pinned driver and leaves the Hermes data volume
free of a managed driver installation. v0.22.7 now has a PM-managed driver pin
(0.21.0), rather than the older moving installer; the explicit override still
wins. Keep 0.28.2 here rather than silently downgrading it with the image upgrade.

Use Hermes Desktop → Settings → Gateways → Remote gateway with
`https://hermes.yadunut.dev` and the existing Kanidm OIDC login. Open the bot's
Screen pane to watch it, take over for logins, and hand control back. The screen
WebSocket uses the existing authenticated dashboard route; no VNC port or new
public hostname is exposed. Desktop login and viewer takeover still require an
end-to-end check from the user's client after deployment.

The desktop shares the gateway's files, credentials and network access; it is
not an isolated sandbox. Use a vision-capable model for screenshot-based work.
The previously tested v0.21.5 image lacks the AT-SPI accessibility bus: `computer-use
doctor` reports degraded UI-tree inspection, although X11 screen capture works.
Use visual coordinates when accessibility elements are unavailable; browser
tasks can use the browser toolset. Background typing returns
`background_unavailable` on this desktop; retry with `delivery_mode: foreground`.
Foreground input targets the bot's virtual desktop, not the user's laptop.

Operator checks (the CLI wrapper runs these as the Hermes runtime user):

```sh
kubectl -n hermes exec deployment/hermes -c hermes -- hermes computer-use screen status
kubectl -n hermes exec deployment/hermes -c hermes -- hermes computer-use screen start
kubectl -n hermes exec deployment/hermes -c hermes -- hermes computer-use doctor
kubectl -n hermes exec deployment/hermes -c hermes -- hermes computer-use screen stop
```

For v0.21.5, the image, bootstrap preservation/idempotency, driver checksum/download,
and 1440×900 desktop capture and foreground terminal input were verified in a
disposable pod without production credentials. Those checks do not constitute a
v0.22.7 runtime test or verify production inference or the Desktop viewer.

## v0.22.7 upgrade gate

This upgrade changes the three image pins only (plus comments, documentation and
an offline regression test). It leaves storage, bootstrap logic, driver 0.28.2,
OIDC, IPv6 transport, resource limits and Kubernetes RBAC unchanged.

Compatibility checks against upstream tag `v0.22.7` (`b200f5bc60e31588ba2cb60e288029c4a54ba5fa`):

- Imported `_get_platform_tools` from the fetched source using the existing
  container's interpreter and a scratch-only `HOME`/`HERMES_HOME`; exercised CLI
  and Telegram default resolution and explicit browser/computer-use lists with
  `include_default_mcp_servers=False`. This is not a test of the new image's
  dependency environment or the full bootstrap against production data.
- Inspected `Dockerfile`, `docker/main-wrapper.sh`, s6 dashboard service and
  entrypoint wiring: `/opt/hermes/.venv/bin/python`, the `hermes` user,
  `/opt/data`, root entrypoint followed by privilege drop, and `gateway run`
  remain supported. Registry configs for both architectures retain these
  environment paths and `/opt/hermes/docker/entrypoint-dispatch.sh`.
- Confirmed source still consumes the dashboard bind/IPv6 WebSocket override,
  public URL, self-hosted OIDC variables and Telegram fallback-IP disable flag.
- Checked the existing 0.28.2 binary's `manifest` against v0.22.7's actual driver
  contract checker: passes. No driver service or new desktop session was started.
  The source still honors `HERMES_CUA_DRIVER_CMD` before the PM-managed driver.
- The image-pin regression test failed on the old digest and passed after the
  update. Both app and root Kustomize renders passed. These are offline checks.

No new-image runtime test was performed: the local Docker daemon is unavailable,
and this agent's Kubernetes access does not permit creating test pods or exec.
Before accepting the release, an operator should smoke-test an isolated instance
with a restored copy of the data and without production bot/provider credentials.
The image's PM/boot code may refresh dependencies under `/opt/data/installs`;
existing configuration, plugins and database migrations still require a real
upgrade test. Do not interpret successful rendering or dashboard HTTP probes as
proof of OIDC, Telegram, inference or desktop compatibility.

### Backup before push or reconciliation

The patch does not create a backup or change the live cluster. Because Flux may
auto-reconcile a pushed commit, complete this gate **before pushing to main**:

1. Have an authorized operator pause reconciliation and stop the gateway and all
   other writers to `hermes-data`, accounting for any named-profile processes.
   Schedule downtime; never run the old and new gateways against the same PVC.
2. Take an application-consistent backup of the whole `/opt/data` PVC, including
   hidden files, SQLite databases and their WAL/SHM files, configuration, profiles,
   sessions, skills, workspace, browser state and install state. Do not copy a
   live SQLite database with a plain tar/cp operation and assume it is consistent.
   Use a supported storage backup after quiescing writers; a Longhorn replica or
   same-volume snapshot alone is not an independent backup.
3. Store the backup off-volume in encrypted, access-controlled storage, verify
   completion/integrity and a restore to a separate volume, and record the backup
   ID and old image digest. `.env`, OAuth tokens, browser sessions and logs can
   contain secrets: never attach the archive to chat or commit it to Git.
4. Only then push/reconcile at the operator's discretion. Confirm bootstrap,
   gateway and dashboard startup; check authorized/unauthorized OIDC login,
   streaming inference, Telegram delivery, desktop capture/input and persistence.

Rollback image for **all three** containers:
`nousresearch/hermes-agent@sha256:b27ce2c14a6bf47070c562f80b0950a9808bdee1baec42d68f0e5a013d385290`
(v0.21.5). If new code has migrated persisted data, an image-only rollback may
not be safe: stop writers, restore the verified pre-upgrade backup and old pins
together, then resume reconciliation. Do not restore over an active gateway.

Repeat the offline checks from the repository root:

```sh
/opt/data/home/.local/bin/kubectl kustomize cluster >/dev/null
/opt/data/home/.local/bin/kubectl kustomize cluster/apps/hermes >/dev/null
```


## Read-only Kubernetes diagnostics

The dedicated `hermes/hermes` ServiceAccount is bound to the explicit
`hermes-diagnostics` ClusterRole. It allows cluster-wide `get`, `list`, and
`watch` on pods, nodes, namespaces, events (core and `events.k8s.io`), Deployments,
ReplicaSets, StatefulSets, DaemonSets, Jobs, CronJobs, and these Flux resources:
GitRepositories, HelmRepositories, HelmCharts, Buckets, OCIRepositories,
Kustomizations, and HelmReleases. Pod logs have `get` only.

There are no wildcard rules, Secret or ConfigMap API reads, writes, exec,
attach, port-forward, proxy, impersonation, or RBAC management permissions.
Services, endpoints, storage, metrics, other custom resources, and Flux image
or notification resources are deliberately outside this initial scope.
Commands such as `kubectl describe` can report permission errors when they try
related resources beyond the allowlist; prefer targeted `get -o yaml` and logs.
Flux reconciliation and deployment must still be performed by an operator;
Hermes can inspect Flux objects using kubectl, not mutate them.

Both the Pod and ServiceAccount keep `automountServiceAccountToken: false`.
Only the main `hermes` container mounts `/var/run/hermes-kubernetes`, containing
an explicitly projected, pod-bound API token (requested lifetime 3600 seconds;
API-server policy determines the actual lifetime) and `kube-root-ca.crt` CA.
The audience is omitted deliberately to use the API server's default audience.
Kubelet rotates the token; the directory is mounted directly, without `subPath`,
so rotations remain visible. Mode `0444` lets the runtime user read it after s6
drops privileges. Init containers do not mount the token, CA, or kubeconfig.
The kubelet supplies the CA ConfigMap projection without granting this service
account permission to read ConfigMaps through the API.

`KUBECONFIG=/etc/hermes-kubernetes/config` selects a generated, non-secret
ConfigMap. It references `tokenFile` and the CA file rather than embedding or
copying credentials, and verifies TLS against
`https://kubernetes.default.svc.k8s.internal:443`. No kubeconfig or token is
written to the data PVC. Its default namespace is `hermes`; use `-A` or `-n`
when inspecting other workloads.

kubectl **v1.35.10** is installed separately at
`/opt/data/home/.local/bin/kubectl` on the existing data PVC. It survives Pod
replacement; the Deployment does not download or mount a separate binary.
Use the absolute path if this directory is not on PATH. A fresh PVC requires
reinstalling a checksum-verified binary for the node architecture. If scheduling
moves the Pod between architectures, replace the binary accordingly.
Before rollout, verify every API server is within one minor version of this
client; the live server version was not available during implementation.

Read-only is not equivalent to non-sensitive: workload specs, annotations,
Flux values, events, and logs can contain credentials or private data even when
Secret API reads are denied. All agent tools and desktop processes inside the
main container share this access. Do not paste tokens or unredacted sensitive
logs into chat. This RBAC does not isolate tools within that container or revoke
credentials the application already receives through other mechanisms.

### Validation and rollout gate

Offline checks (requires kubectl):

```sh
kubectl kustomize cluster >/dev/null
kubectl kustomize cluster/apps/hermes >/dev/null
```

Review the rendered resources for the exact RBAC allowlist, credential mount
isolation and rotation, and kubeconfig TLS/tokenFile configuration. Rendering
and static review do not prove effective live RBAC, token rotation, or pod startup.

After the operator-approved Flux rollout, run from the main Hermes container
(or have an operator invoke these commands there using their own exec access):

```sh
kubectl version --client
kubectl auth can-i get pods --all-namespaces          # yes
kubectl auth can-i get pods --subresource=log -A      # yes
kubectl auth can-i get nodes                         # yes
kubectl auth can-i get kustomizations.kustomize.toolkit.fluxcd.io -A # yes
kubectl auth can-i get secrets -A                    # no
kubectl auth can-i get configmaps -A                 # no
kubectl auth can-i create pods --subresource=exec -A # no
kubectl auth can-i get pods --subresource=exec -A    # no
kubectl auth can-i create pods --subresource=attach -A # no
kubectl auth can-i create pods --subresource=portforward -A # no
kubectl auth can-i get nodes --subresource=proxy     # no
kubectl auth can-i patch deployments.apps -A        # no
kubectl auth can-i create deployments.apps -A       # no
kubectl auth can-i delete pods -A                    # no
kubectl get nodes
kubectl get pods -A
kubectl get events -A
kubectl get kustomizations.kustomize.toolkit.fluxcd.io -A
kubectl get helmreleases.helm.toolkit.fluxcd.io -A
kubectl -n hermes logs deployment/hermes -c hermes --tail=20
```

Confirm the main process can read the token/CA without displaying their contents,
that no init container has the credential mounts, and that reads still succeed
after observing a projected-token rotation. If any forbidden `can-i` returns
`yes`, inspect additional cluster bindings before accepting the rollout. Test
as the actual runtime user: an operator's successful API read does not validate
Hermes access. No live verification or deployment was performed for this change.

## Flux management

Flux manages Hermes after LiteLLM is ready. The manual rollout used temporary
suspension and a `kustomize.toolkit.fluxcd.io/reconcile: disabled` annotation;
adoption removes both holds after the new source revision is available.

## Validation

The manual LiteLLM migration verified Hermes's runtime provider resolution,
1Password virtual-key lookup, non-streaming and streaming GLM inference, and
dashboard readiness. The old OpenRouter key is absent from both the container
environment and saved `.env`. Telegram end-to-end delivery was not retested.

Render before committing:

```sh
kubectl kustomize cluster >/dev/null
kubectl kustomize cluster/apps/hermes >/dev/null
```

After deploying through Flux, verify:

```sh
kubectl -n hermes rollout status deployment/hermes
kubectl -n hermes exec deployment/hermes -- hermes gateway status
kubectl -n hermes logs deployment/hermes -c hermes --tail=100
```

In a private browser window, confirm the dashboard requires login, an authorized
Kanidm account succeeds, and an account outside `hermes_access` cannot authorize.
Check that session cookies carry Secure and that dashboard chat connects. Send a
test message yourself to the Telegram bot, confirm an unlisted sender cannot use
it, then restart the pod and confirm configuration and conversation state persist.

## Upstream references

- [Docker deployment](https://hermes-agent.nousresearch.com/docs/user-guide/docker/)
- [Dashboard authentication](https://hermes-agent.nousresearch.com/docs/user-guide/features/web-dashboard/)
- [Model providers](https://hermes-agent.nousresearch.com/docs/integrations/providers/)
- [Telegram](https://hermes-agent.nousresearch.com/docs/user-guide/messaging/telegram/)
- [Kanidm OAuth2 and public clients](https://kanidm.github.io/kanidm/stable/integrations/oauth2.html)
