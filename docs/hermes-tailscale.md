# Hermes tailnet networking (merge/rollout gate)

This change is **PR-only**. It does not enroll a node, create a 1Password item,
change ACLs, install `bb`, or deploy anything. Do not merge into Flux's `main`
until the prerequisites below are complete and the operator approves rollout.

## Design

The Pod starts native restartable init sidecars in this order:

1. `tailnet-dns` (CoreDNS), gated on its HTTP startup probe.
2. `tailscale` (kernel networking), gated on its health endpoint.
3. Existing bootstrap and network-dependent computer-use-driver init containers.
4. Hermes, with `BB_SERVER_URL=https://yadunut-grep-bb.tail8dce03.ts.net`.

The sidecars remain alive with Hermes and shut down after it, in reverse order.
The reported Kubernetes v1.36.3 nodes support native sidecars. Do not convert the
resolver into an ordinary container: init downloads would wait for DNS that has
not started yet. Enrollment failure deliberately blocks Hermes startup.

Tailscale owns `tailscale0` and its routes inside the **shared Pod network
namespace**, not the host. Ordinary `bb` socket connections use those routes;
there is no SOCKS/HTTP proxy, SSH hop, exit node, accepted subnet route, advertised
subnet, forwarding sysctl or global proxy environment. `--shields-up` rejects
unsolicited tailnet ingress so the dashboard/desktop is not newly exposed to
peers. Return traffic for outbound connections is still allowed. All Hermes
tools and desktop processes share this outbound access; this is not a sandbox.

### Split DNS, not a tailnet-wide DNS replacement

The Pod uses `dnsPolicy: None` and its sole nameserver is `::1`. CoreDNS binds DNS
on IPv6 loopback only (UDP and TCP), with these non-overlapping forwarding zones:

| Query | Upstream |
| --- | --- |
| `tail8dce03.ts.net` and its descendants | Local Tailscale service resolver `fd7a:115c:a1e0::53` |
| Everything else | Existing cluster DNS service `fd00:10:97::a` |

`TS_ACCEPT_DNS=false` prevents Tailscale from taking over `/etc/resolv.conf`;
its internal resolver still answers known MagicDNS peer names. No fallback from
the tailnet zone to cluster/public DNS is configured. Unknown names or an
offline tunnel can fail; they must not bypass the split. CoreDNS never forwards
to `/etc/resolv.conf` (which would loop to itself), and never synthesizes DNS64
answers for tailnet addresses. The original cluster CoreDNS still handles
`k8s.internal` and public DNS64; Jool remains the public IPv4 egress translator.
No cluster DNS resources are changed.

Search domains are explicitly `hermes.svc.k8s.internal`, `svc.k8s.internal`,
`k8s.internal`. `ndots:1` tries dotted names, including BB and public hosts,
absolutely first; short Kubernetes service names still use the search list.
Use the full BB hostname, not `yadunut-grep-bb`. A terminal dot is useful for DNS
diagnostics, but do not change the HTTPS URL/TLS server name to a trailing-dot
variant. MagicDNS may return only a `100.64.0.0/10` A record depending on tailnet
configuration; that address uses the **kernel Tailscale route**, not DNS64.
Do not require an AAAA record or synthesize `64:ff9b::/96` for that private A.

DNS health probes test the resolver process, not upstream correctness.
Tailscale's `/healthz` tests assigned tailnet IPs, not BB ACLs, TLS, or application
authentication. No aggressive Tailscale liveness restart is tied to Internet
availability. The probe ports (18180, 18181, 19002) bind on the Pod IPv6 address
for kubelet access; they have no Service or Ingress.

### Credentials, state, and privileges

A **separate** OnePasswordItem, `hermes-tailscale`, syncs
`vaults/cluster/items/hermes-tailscale`. Only the Tailscale sidecar receives its
concealed `TS_AUTHKEY` field. `TS_KUBE_SECRET=""` explicitly disables Kubernetes
Secret state storage. Neither sidecar mounts Hermes's API token or kubeconfig;
no RBAC is added and token automount remains disabled.

Tailscale state lives on a dedicated 1 GiB replicated Longhorn RWO PVC,
`hermes-tailscale`, not Hermes's data PVC. Its root is mode 0700, new files use
umask 077, and only Tailscale mounts it. Its private socket uses a separate
sidecar-only emptyDir. Treat state/backups as node identity credentials. Keep
one replica and Recreate; never start two nodes from copies of the same state.
`TS_AUTH_ONCE=true` reuses persisted identity rather than forcing login on every
restart. Do not erase the PVC to fix a transient network failure. Restoring or
replacing state requires an operator review of the old enrollment.

The Tailscale container runs as root with **only NET_ADMIN** added after dropping
all capabilities; no privileged container, SYS_MODULE, hostNetwork or host PID
namespace is used. `/dev/net/tun` is a CharDevice hostPath mounted only there.
The node must provide the device, normally root-owned mode 0666, and the runtime's
device cgroup/LSM policy must allow opening it. This patch does not chmod the host
device or try to create it with MKNOD. CoreDNS has only NET_BIND_SERVICE and a
read-only root filesystem. HostPath and NET_ADMIN require an appropriately
scoped admission-policy exception; do not relax policy cluster-wide.

`TS_DEBUG_FIREWALL_MODE=nftables` explicitly selects the native nftables backend
with `--netfilter-mode=on`. This avoids the official image's legacy
`iptables`/`ip6tables` backend depending on NixOS legacy `ip6_tables` modules.
The host kernel must instead support nftables for **both IPv4 and IPv6**, conntrack
and TUN, inside the Pod namespace. Do not disable IPv6 or netfilter to hide an
error, grant privileged/SYS_MODULE, or change Cilium/Jool host settings.

## Before merge

- Authorize `tag:hermes` in tailnet policy (`tagOwners` with the intended admin
  owner). Grant this source tag only TCP 443 to the actual BB server's approved
  destination identity/tag or tailnet IP. The DNS suffix is not an ACL identity;
  do not add blanket access to all peers or all ports. Review existing broad
  grants because Tailscale grants are additive. Review whether a Tailscale Serve
  endpoint on the BB node has any additional policy requirements.
- Generate a tagged **non-ephemeral**, preferably single-use pre-authorized auth
  key for this node with `tag:hermes`, and store it as concealed `TS_AUTHKEY` in
  the separate 1Password Secure Note. Ensure the operator has vault access and
  the Secret will sync before rollout. Key expiry must cover first enrollment;
  an expired/consumed key cannot enroll a replacement with lost state. Review
  device approval, Tailnet Lock signing (if enabled), node expiry and key rotation.
  Do not put keys in Git, shell history, logs, PRs, or chat.
- Verify the BB device exists under the exact MagicDNS name, MagicDNS is enabled,
  its TCP 443 endpoint has a trusted certificate for the hostname, and the ACL
  lets this new tag see/reach it. Existing user-device success does not prove
  the new tagged node has equivalent rights.
- Confirm TUN availability, device permissions/cgroup access, nftables IPv4/IPv6
  support and admission exemptions on **every eligible node**. No root-owned
  state with unexpected ownership or pre-existing symlinks may be seeded into
  the dedicated PVC. Keep the existing Hermes backup/rollout gate as well.
- Check egress permits cluster DNS UDP/TCP 53, Tailscale control/DERP HTTPS over
  native IPv6 or DNS64/NAT64, and useful peer UDP paths. IPv4 literals cannot use
  NAT64; IPv4-only direct peers may need DERP relay. Do not assume direct UDP
  connectivity from this IPv6-only cluster. Kubelet must reach the probe ports.
- Have an operator smoke-test an isolated Pod with equivalent restrictions and
  disposable identity/storage before production acceptance. Offline checks below
  cannot prove node device access, enrollment, nftables, or remote `bb` access.

`TS_EXTRA_ARGS` are applied by containerboot at initial `tailscale up`, but with
`TS_AUTH_ONCE=true` its subsequent `tailscale set` only reconciles selected fields
(such as hostname and accept-DNS), not all extra arguments. Future tag,
shields-up, route or netfilter policy changes require explicit operator review
and `tailscale set` on the persisted identity, not just editing the environment.

## Verification after an explicitly approved rollout

Use operator credentials for exec; Hermes's read-only service account cannot
exec. Never print the auth key or state. In the Tailscale container, inspect
`tailscale status`, `ip addr show tailscale0`, and both `ip route show table 52`
and `ip -6 route show table 52`. Review logs for TUN permission errors, firewall
backend/IPv6 errors and enrollment failures. A relay path is acceptable.

From the **Hermes** container as its runtime user:

1. Resolve `yadunut-grep-bb.tail8dce03.ts.net` (A and AAAA separately),
   `litellm.litellm.svc.k8s.internal`, `kubernetes.default.svc.k8s.internal`,
   and a known public IPv4-only test hostname. Verify the latter gets a synthesized
   AAAA through cluster DNS64, while the BB A never becomes a NAT64 address.
2. Check HTTPS to the supplied BB hostname with normal certificate verification
   and a bounded timeout. Do not use `-k`, a hosts-file pin, IP URL, or a proxy.
3. Using the separately installed/configured `bb` CLI, run the user's already
   tested harmless read command with the supplied `BB_SERVER_URL`. CLI install,
   version selection and application credentials are **not part of this patch**.
4. Check LiteLLM, Telegram, OIDC, dashboard and computer-use-driver startup still
   work. During a planned restart confirm enrollment identity/IPs persist and
   bootstrap completes. A controlled tailnet outage must not break ordinary
   cluster/public DNS or cause private queries to go to the cluster resolver.

Do not report end-to-end success until these checks pass. Rollback removes both
sidecars, the `dnsPolicy`/`dnsConfig` override and BB environment together; leaving
`::1` without the resolver breaks all DNS. Preserve the identity PVC for recovery,
and explicitly revoke/decommission the tailnet node if retiring the integration.

## Offline evidence and reproduction

The Docker Hub registry manifest bytes were SHA-256 checked against both pins;
both indexes include linux/amd64 and linux/arm64:

- `tailscale/tailscale:v1.104.4`:
  `sha256:ed6480b33c6eb67c9cbd203ed42b9fb57e361986725b6856def71b7a3d9e276c`
- `coredns/coredns:1.15.0`:
  `sha256:0a9d8c8ddf34347eb59aad9a8784f0710de88d6d112726d11d271f9bc6daca26`

GitHub's v1.104.5 release did not have a matching Docker Hub image tag when
checked; this deliberately pins the published stable v1.104.4 container, not an
unresolvable tag. Source inspection uses that exact tag, not HEAD.

```sh
# Python environment must provide PyYAML 6.0.3; no cluster API access required.
python -m unittest discover -s tests -v
kubectl kustomize cluster/apps/hermes >/dev/null
kubectl kustomize cluster >/dev/null
git diff --check
# Optional: executable extracted from the digest-verified CoreDNS image.
COREDNS_BINARY=/path/to/coredns python -m unittest discover -s tests -v
```

Manifest tests were observed failing before adding their respective features,
then passed. The optional runtime test was run with the actual pinned CoreDNS
1.15.0 amd64 executable: real UDP/TCP split forwarding to **local fixture
upstreams**, answer preservation, suffix-boundary handling, NXDOMAIN and SERVFAIL
without fail-open all passed. It does not simulate a real tailnet or claim to
exercise Jool. The Docker daemon is unavailable here; no Tailscale kernel-mode
container was run, no device enrollment attempted, and nothing was deployed.

## Official references inspected

- Tailscale containerboot v1.104.4 settings and state/auth/health behavior:
  https://github.com/tailscale/tailscale/blob/v1.104.4/cmd/containerboot/main.go
  and https://github.com/tailscale/tailscale/blob/v1.104.4/cmd/containerboot/tailscaled.go
- IPv6 local resolver address:
  https://github.com/tailscale/tailscale/blob/v1.104.4/net/tsaddr/tsaddr.go
- MagicDNS when OS DNS acceptance is disabled:
  https://github.com/tailscale/tailscale/blob/v1.104.4/ipn/ipnlocal/node_backend.go
  and https://github.com/tailscale/tailscale/blob/v1.104.4/net/dns/manager.go
- Firewall backend selection:
  https://github.com/tailscale/tailscale/blob/v1.104.4/util/linuxfw/detector.go
- CoreDNS forwarding and listener binding:
  https://coredns.io/plugins/forward/ and https://coredns.io/plugins/bind/
- Native sidecar startup/termination ordering:
  https://kubernetes.io/docs/concepts/workloads/pods/sidecar-containers/
