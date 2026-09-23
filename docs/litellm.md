# LiteLLM gateway

Initially validated with kubectl on 2026-09-22, then registered in
`cluster/apps/kustomization.yaml` for Flux management. LiteLLM depends on
infrastructure and llama; Hermes depends on LiteLLM.

## Configuration

- Image: LiteLLM v1.101.0, pinned by registry digest in `internal/deployment.yaml`.
- Internal base URL: `http://litellm.litellm.svc.k8s.internal:4000/v1`.
- Public base URL: `https://llm.yadunut.dev/v1`.
- Admin UI: `https://litellm.yadunut.dev/ui`, with native Kanidm OIDC.
- LiteLLM owns the public hostname; llama is reached only through its private
  Kubernetes Service. Hermes uses LiteLLM through its private Kubernetes Service.
- One replica and one worker, with `Recreate` updates to avoid OAuth token writers
  sharing the same file. Updates briefly interrupt the gateway.
- A 1 GiB `longhorn-local-1r` PVC holds renewable ChatGPT OAuth credentials.
  Loss of this non-replicated volume requires a new device login.
- PostgreSQL: three CloudNativePG instances, each with a 5 GiB
  `longhorn-local-1r` volume. PostgreSQL provides replication for keys, users,
  configuration, and usage records. Replication is not a database backup.
- Direct IPv6/DNS64 egress, matching the current llama and Hermes deployments.
  The legacy HTTP proxy in AGENTS.md is absent from the live cluster.
- Existing wildcard `DNSEndpoint` A/AAAA records cover both public hostnames.
- Explicit model selection, no automatic fallback, retries, or paid background
  model health checks. Kubernetes probes only check gateway readiness/liveness.

### ChatGPT compatibility patch

`internal/patch-chatgpt.py` patches the pinned release's sync and async HTTP
handlers in an init container. The subscription backend requires SSE upstream,
but LiteLLM incorrectly promotes that requirement to the caller's streaming
preference. Non-streaming Responses then return SSE, and Chat Completions fail
while converting that unexpected stream. The patch preserves the caller's flag
for `chatgpt`, allowing the provider's existing SSE aggregation code to run.
Explicit streaming and other providers retain their original behavior.

The init container copies the patched module to an ephemeral volume; only that
module is mounted into the application. No provider credentials are given to the
init container. It checks for exactly two expected source sites and compiles the
result before starting the gateway. Review this patch, both image pins, and the
Python module mount path together on upgrades; remove it when upstream fixes the
behavior. The original image itself is unchanged.

| Client model | Upstream | Initial test endpoint |
| --- | --- | --- |
| `qwen3.8-27b` | Existing local llama.cpp service | `/v1/chat/completions` |
| `openrouter/<provider>/<model>` | Any available OpenRouter model, e.g. `openrouter/z-ai/glm-5.3-flash` | `/v1/chat/completions` for chat models |
| `codex` | ChatGPT subscription `gpt-6-astra` | `/v1/responses` |

The Codex alias uses the requested GPT-6 Astra model. Confirm subscription
availability and LiteLLM connector compatibility during manual testing.
OpenRouter uses provider-specific wildcard routing: send the full model name
prefixed with `openrouter/`; no config change is needed to select another model.
Availability and supported operations still depend on OpenRouter and your key.
The deployed release expands the OpenRouter wildcard in `/v1/models`, so clients
can discover model IDs; availability can change upstream. Public ingress exposes chat and
Responses routes, not embeddings or image-generation endpoints.
The subscription connector is distinct from the separately billed OpenAI API;
no OpenAI API key is configured here. Chat Completions bridging for `codex` also
needs verification before using it from Hermes.

## Credentials

Create a Secure Note named `litellm` in the 1Password `cluster` vault with these
concealed fields:

| Field | Value |
| --- | --- |
| `LITELLM_MASTER_KEY` | A new random gateway key, prefixed `sk-`; use at least 32 random bytes encoded as hex after the prefix |
| `OPENROUTER_API_KEY` | Your OpenRouter API key |

The separate `llama` OnePasswordItem syncs the existing `cluster/llama` item into
this namespace. The gateway reads the first line of `API_KEYS`.
No provider keys or OAuth tokens belong in Git. Restart the deployment after
1Password key changes have synced, because it reads credentials at startup.

The inference hostname permits only model listing, Chat Completions, and
Responses creation. Use PostgreSQL-backed virtual keys for individual apps;
reserve the master key for administration. The separate admin hostname exposes
the UI and management API, with native Kanidm OIDC for UI sign-in and LiteLLM
authentication for management requests. Usage records include request/response
bodies in PostgreSQL, enabled by `general_settings.store_prompts_in_spend_logs`
with `litellm_settings.turn_off_message_logging: false`. After the configuration
rolls out, new requests show their content on the admin UI Logs page; older logs
are not backfilled. Do not enable debug logging for private requests.

OAuth tokens are written by LiteLLM into `/auth/chatgpt/auth.json` on the PVC,
under UID 1000 with a private directory and file-creation umask. They are mutable
session state, not mounted from the read-only 1Password Secret.

## Admin UI and virtual-key setup

LiteLLM v1.101.0 supports generic OIDC without an Enterprise license for up to
five users. The manifests use native SSO, not oauth2-proxy. Kanidm must restrict
the `litellm` client to `litellm_access`, with only intended UI users added to that
group. The short `preferred_username` identifies users; `yadunut` is the initial
proxy admin. Other users receive LiteLLM's default restricted role. Password and
environment-credential UI login are disabled; the master key remains valid for
administrative API access.

The confidential Kanidm `litellm` client is provisioned with redirect URI
`https://litellm.yadunut.dev/sso/callback` and PKCE enabled in LiteLLM.
The following 1Password items supply the credentials:

| 1Password item | Fields |
| --- | --- |
| `cluster/litellm` | Existing master/OpenRouter keys plus `GENERIC_CLIENT_SECRET` and `LITELLM_SALT_KEY` |
| `cluster/litellm-postgres` | `username=litellm` and a random concealed `password` |

Keep existing database passwords and salts when reprovisioning. Keep
`LITELLM_SALT_KEY` stable: it encrypts credentials stored in the database. The
database OnePasswordItem supplies bootstrap credentials; username must match
the CNPG database owner. Database password rotation requires coordinating CNPG
role credentials and the application, not merely changing the startup secret.

Deploy the database references first and wait for their secrets and the database:

```sh
kubectl apply -f cluster/apps/litellm/internal/database-onepassworditem.yaml
kubectl apply -f cluster/apps/litellm/internal/database.yaml
kubectl -n litellm get secrets litellm litellm-postgres
kubectl -n litellm wait --for=condition=Ready cluster/litellm-postgres --timeout=10m
```

Only after the new fields have synced and PostgreSQL is ready, apply the internal
assembly. The single gateway runs Prisma migrations with the v2 resolver and
refuses to start if migrations fail. `Recreate` prevents overlapping application
versions during migration. This rollout briefly interrupts inference.

```sh
kubectl apply -k cluster/apps/litellm/internal
kubectl -n litellm rollout status deployment/litellm --timeout=10m
```

Validate database readiness, virtual-key generation/revocation, and the Kanidm
authorization redirect before exposing the admin hostname. Then:

```sh
kubectl apply -f cluster/apps/litellm/exposure/admin-certificate.yaml
kubectl -n litellm wait --for=condition=Ready certificate/litellm-admin-tls --timeout=5m
kubectl apply -f cluster/apps/litellm/exposure/admin-ingressroute.yaml
```

Visit `https://litellm.yadunut.dev/ui` and sign in with Kanidm. Verify your admin
role, create separate virtual keys for each client in the UI, and store those
keys in 1Password. Verify an account outside `litellm_access` cannot authorize
the client and unauthenticated management calls are rejected. Clients continue
using `https://llm.yadunut.dev/v1`; they do not use browser OAuth for inference.

## Local validation

```sh
kubectl kustomize cluster >/dev/null
kubectl kustomize cluster/apps/litellm >/dev/null
kubectl kustomize cluster/apps/litellm/internal >/dev/null
kubectl kustomize cluster/apps/litellm/exposure >/dev/null
```

The root build intentionally excludes LiteLLM until Flux adoption. ConfigMap
names include a content hash, so applying a changed config rolls the deployment.

## Manual deployment after review

First create the namespace and secret references:

```sh
kubectl apply -f cluster/apps/litellm/internal/namespace.yaml
kubectl apply -f cluster/apps/litellm/internal/onepassworditem.yaml
kubectl apply -f cluster/apps/litellm/internal/llama-onepassworditem.yaml
kubectl -n litellm get secret litellm llama
```

Wait for both Secrets to exist, then deploy only the internal gateway:

```sh
kubectl apply -k cluster/apps/litellm/internal
kubectl -n litellm logs -f deployment/litellm
```

On first startup, the pinned release initializes the subscription provider and
prints a device-login URL and code in its logs. Complete that login before
waiting for readiness; startup is blocked until authentication finishes. Do not
start a second login concurrently. The startup probe allows roughly thirty minutes
after container startup; if the pod restarts, use the code from the current pod.

After completing login:

```sh
kubectl -n litellm rollout status deployment/litellm --timeout=10m
```

For a later reauthentication on an already running gateway, the following command
uses the pinned authenticator without printing its returned token. Stop other
subscription requests first and do not run this alongside a startup login:

```sh
kubectl -n litellm exec -it deployment/litellm -- python -c 'import os; os.umask(0o077); from litellm.llms.chatgpt.authenticator import Authenticator; auth = Authenticator(); _ = auth.get_access_token(); print("ChatGPT login complete")'
```

Open the verification URL shown and enter the device code in your own browser.
If requested by OpenAI, enable device-code authentication in your account first.
Do not paste credentials or the auth file into logs or this repository. No
public callback route is required. LiteLLM refreshes tokens during later use;
revoked or expired sessions may require this login again.

## Inference verification

In a separate terminal:

```sh
kubectl -n litellm port-forward service/litellm 4000:4000
```

Load the key locally using 1Password CLI (or a private environment-variable
prompt), without typing the secret as a literal shell command:

```sh
export LITELLM_API_KEY="$(op read 'op://cluster/litellm/LITELLM_MASTER_KEY')"
export LITELLM_BASE_URL=http://localhost:4000

# Expect a 4xx response without credentials. No inference should run.
curl -sS -o /dev/null -w '%{http_code}\n' "$LITELLM_BASE_URL/v1/models"
curl -sS -o /dev/null -w '%{http_code}\n' \
  -H 'Authorization: Bearer sk-invalid' "$LITELLM_BASE_URL/v1/models"

# Inspect local/Codex aliases and the expanded OpenRouter model list.
curl --fail-with-body -sS "$LITELLM_BASE_URL/v1/models" \
  -H "Authorization: Bearer $LITELLM_API_KEY"

curl --fail-with-body -sS "$LITELLM_BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"qwen3.8-27b","messages":[{"role":"user","content":"Reply with hello."}],"max_tokens":128}'

curl --fail-with-body -sS "$LITELLM_BASE_URL/v1/chat/completions" \
  -H "Authorization: Bearer $LITELLM_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"openrouter/z-ai/glm-5.3-flash","messages":[{"role":"user","content":"Reply with hello."}],"max_tokens":128}'

curl --fail-with-body -sS "$LITELLM_BASE_URL/v1/responses" \
  -H "Authorization: Bearer $LITELLM_API_KEY" \
  -H 'Content-Type: application/json' \
  -d '{"model":"codex","input":[{"role":"user","content":"Reply with hello."}]}'
```

These cloud requests consume OpenRouter credits or subscription allowance.
Reasoning models may need a larger output budget to return visible text.
The ChatGPT subscription backend requires Responses `input` to be a list;
the pinned connector forwards a bare string unchanged, resulting in HTTP 400.

Before considering the deployment working, also verify:

1. Repeat each request with `"stream":true` and curl `-N`; check incremental
   events and successful completion, not only the initial HTTP status.
2. Send `codex` through `/v1/chat/completions` with a `messages` array. Verify
   both streaming and non-streaming bridging with the actual intended client.
3. Run a tool-call round trip for each model: provide a simple function schema,
   receive its call, return a result with the matching call ID, and receive the
   final answer. A successful plain-text response does not establish agent compatibility.
4. Restart the deployment, wait for readiness, and repeat subscription inference.
   It should reuse the PVC credentials without a new login. Recheck after normal
   access-token expiry to establish that refresh works too; restart alone does
   not test refresh.
5. Check pod restarts, errors, and memory while streaming. Check local-only
   requests still work independently of subscription availability.

## Public exposure after internal checks

```sh
kubectl apply -f cluster/apps/litellm/exposure/certificate.yaml
kubectl -n litellm wait --for=condition=Ready certificate/litellm-tls --timeout=5m
kubectl apply -f cluster/apps/litellm/exposure/ingressroute.yaml
export LITELLM_BASE_URL=https://llm.yadunut.dev
```

Repeat auth, streaming, and inference checks against the public hostname. Verify
`/`, `/ui`, `/config`, and `/health/readiness` are not routed to LiteLLM (normally
Traefik 404). A client base URL includes `/v1`. The route currently exposes
Responses creation, not stored-response retrieval or deletion.

To withdraw public exposure, delete the LiteLLM IngressRoute. The private llama
Service remains available:

```sh
kubectl -n litellm delete ingressroute litellm
```

To stop the trial without losing login state, scale the Deployment to zero.
Avoid deleting the namespace or PVC unless discarding the OAuth state is intended.

## Flux management

The Flux Kustomization uses `./cluster/apps/litellm`, assembling internal resources
and exposure. It adopts the resources validated manually, preserving the PVCs,
database, and saved subscription login. Reconcile the root and then llama,
LiteLLM, and Hermes in dependency order.

The manual trial used temporary suspension and
`kustomize.toolkit.fluxcd.io/reconcile: disabled` annotations on llama and Hermes.
During adoption, remove those holds only after Flux has fetched the commit that
removes llama's direct public route and migrates Hermes. Resuming against the
old source revision would restore the conflicting configuration.

## Verification record — 2026-09-22

- Both 1Password Secrets synced, the PVC bound, and the TLS certificate became ready.
- Local Qwen and OpenRouter `z-ai/glm-5.3-flash` passed non-streaming chat,
  streaming with terminal completion, and a two-request function-call round trip,
  both internally and through the public HTTPS endpoint.
- Codex GPT-6 Astra passed non-streaming Responses, streamed text deltas followed
  by `response.completed`, and a function-call round trip internally and publicly.
  The upstream terminal Responses event can have an empty `output` array; clients
  must accumulate the preceding output events. Non-streaming aggregation recovers
  the output from those events.
- Codex Chat Completions bridging passed non-streaming, streaming, and a
  function-call round trip internally and publicly with the compatibility patch.
- A deployment replacement reused the saved subscription tokens and became ready
  without another device login. Explicit OAuth refresh saved renewed credentials;
  subsequent public Codex calls succeeded. The auth file mode is `0600`.
- Missing and invalid gateway keys were rejected (401 and 400 respectively).
  `/v1/models` returned local/Codex aliases and expanded OpenRouter models.
- Public `/`, `/ui`, `/config`, and `/health/readiness` returned 404.
- The final pod was ready with no restarts; observed memory was approximately
  484 MiB. The original short startup allowance caused one restart during the
  first device login; the manifest now allows 30 minutes.

These are synthetic inference checks, not an exhaustive test of every OpenRouter
model or client. Hermes was subsequently migrated to LiteLLM, as documented in
`docs/hermes.md`.

### Public hostname cutover — 2026-09-22

LiteLLM now serves `llm.yadunut.dev` with a certificate for that hostname. The
direct llama IngressRoute, Certificate, and TLS Secret were removed from the
cluster; the route/certificate manifests were removed locally. The previous
`litellm.yadunut.dev` inference route was removed; that hostname now serves the
admin UI with native Kanidm OIDC. The llama ClusterIP Service is unchanged.
The llama token succeeds against the private Service and is rejected by the
public gateway; public clients must use `LITELLM_MASTER_KEY`.

Chat and streaming were checked for all three providers through the new hostname.
Local Qwen and Codex tool round trips passed. One Codex attempt returned an
upstream server-overload error and passed on retry. An OpenRouter GLM continuation
requested another tool call despite `tool_choice: none`; the follow-up check
explicitly asks for a plain-text final result and omits tools on that final request.
The manual trial held Flux `llama` reconciliation until the manifest changes
were committed and fetched, as described in the adoption procedure above.
The initial suspension alone was undone by the parent Flux assembly, recreating
the direct llama route. After adding the resource reconciliation-disable annotation,
a forced parent reconciliation preserved suspension and the public authenticated
model listing returned HTTP 200 through LiteLLM.

### Database and admin UI rollout — 2026-09-22

- All three PostgreSQL instances became ready. Prisma migrations completed and
  the database-backed gateway rolled out successfully.
- A temporary model-scoped virtual key completed local inference, rejected Codex
  access, and was revoked. Requests using the revoked key were rejected.
- Native SSO redirects to Kanidm with the correct callback URL and S256 PKCE.
  Password login, including the master-key password, returns HTTP 403.
- The public admin UI serves over valid TLS; unauthenticated management calls
  return HTTP 401. The inference hostname still returns HTTP 404 for UI and
  management paths. Missing and invalid inference keys now both return HTTP 401.
- Local Qwen and OpenRouter passed public chat, streaming, and tool round trips
  after the rollout. Codex passed public Responses, streaming, and tool round
  trips without another device login.
- Interactive Kanidm sign-in and the resulting admin role still require browser
  verification. The single gateway process keeps pending PKCE verifiers in
  memory; restarting during sign-in requires starting that sign-in again.

## References

- https://docs.litellm.ai/docs/providers/chatgpt
- https://docs.litellm.ai/docs/providers/openai_compatible
- https://docs.litellm.ai/docs/providers/openrouter
- https://docs.litellm.ai/docs/wildcard_routing
- https://docs.litellm.ai/docs/proxy/health
- https://docs.litellm.ai/docs/proxy/admin_ui_sso
- https://docs.litellm.ai/docs/proxy/virtual_keys
- https://github.com/BerriAI/litellm/releases/tag/v1.101.0
