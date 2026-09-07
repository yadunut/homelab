# Hermes Agent

Hermes runs one gateway with Telegram and a dashboard at
https://hermes.yadunut.dev. OpenRouter supplies inference. The dashboard uses
native OIDC with Kanidm; no oauth2-proxy is needed. Its public PKCE client uses
ES256 verification and does not require a client secret.

## Prerequisites

Create a Secure Note named `hermes` in the 1Password `cluster` vault with these
custom fields (field labels must match exactly):

| Field | Value |
| --- | --- |
| `OPENROUTER_API_KEY` | API key from https://openrouter.ai/settings/keys; use a concealed field |
| `TELEGRAM_BOT_TOKEN` | Token issued by Telegram's `@BotFather` when creating the bot; use a concealed field |
| `TELEGRAM_ALLOWED_USERS` | Your numeric Telegram user ID, or comma-separated numeric IDs; not usernames or group/chat IDs |

The operator creates the `hermes` Kubernetes Secret. All three keys are required
by the Deployment. An empty user allowlist is not a substitute for configuring
your ID. Keep keys in 1Password rather than putting them in dashboard settings
or committing them to Git. Environment-injected secrets take precedence over
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

`cluster/apps/hermes.yaml` depends on infrastructure. The existing wildcard
`DNSEndpoint` already supplies A and AAAA records for this hostname. Traefik
terminates TLS using a dedicated cert-manager certificate.

The dashboard listens on IPv6 port 9119. Its proxy trust list contains the
internal addresses of the three ingress nodes, whose Traefik pods use host
networking. Update the persisted dashboard `trusted_proxies` setting if those
addresses change. Confirm secure cookies during the initial login test; if
traffic is SNATed to a different address, verify the observed source before
adding that exact address to the trust list.

The official image is pinned by multi-architecture digest in both the init and
main containers. Update both references together. Its s6 entrypoint starts and
supervises the dashboard and gateway and drops application processes to the
`hermes` user. HTTP probes check dashboard availability; they do not prove that
Telegram polling or inference works.

The 10 GiB replicated Longhorn PVC stores `/opt/data`, including memories,
sessions, skills, configuration, and workspace. The single replica uses Recreate
updates to avoid concurrent gateway writers. Do not scale this Deployment above
one replica. Longhorn replication is not a backup.

`bootstrap-config.yaml` is copied only when `/opt/data/config.yaml` does not
exist. Dashboard edits therefore persist across restarts. Changes to this seed
file do not update an existing installation: apply subsequent settings through
the dashboard or `hermes config set`. OIDC issuer/client/scopes and the public URL
are supplied through environment overrides on each start.

The seed selects OpenRouter as provider and leaves the model at Hermes's default.
Choose your desired OpenRouter model in the dashboard's Models page before the
first conversation. Terminal tools run locally in the container under
`/opt/data/workspace`; no Docker daemon or Kubernetes service-account token is
mounted. Standard HTTP proxy variables and an explicit Telegram proxy provide
IPv4 egress. There is no external gateway API service or Telegram webhook ingress.

## Validation

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
