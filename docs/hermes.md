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

The official desktop image (v0.21.5, upstream `749220ef`) is pinned by
multi-architecture digest in all containers. Update these references together.
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
`/opt/data/workspace`; no Docker daemon or Kubernetes service-account token is
mounted. Egress uses direct IPv6 and the cluster's DNS64/NAT64 path. The legacy
HTTP proxy described in AGENTS.md is absent; do not configure Hermes to use it.
Telegram, OpenRouter, and Kanidm were verified reachable directly from the pod.
`HERMES_TELEGRAM_DISABLE_FALLBACK_IPS=true` selects the standard Telegram HTTP
transport. Hermes's custom fallback transport prioritizes IPv4 literals, which
bypass DNS64 and cannot connect from this IPv6-only pod; it also showed repeated
polling and delivery failures while standard hostname requests succeeded.
There is no external gateway API service or Telegram webhook ingress.

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
This avoids the image's moving upstream driver installer and leaves the Hermes
data volume free of a managed driver installation.

Use Hermes Desktop → Settings → Gateways → Remote gateway with
`https://hermes.yadunut.dev` and the existing Kanidm OIDC login. Open the bot's
Screen pane to watch it, take over for logins, and hand control back. The screen
WebSocket uses the existing authenticated dashboard route; no VNC port or new
public hostname is exposed. Desktop login and viewer takeover still require an
end-to-end check from the user's client after deployment.

The desktop shares the gateway's files, credentials and network access; it is
not an isolated sandbox. Use a vision-capable model for screenshot-based work.
The tested upstream image lacks the AT-SPI accessibility bus: `computer-use
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

The image, bootstrap preservation/idempotency, driver checksum/download, and
1440×900 desktop capture and foreground terminal input were verified in a
disposable pod without production
credentials. This does not verify production inference or the Desktop viewer.

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
