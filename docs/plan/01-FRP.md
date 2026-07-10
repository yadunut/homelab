# FRP demo tunnels

Status: proposed

## Decisions

- A brief, complete Traefik outage while adding or removing the static
  `frp-ssh` entrypoint is accepted. Zero-downtime Traefik rollout changes are
  outside this work.
- The initial deployment keeps `proxy.yadunut.dev`. Because demo content is
  untrusted and shares the `yadunut.dev` site boundary with homelab apps, the
  implementation must first audit parent-domain cookies, CORS, and CSRF
  assumptions. A separate registrable domain is preferred if that audit cannot
  establish an acceptable boundary.
- SSH-authorized users are trusted FRP users. The externally reachable design
  exposes only HTTP virtual hosts and the SSH gateway; a NetworkPolicy and an
  FRP control token provide defense in depth against other proxy types and the
  normal FRP control listener.
- The persistent SSH host key and the FRP control token are stored in
  1Password and projected through the 1Password operator. No PVC is required.

## Goal

Provide a fast, ephemeral way to expose an HTTP server running on the Mac at a
configurable HTTPS hostname such as `demo.proxy.yadunut.dev`.

The intended workflow is:

1. Start a web server on the Mac, for example on `127.0.0.1:3000`.
2. Start one SSH reverse-tunnel command and select the first DNS label.
3. Wait for FRP's proxy-created success banner.
4. Share `https://<name>.proxy.yadunut.dev`.
5. Stop the SSH process to remove the tunnel without a GitOps change.

Demo tunnels do not survive client disconnects or FRP restarts. A graceful
Ctrl-C should remove a tunnel promptly. An ungraceful network partition has no
proven application-level cleanup bound: the client keepalives terminate the
local SSH process but do not guarantee when FRPS detects the dead TCP session.
Measure and document the observed behavior without promising an SLA. The
persistent host key comes from 1Password so clients retain the same SSH server
identity across pod, node, and rollout replacement.

## Non-goals

- Hosting production or persistent applications from the Mac.
- Providing a zero-downtime Traefik rollout.
- Exposing arbitrary TCP or UDP ports publicly.
- Supporting nested names below `*.proxy.yadunut.dev`.
- Adding oauth2-proxy in front of every demo.
- Replacing Traefik's existing ingress responsibilities.
- Requiring `frpc` for the normal demo workflow.
- Enforcing per-key proxy quotas inside FRP.

## Proposed architecture

```text
Browser
  |
  | HTTPS: demo.proxy.yadunut.dev
  v
Cloudflare DNS (*.proxy.yadunut.dev, DNS-only)
  |
  v
Traefik websecure :443
  |  terminates wildcard TLS
  |  preserves the Host header
  |  applies request-rate and in-flight limits
  v
frps HTTP virtual-host listener :8080
  |
  | active SSH reverse tunnel
  v
127.0.0.1:3000 on the Mac

Mac ssh client
  |
  | SSH: tunnel.proxy.yadunut.dev:2200
  v
Traefik frp-ssh entrypoint :2200
  |
  v
frps SSH tunnel gateway :2200
```

FRP's HTTP proxy mode selects a tunnel from the incoming `Host` header. Traefik
therefore needs only one wildcard HTTPS route and one backend HTTP service,
regardless of how many demo names are used.

The FRP pod also listens on its mandatory normal control port `7000`. That port
is not present in the Service, is blocked by NetworkPolicy, and requires a
random 1Password-backed token. It is not part of the user workflow.

## User interface

The underlying command should be equivalent to:

```sh
ssh -T \
  -o ExitOnForwardFailure=yes \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=3 \
  -o IdentitiesOnly=yes \
  -i ~/.ssh/<selected-key> \
  -p 2200 \
  -R :80:127.0.0.1:3000 \
  v0@tunnel.proxy.yadunut.dev \
  http \
  --proxy_name demo \
  --sd demo
```

`subDomainHost = "proxy.yadunut.dev"` on the server combines with `--sd demo`
to register `demo.proxy.yadunut.dev`. Do not use
`--custom_domain demo.proxy.yadunut.dev` with that server setting: FRP rejects
a custom domain that belongs to its configured subdomain host.

The selected label must be a valid lowercase DNS hostname label: 1-63 letters,
digits, or hyphens; it must begin and end with a letter or digit. `tunnel` is
reserved for the SSH gateway and must not be used as a demo label. The published
documentation should replace `<selected-key>` with the chosen key path or
provide an equivalent SSH host configuration.

The `:80` portion is part of FRP's SSH gateway protocol; public browser traffic
still enters through Traefik on HTTPS port 443. `ExitOnForwardFailure` confirms
the SSH forwarding request, but the user should not share the URL until FRP
prints its success banner because later FRP registration errors may not be
reported as an SSH forwarding failure.

On first use, the client must verify the SSH host-key fingerprint published by
the deployment documentation before accepting it. Subsequent rollouts must
present the same fingerprint.

## Cluster resources

Create `cluster/infrastructure/frp/` containing:

- `namespace.yaml`: dedicated `frp` namespace.
- `configmap.yaml`: `frps.toml` and the allowed SSH public keys.
- `onepassworditem.yaml`: projects the FRP control token and persistent SSH host
  private key into a Kubernetes Secret.
- `deployment.yaml`: one `frps` replica using the official, version-pinned FRP
  image.
- `service.yaml`: IPv6 single-stack ClusterIP ports for HTTP and SSH only.
- `networkpolicy.yaml`: allows ingress to the FRP pod only on TCP ports `8080`
  and `2200`; port `7000` and dynamically bound proxy ports remain blocked.
- `certificate.yaml`: wildcard certificate for `*.proxy.yadunut.dev`.
- `dnsendpoint.yaml`: explicit DNS-only A and AAAA records for
  `tunnel.proxy.yadunut.dev` and `*.proxy.yadunut.dev`.
- `middlewares.yaml`: Traefik request-rate and in-flight request limits for
  public demo traffic.
- `ingressroute.yaml`: single-label wildcard HTTPS route to the FRP HTTP
  listener, excluding the reserved `tunnel` label.
- `ingressroutetcp.yaml`: TCP route from the dedicated Traefik entrypoint to the
  FRP SSH gateway.
- `kustomization.yaml`: component assembly.

Add `frp` to `cluster/infrastructure/kustomization.yaml` after Traefik for
readability. Resource-list position is not a Flux readiness dependency; the
rollout sequence must wait for the Traefik HelmRelease and FRP Deployment
explicitly.

### Secrets and SSH host identity

Create or select a 1Password item containing:

- A random, high-entropy FRP control token.
- A persistent SSH host private key generated specifically for this service.

The `OnePasswordItem` should create one Secret mounted read-only at a stable
path such as `/run/secrets/frp/`. Configure:

```toml
auth.method = "token"
auth.additionalScopes = ["HeartBeats", "NewWorkConns"]
auth.tokenSource.type = "file"
auth.tokenSource.file.path = "/run/secrets/frp/auth-token"
sshTunnelGateway.privateKeyFile = "/run/secrets/frp/ssh-host-key"
```

The Secret volume must be readable by the fixed non-root UID/GID without making
the files writable. Record the public fingerprint of the SSH host key in the
operational documentation. Do not commit the private key, control token, Secret
data, or a rendered Secret manifest.

The token protects the mandatory normal FRP control listener. In the pinned FRP
version, an SSH gateway session that passes `authorized_keys` authentication
must be verified to use FRP's internal authenticated path without requiring the
token in the SSH command.

### FRP server configuration

The minimal `frps.toml` should:

- Set `bindAddr = "::"` for the cluster's IPv6-only networking.
- Set the mandatory normal control listener explicitly to `bindPort = 7000`.
- Listen for HTTP virtual hosts on port `8080`.
- Set `subDomainHost = "proxy.yadunut.dev"`; clients select exactly one label
  with `--sd <name>`.
- Enable the SSH tunnel gateway on port `2200`.
- Read `authorized_keys` from the ConfigMap.
- Read the SSH host private key and FRP auth token from the projected Secret.
- Log to stdout at `info` level.
- Set `detailedErrorsToClient = false`.
- Leave the dashboard, web server, Prometheus endpoint, KCP, and QUIC disabled.

Do not configure `maxPortsPerClient` as an HTTP tunnel quota. It counts bound
TCP/UDP ports, not HTTP virtual-host proxies, and each SSH process is a separate
virtual client.

Do not expose port `7000`, the dashboard, or arbitrary FRP remote ports through
a Service or Traefik. The NetworkPolicy permits pod ingress only to `8080` and
`2200`. Authorized SSH key holders can request other FRP proxy types, but those
listeners are not publicly or cluster-reachably exposed by this design. If
authorized users can no longer be fully trusted, add a `NewProxy` authorization
plugin that permits only HTTP proxies before adding their keys.

### FRP image and Deployment

This plan has been checked against FRP `v0.70.0`. Use the official
`ghcr.io/fatedier/frps:v0.70.0` image and pin its multi-architecture manifest
digest in the Deployment; do not use `latest`. If implementation deliberately
upgrades FRP, repeat the configuration, SSH command, and image-security tests
against the replacement version before changing the pin.

Run the container with:

- `runAsNonRoot: true`, `runAsUser: 65532`, and `runAsGroup: 65532`.
- Pod-level `fsGroup: 65532` and `fsGroupChangePolicy: OnRootMismatch` for the
  read-only Secret projection.
- `readOnlyRootFilesystem: true`.
- All Linux capabilities dropped.
- `allowPrivilegeEscalation: false`.
- `seccompProfile.type: RuntimeDefault`.
- `automountServiceAccountToken: false`.
- Initial resource requests of `25m` CPU and `32Mi` memory.
- Initial resource limits of `500m` CPU and `256Mi` memory.
- Named container ports `http-vhost` (`8080`) and `ssh-gateway` (`2200`).
- A `Recreate` Deployment strategy because FRPS is an in-memory singleton and
  all active demos intentionally end on rollout.

Use concrete probes:

```yaml
startupProbe:
  tcpSocket:
    port: ssh-gateway
  periodSeconds: 2
  timeoutSeconds: 1
  failureThreshold: 30
readinessProbe:
  tcpSocket:
    port: http-vhost
  periodSeconds: 5
  timeoutSeconds: 1
  failureThreshold: 3
livenessProbe:
  tcpSocket:
    port: ssh-gateway
  periodSeconds: 10
  timeoutSeconds: 1
  failureThreshold: 3
```

The pre-deployment container test must prove that the chosen numeric UID/GID,
read-only root filesystem, ConfigMap, and Secret mounts work with the exact
pinned image.

### Traefik

Add a new Traefik TCP entrypoint named `frp-ssh` on host port `2200`. This is
separate from the existing Forgejo SSH entrypoint on `2222`, since ordinary SSH
cannot be routed by hostname or TLS SNI.

Create:

- An `IngressRouteTCP` using ``HostSNI(`*`)`` on `frp-ssh`, forwarding to the
  FRP Service's SSH port.
- An `IngressRoute` on `websecure` matching one valid DNS label beneath
  `proxy.yadunut.dev`, explicitly excluding `tunnel.proxy.yadunut.dev` and all
  nested names.
- TLS termination on the HTTP route using the wildcard certificate.
- A `RateLimit` middleware with an initial average of 20 requests per second,
  burst 40, and period 1 second.
- An `InFlightReq` middleware with an initial limit of 100 requests.

Traefik must preserve the original `Host` header because FRP uses it to select
the correct tunnel. The middleware values are operational guardrails, not a
security boundary, and may be tuned after observing real demos.

The current Traefik Deployment has three host-network replicas and uses
`Recreate`. Adding or removing a static entrypoint changes its pod template, so
all Traefik pods stop before their replacements start. A brief outage of all
HTTP, HTTPS, Forgejo SSH, and FRP SSH ingress during rollout and rollback is
expected and accepted. Record pre-change endpoint checks and verify them again
immediately after the rollout; changing Traefik's rollout strategy is not part
of this work.

### NixOS ingress-node firewall

Update the sibling system configuration repository at `../nix` so the new
Traefik host port is allowed by the NixOS firewall.

Add port `2200` to `networking.firewall.allowedTCPPorts` in the
`flake.modules.nixos.kubernetes-common` configuration in:

```text
../nix/modules/kubernetes/00-kubernetes.nix
```

All three current Kubernetes machines are ingress nodes and import
`kubernetes-common`, so all three require this opening. The existing host-level
rules for HTTP/HTTPS and Forgejo SSH port `2222` remain unchanged. If a future
Kubernetes machine is not an ingress node, move ingress-only ports into a
dedicated NixOS module instead of inheriting them through `kubernetes-common`.

Deploy the NixOS firewall change to all Kubernetes nodes before enabling the
new Traefik entrypoint. No reboot should be required or performed as part of
this work.

### DNS

Cloudflare's existing `*.yadunut.dev` wildcard is multi-level and currently
resolves `demo.proxy.yadunut.dev` and `tunnel.proxy.yadunut.dev` when no closer
record takes precedence. Dedicated records are therefore not required merely
to make those names resolve.

Create explicit DNS-only A and AAAA records for
`tunnel.proxy.yadunut.dev` and `*.proxy.yadunut.dev` using the same ingress
targets and 300-second TTL convention as the existing root wildcard. These
records provide component ownership, stable closest-encloser behavior, and an
independently managed target set. DNS-only mode is required because Cloudflare's
HTTP proxy does not carry the raw SSH service on port `2200`.

Deleting the dedicated records during rollback does not guarantee NXDOMAIN;
the parent `*.yadunut.dev` wildcard can resume answering. Rollback success is
defined by removal of the Traefik routes/listener and FRP workload, not by DNS
resolution failure.

### TLS

Issue a cert-manager DNS-01 certificate for:

```text
*.proxy.yadunut.dev
```

The existing `*.yadunut.dev` certificate does not cover a two-label name such
as `demo.proxy.yadunut.dev`, so the dedicated certificate is required even
though parent wildcard DNS already resolves the name.

Traefik terminates public TLS. The local Mac service remains plain HTTP, the
Traefik-to-FRP hop stays inside the cluster, and the FRP-to-Mac hop is carried
inside SSH.

## Authentication, exposure, and key lifecycle

Tunnel creation through the supported public workflow requires SSH public-key
authentication. Commit only public keys in the `authorized_keys` ConfigMap;
never commit a private key or FRP auth token.

The initial authorized key must be explicitly selected during implementation.
Every key line must have a stable, unique, lowercase comment because FRP uses
the authorized-key comment as its client identity. Additional users can be
added by appending reviewed public keys.

FRP reloads `authorized_keys` for new SSH authentications, subject to normal
ConfigMap projection delay. Removing a key blocks new sessions but does not
terminate a tunnel that is already authenticated. Emergency revocation is:

1. Remove the key from Git and reconcile the ConfigMap.
2. Confirm a new handshake with the key is rejected.
3. Restart the FRP Deployment to terminate all existing sessions.
4. Confirm every demo tunnel is gone.

The all-tunnel outage caused by emergency revocation is accepted.

The file-backed control token is read when FRPS starts. Rotate it by updating
the 1Password item, waiting for the projected Secret to update, and restarting
the FRP Deployment. That restart ends every active demo, which is accepted.

Rotate the SSH host key only for compromise or deliberate service re-identity.
Publish the replacement fingerprint through the cluster administration path
before restarting FRPS, then require clients to verify it before removing the
old `known_hosts` entry. Never tell clients to bypass host-key checking.

Demo pages are public to anyone who knows or discovers the URL. Rate limits do
not provide confidentiality or authorization. Documentation must warn users not
to expose sensitive local applications, credentials, privileged development
tools, or data that should not be public. FRP's per-proxy HTTP basic
authentication can be added later, but oauth2-proxy is outside the initial scope
because demos may need to be shared with people without homelab OIDC access.

Because demo pages are same-site with other `*.yadunut.dev` applications, audit
all homelab applications before rollout for cookies scoped to `.yadunut.dev`,
overly broad CORS, and CSRF defenses that depend only on SameSite cookies. If
the audit finds an unsafe dependency that cannot be fixed, use a separate
registrable domain for demos before deployment.

## Implementation sequence

1. Confirm port `2200` is unused on every ingress node and permitted by every
   upstream network firewall.
2. Audit the `yadunut.dev` same-site boundary. Resolve any parent-domain cookie,
   CORS, or CSRF issue, or select a separate registrable demo domain and update
   this plan before continuing.
3. Select the initial SSH client public key. Create the dedicated SSH host key
   and FRP control token in 1Password, and record the host-key fingerprint.
4. Select and pin the FRP image tag and multi-architecture manifest digest.
5. Build the proposed `frps.toml` and run the exact image, security context,
   mounts, probes, authorized and unauthorized SSH commands locally with
   Apple's `container` command.
6. In `../nix/modules/kubernetes/00-kubernetes.nix`, allow TCP port `2200` in
   the `kubernetes-common` firewall configuration.
7. In `../nix`, run `jj status` and `jj diff`, validate the flake and every
   Kubernetes machine configuration, commit, advance the bookmark consumed by
   that repo's deployment workflow, explicitly push that bookmark to its
   deployment remote, confirm the remote bookmark moved, and deploy the change
   to all Kubernetes nodes with Clan.
8. Confirm the node firewall change is active before editing Traefik.
9. Add the FRP namespace, ConfigMap, OnePasswordItem, Deployment, Service,
   NetworkPolicy, certificate, DNS endpoint, middlewares, and HTTP/TCP routes.
10. Add the `frp-ssh` Traefik entrypoint and add the FRP component to the
    infrastructure kustomization.
11. Render the full cluster manifests, render the exact Traefik chart, and run
    the static and server-side validation below.
12. Record pre-rollout checks for representative HTTP/HTTPS endpoints and
    Forgejo SSH on port `2222`.
13. In this repo, run `jj status` and `jj diff`, commit with a short imperative
    message, run `jj tug` to advance `main` to the new commit, then run
    `jj git push --remote origin --bookmark main`. Confirm `main@origin` points
    to the new commit; Flux consumes that GitHub branch. The push authorizes the
    deployment, so Flux may begin reconciling before the next command.
14. Run `flux reconcile kustomization infrastructure --with-source` and expect
    the accepted complete Traefik outage while its pods are recreated.
15. Wait for the Certificate, FRP Deployment, and Traefik HelmRelease to become
    Ready. Confirm the NetworkPolicy is present and the DNS records have
    propagated, then verify the pre-rollout endpoints have recovered.
16. Run the cluster and end-to-end validation, including two simultaneous demo
    tunnels and every published A/AAAA target.

## Validation

### Static and local validation

- Run `frps verify` against the planned `frps.toml` using the exact pinned image
  through Apple's `container` command.
- Start that image locally with the planned non-root UID/GID, read-only root
  filesystem, ConfigMap content, Secret files, and probes. Run the exact
  documented `--sd demo` SSH command and require FRP's success banner.
- Confirm an unauthorized SSH key is rejected locally and that the configured
  FRP control token does not appear in the SSH command.
- Restart the local container with the same host key and confirm its fingerprint
  is unchanged.
- Render the exact Traefik chart version resolved by the HelmRelease with the
  proposed values using `helm template`; verify the `frp-ssh` entrypoint,
  host-network port, and existing `2222` entrypoint in the rendered Deployment.
- Run `kubectl kustomize cluster` from `nix develop`.
- Run
  `nix develop -c flux diff kustomization infrastructure --path ./cluster/infrastructure`.
  Exit status `1` means expected differences; a status greater than `1` is a
  validation failure.
- Confirm rendered manifests contain no plaintext secret, control token, SSH
  private key, or rendered Kubernetes Secret data.
- Confirm no generated `cluster/flux-system/gotk-*` files changed.
- Confirm the FRP Service is IPv6 single-stack and exposes only `8080` and
  `2200`.
- Confirm the NetworkPolicy permits only FRP pod ingress on `8080` and `2200`.
- Confirm the HTTP route matches one valid label, excludes `tunnel`, and does
  not match nested names.
- Confirm the exact A and AAAA targets match the intended ingress addresses and
  are DNS-only.
- In `../nix`, validate the flake and evaluate or build every Kubernetes machine
  configuration with the new common firewall rule.

### Cluster validation

- Confirm the FRP startup, readiness, and liveness probes pass.
- Confirm the FRP pod retains the same SSH host-key fingerprint across a pod
  restart and scheduling onto another node.
- Confirm the projected 1Password Secret is present but never print its values.
- Confirm one Traefik pod is Running and Ready on every current ingress node
  after the accepted `Recreate` rollout.
- Confirm Traefik listens on port `2200` on every ingress node and continues to
  listen on Forgejo SSH port `2222`.
- Enumerate every published A and AAAA target. Force an HTTPS request with
  `curl --resolve` and perform an SSH handshake against each address rather than
  relying on resolver selection.
- Confirm `tunnel.proxy.yadunut.dev` and a demo hostname resolve over A and
  AAAA, use the intended TTL, and are DNS-only.
- Confirm the wildcard certificate is Ready and served for a valid demo
  hostname.
- Confirm an unauthorized SSH key cannot create a tunnel.
- From a disposable in-cluster test pod, confirm FRP port `7000`, the dashboard,
  and an arbitrary dynamically requested proxy port are blocked while `8080`
  and `2200` remain reachable through their intended paths.
- Confirm `https://tunnel.proxy.yadunut.dev` and a nested name such as
  `foo.demo.proxy.yadunut.dev` do not reach an FRP demo.
- Confirm the RateLimit and InFlightReq middlewares are attached and enforce
  their configured bounds without breaking WebSocket upgrades.
- Repeat the representative HTTP/HTTPS and Forgejo SSH checks recorded before
  rollout.

### End-to-end validation

1. Start two disposable local HTTP servers with distinct response markers on
   Mac ports `3000` and `3001`.
2. Start an SSH tunnel named `demo-a` to port `3000` using `--sd demo-a` and
   require the FRP success banner.
3. While `demo-a` remains connected, start `demo-b` to port `3001` using
   `--sd demo-b`.
4. Fetch both HTTPS hostnames over every published IPv4 and IPv6 target and
   confirm each reaches only its own marker.
5. Confirm original Host handling, forwarded headers, WebSocket upgrades, query
   strings, request bodies, and non-root paths reach the correct local server.
6. Stop only `demo-a`. Within five seconds, confirm its public hostname no
   longer reaches marker A while `demo-b` continues to work.
7. Stop `demo-b` and confirm it no longer reaches marker B.
8. Repeat one tunnel with an ungraceful client termination, measure when FRPS
   removes it, and record the result. Do not treat client keepalive settings as
   a guaranteed server-side cleanup bound.
9. Attempt invalid, nested, and reserved labels and confirm none becomes a
   public demo route.

## Acceptance criteria

- A local HTTP server becomes available at
  `https://<name>.proxy.yadunut.dev` with one SSH command using `--sd <name>`.
- The client verifies the documented SSH host-key fingerprint, and that
  fingerprint survives pod and node replacement.
- The public endpoint has a trusted certificate issued through cert-manager.
- Starting a tunnel through the supported workflow requires an authorized SSH
  key; the mandatory normal FRP control port is token-protected and blocked by
  NetworkPolicy.
- Stopping the SSH process removes the demo without a Flux or Kubernetes
  change, and graceful cleanup completes within five seconds.
- Two differently named tunnels coexist; stopping one does not affect the
  other.
- Every published A and AAAA target serves HTTPS and accepts the SSH gateway
  connection on port `2200`.
- Only one valid, non-reserved label is publicly routed. Nested names and
  `tunnel.proxy.yadunut.dev` do not reach demo content over HTTPS.
- The dashboard, port `7000`, and arbitrary FRP proxy ports are not reachable
  from another pod or the public network.
- Public request-rate and in-flight limits are active.
- Representative Traefik HTTP/HTTPS and Forgejo SSH routes work after rollout.
  A transient complete Traefik outage during rollout and rollback is accepted.
- The same-site cookie/CORS/CSRF audit is complete with no unresolved blocker.
- No plaintext secret, control token, or private key is committed.
- The image is pinned by version and multi-architecture digest.
- `kubectl kustomize cluster`, the Traefik Helm render, the Nix validations, and
  the Flux diff complete without validation errors.
- The homelab change is present on remote `main` before Flux reconciliation.

## Rollback

1. Stop active demo SSH processes where practical; the FRP/Traefik rollout will
   terminate any remaining sessions.
2. In one homelab change, remove the FRP component reference and directory and
   remove the `frp-ssh` entrypoint from the Traefik HelmRelease.
3. Render the cluster, render the Traefik chart, and run the Flux diff.
4. Review with `jj status` and `jj diff`, commit, run `jj tug`, push explicitly
   with `jj git push --remote origin --bookmark main`, and confirm the rollback
   is present at `main@origin`.
5. Reconcile infrastructure with source. Expect the accepted complete Traefik
   outage while its pods are recreated.
6. Verify Traefik HTTP/HTTPS and Forgejo SSH recover, port `2200` is no longer
   listening on any ingress node, and all FRP namespace resources, routes,
   middlewares, NetworkPolicy, Certificate, and projected Kubernetes Secret are
   pruned.
7. Wait for ExternalDNS and cert-manager cleanup. Do not require DNS failure:
   the parent `*.yadunut.dev` wildcard may resume answering demo names.
8. In `../nix`, remove port `2200` from `kubernetes-common`, validate all
   machines, review and commit with `jj`, advance and explicitly push the
   consumed bookmark, and deploy the firewall rollback with Clan only after the
   listener is gone.
9. Confirm port `2200` is closed at every published ingress address and repeat
   the representative HTTP/HTTPS and Forgejo SSH checks.
10. Retain the 1Password item by default so a future reinstall presents the
    same SSH host identity. Delete or rotate it only as an explicit permanent
    decommissioning decision.
