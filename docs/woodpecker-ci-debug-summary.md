# Woodpecker CI Debug Summary (2026-02-08)

## Scope
Investigate why Woodpecker image build pipelines fail in `git.yadunut.dev/yadunut/yadunut.dev`, especially in `woodpeckerci/plugin-docker-buildx` steps.

## What Was Changed
All changes were made in:
- `cluster/apps/woodpecker/helmrelease.yaml`

Applied updates included:
- Enabled privileged plugin use for buildx:
  - `WOODPECKER_PLUGINS_PRIVILEGED=woodpeckerci/plugin-docker-buildx:latest`
- Added proxy env for server/agent:
  - `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY`
- Added buildx plugin networking/proxy env:
  - `PLUGIN_IPV6`
  - `PLUGIN_CUSTOM_DNS=fd00:10:97::a`
  - `PLUGIN_HTTP_PROXY`, `PLUGIN_HTTPS_PROXY`, `PLUGIN_NO_PROXY`
- Added global environment forwarding + build args:
  - `WOODPECKER_ENVIRONMENT=PLUGIN_IPV6,PLUGIN_CUSTOM_DNS,PLUGIN_HTTP_PROXY,PLUGIN_HTTPS_PROXY,PLUGIN_NO_PROXY,PLUGIN_BUILD_ARGS_FROM_ENV,HTTP_PROXY,HTTPS_PROXY,NO_PROXY`
  - `PLUGIN_BUILD_ARGS_FROM_ENV=HTTP_PROXY,HTTPS_PROXY,NO_PROXY`

Applied to cluster with:
- `kubectl apply -f cluster/apps/woodpecker/helmrelease.yaml`
- HelmRelease reconciled successfully (later revisions reached `woodpecker.v12`).

## What Has Worked
1. Previous failure mode improved:
   - Old error: buildx could not resolve/connect to proxy host:
     - `lookup http-proxy.kube-system.svc.k8s.internal: i/o timeout`
2. Buildx pod runtime now shows plugin env injection for DNS/proxy.
3. Server pod now has expected proxy + plugin-related env vars at runtime.
4. Pipeline reaches build stage and runs Docker build, so earlier startup/connectivity blockers were reduced.

## What Is Still Failing
Latest observed failure (pipeline 14, workflow UUID `01KGYZZ34FB297FG0BV78FP1Y9`) is during Dockerfile `RUN apk add`:

- `WARNING: fetching https://dl-cdn.alpinelinux.org/alpine/v3.22/main: IO ERROR`
- `WARNING: fetching https://dl-cdn.alpinelinux.org/alpine/v3.22/community: IO ERROR`
- Then package resolution fails:
  - `curl (no such package)`
  - `tar (no such package)`
  - `xz (no such package)`

This indicates Alpine index fetch failure inside the image build step (not the earlier proxy DNS lookup error).

## Notes From Logs
- Agent logs confirm latest workflow failed with exit code 1:
  - `workflow finished with error uuid=01KGYZZ34FB297FG0BV78FP1Y9: exit code 1`
- Build step pods are ephemeral and often gone before direct log retrieval.
- Server logs after restart showed warnings like:
  - `key 'PLUGIN_IPV6' has no value, will be ignored`
  - even though env vars are visible on the running pod spec.
  - This suggests potential nuance in how `WOODPECKER_ENVIRONMENT` is interpreted by server runtime.

## Additional Findings (2026-02-09)
1. Clone path issue was fixed by removing `git.yadunut.dev` from `NO_PROXY`:
   - direct path was hanging in clone pod for this environment
   - proxied path worked
2. Alpine CDN behavior was reproduced with controlled pod tests:
   - direct `dl-cdn.alpinelinux.org` from pod was stable
   - proxied `dl-cdn.alpinelinux.org` via tinyproxy was flaky/slow
3. Measured results:
   - direct `curl` to Alpine index URL: `4/4` success
   - proxied `curl` to same URL: `0/4` success (timeouts)
   - direct `apk update`: `3/3` success
   - proxied `apk update` repeat test: `1/8` success, `7/8` `IO ERROR`
4. tinyproxy logs showed delayed upstream establishment for Alpine CDN:
   - `CONNECT dl-cdn.alpinelinux.org:443` then long gap before `Established connection`
   - delay duration aligns with CI step timeout/failure windows
5. Host-network test on node `penguin` showed direct Alpine CDN access is fast (sub-second), indicating node egress is generally fine.

## Root Cause (Current Best Explanation)
1. Proxy in cluster is tinyproxy `1.11.0` (`vimagick/tinyproxy`, unpinned tag).
2. tinyproxy `opensock` resolves all destination addresses, then attempts `connect()` sequentially (one address at a time).
3. tinyproxy applies socket send/recv timeouts from config `Timeout`; current config is `Timeout 600`.
4. For `dl-cdn.alpinelinux.org` (Fastly dual-stack), some attempts through proxy spend a long time before connection is established or fail within client timeout windows.
5. This explains observed behavior:
   - direct pod path to Alpine CDN: consistently fast
   - proxied path: intermittent long stalls/timeouts
   - tinyproxy logs show `getaddrinfo returned` immediately, but `Established connection` can be delayed by tens of seconds to minutes.

## Current State
- Woodpecker server and agents are running.
- HelmRelease changes are applied (`v12` observed).
- Mitigation in place:
  - keep `git.yadunut.dev` out of `NO_PROXY` (proxy it)
  - keep `dl-cdn.alpinelinux.org` in `NO_PROXY` (bypass proxy)
- Latest pipeline observed in DB at the time of validation (`#17`) completed successfully.

## Next Checks (when a new job is running)
1. Immediately capture buildx pod logs before GC:
   - `kubectl logs -n woodpecker <wp-buildx-pod> --tail=300`
2. Confirm buildx pod env:
   - `kubectl get pod -n woodpecker <wp-buildx-pod> -o jsonpath='{range .spec.containers[0].env[*]}{.name}={.value}{"\n"}{end}'`
3. Verify whether build args are actually passed into buildkit invocation in logs.
4. If Alpine fetch still fails, test one of:
   - add Alpine CDN host handling strategy (mirror change or explicit proxy/no_proxy behavior during build),
   - pass explicit build args in pipeline step as a control comparison.
