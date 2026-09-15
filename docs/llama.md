# Local inference

The manifests in `cluster/apps/llama` serve Qwen3.8-27B GSQ-RCO IQ3_XXS
through llama.cpp's CUDA server. The same manifests support initial manual
validation followed by Flux adoption.

## Configuration

- Internal base URL: `http://llama.llama.svc.k8s.internal:8080/v1`
- Public base URL: `https://llm.yadunut.dev/v1`
- Model alias: `qwen3.8-27b`
- One replica on `penguin`, one inference slot, 65,536 tokens of context.
  Hermes enforces a minimum 64,000-token context at agent startup.
- Full GPU layer offload, default cache precision, flash attention and Jinja enabled.
- A 30 GiB `longhorn-local-1r` PVC caches the approximately 10.1 GB model.
  The downloader pins the upstream revision, resumes partial downloads, verifies
  SHA-256, and only then renames the file. Every startup checks the cached file.
- Direct IPv6/DNS64/NAT64 download egress, following the current Hermes setup.
  The legacy proxy referenced in AGENTS.md no longer exists.

Jellyfin shares the same 16 GiB GPU. `nvidia.com/gpu.shared: 1` is a scheduling
share, not a VRAM quota. Measure memory while transcoding before increasing
context or concurrency. System RAM limits do not limit VRAM. If necessary,
reduce context or test `--no-kv-offload`, measuring the effect on speed.
The initial deployment is text-only; no vision projector or MTP head is loaded.

## Authentication

Create a Secure Note named `llama` in the 1Password `cluster` vault. Add a
concealed field named `API_KEYS` containing two independently generated random
tokens, one per line: one for Hermes, one for personal clients. Use at least
32 random bytes per token, encoded as hex. Never commit the values.

The operator creates the `llama` Secret. Only `API_KEYS` is mounted into the
server, which refuses to start with an empty or comment-only file. Both internal
and external inference calls require `Authorization: Bearer <token>`.
These are static keys with equal access, not scoped OAuth tokens or per-user quotas.
After rotating keys in 1Password and observing both namespaces' Secret updates,
restart llama and update the affected client. The server reads keys at startup;
Hermes reads its mounted token through the provider's `key_cmd`.

Traefik terminates HTTPS and forwards only `/v1/models`, `/v1/chat/completions`,
and `/v1/completions`. The built-in UI is disabled. Health and administration
paths are not exposed by this route. The existing wildcard DNSEndpoint provides
both A and AAAA records; cert-manager issues the dedicated certificate.

## Review, then local validation

Do not apply until the user has reviewed the manifests. Render locally:

```sh
kubectl kustomize cluster >/dev/null
kubectl kustomize cluster/apps/llama >/dev/null
```

After review and 1Password provisioning, first apply only the internal resources:

```sh
kubectl apply -f cluster/apps/llama/namespace.yaml
kubectl apply -f cluster/apps/llama/onepassworditem.yaml
# Wait for the operator to create the Secret; do not print its data.
kubectl -n llama get secret llama
kubectl apply -f cluster/apps/llama/pvc.yaml
kubectl apply -f cluster/apps/llama/deployment.yaml
kubectl apply -f cluster/apps/llama/service.yaml
kubectl -n llama rollout status deployment/llama --timeout=30m
kubectl -n llama logs deployment/llama -c download-model
kubectl -n llama logs deployment/llama -c llama --tail=100
kubectl -n llama port-forward service/llama 8080:8080
```

Through the port-forward, verify missing and invalid keys return 401 on
`/v1/models` and `/v1/chat/completions`. Verify a valid token can list the alias,
complete a request, stream a response, and perform a tool call followed by a
tool-result continuation. Confirm IPv6 Service access from Hermes as well.
Check GPU memory and latency with a representative Hermes prompt and with
Jellyfin transcoding. A ready health probe does not prove inference works.

Once internal tests pass, apply the public route and certificate:

```sh
kubectl apply -f cluster/apps/llama/certificate.yaml
kubectl -n llama wait --for=condition=Ready certificate/llama-tls --timeout=5m
kubectl apply -f cluster/apps/llama/ingressroute.yaml
```

Repeat authentication and streaming checks over HTTPS; check that `/health`,
`/props`, `/slots`, and `/` are not routed to llama. Test both issued tokens.

## Hermes cutover

The Hermes manifests register `providers.llama` with `api_mode: chat_completions`,
the internal base URL, a 64K context, and a 4096-token output limit. Its
`key_cmd` reads the first line of `/llama-auth/api-keys`. A OnePasswordItem in
the Hermes namespace syncs the same item and mounts the `API_KEYS` field.
Both tokens are present in that mount; the configured provider uses only the
first. Credentials are not stored in the config file or bootstrap ConfigMap.

Hermes persists `/opt/data/config.yaml`. The init container reconciles the
named provider on startup but preserves the selected default. Fresh installations
default to llama. For the existing installation, after testing, set
`model.provider` to `custom:llama` and `model.default` to `qwen3.8-27b` through
`hermes config set`, then restart the gateway to pick up the change.
The previous default was provider `openrouter`, model `z-ai/glm-5.3-flash`;
its credentials remain available for manual rollback.

The existing Daily briefing and Weekly review jobs are explicitly pinned to
their previous OpenRouter model so changing the global default does not trigger
Hermes's cron provider/model drift guard.

## Measured validation (2026-09-15)

- IQ3_XXS loaded with a 16K context, using roughly 10.4–10.6 GiB VRAM at idle.
- Internal calls from Hermes: both valid tokens accepted, missing/invalid keys
  rejected, chat streaming and tool-call/result continuation passed.
- Public HTTPS: both valid tokens accepted, missing/invalid keys returned 401;
  UI, health, props and slots paths returned 404. IPv4 and IPv6 both reached
  the authenticated API.
- An isolated Hermes agent executed a harmless terminal command and returned
  its output in 15 seconds over two inference requests.
- While Jellyfin performed a synthetic 1080p H.264 NVENC encode, a 7,022-token
  prompt processed at 349.5 tokens/sec; generation ran at 9.75 tokens/sec for
  256 output tokens. Total request time was 46.5 seconds. GPU memory use during
  the overlap was 11,088 MiB. This tests synthetic encoding, not a full media
  playback/transcode pipeline. Benchmark requests disabled thinking.
- The same uncached request with the GPU otherwise idle processed at 359.2
  prompt tokens/sec and generated at 10.40 tokens/sec (44.2 seconds total).
- The final server context is 64K because Hermes rejects a declared context
  below 64,000 tokens. At 64K, startup VRAM use was 13,802 MiB and about
  14,000 MiB during the agent test; free memory was roughly 1.9 GiB.
  The earlier 16K benchmark figures above are retained for comparison.
- At the final 64K setting, the same 7,022-token uncached benchmark processed
  at 341.2 prompt tokens/sec and generated 256 tokens at 8.89 tokens/sec,
  taking 49.6 seconds total. A default reasoning-enabled Hermes terminal-tool
  round trip completed successfully in 63.9 seconds over two requests.

## Flux handover

Once local validation and Hermes integration work, commit the finalized manifests
and documentation, push `main`, and reconcile Flux. `cluster/apps/llama.yaml`
depends on infrastructure and points at the same resources applied manually.
Do not apply the root assembly or create the Flux Kustomization during the initial
local test: its source still points at the previously committed repository.
After pushing, verify Flux adopts the resources and the workload remains healthy.
Do not delete the namespace or PVC during handover.

## References

- https://huggingface.co/ISTA-DASLab/Qwen3.8-27B-GSQ-RCO-GGUF
- https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md
- https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md
- https://hermes-agent.nousresearch.com/docs/integrations/providers/
