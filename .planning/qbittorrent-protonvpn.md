# qBittorrent Proton VPN Rollout Plan

## Goal

Route only the `jellyfin/qbittorrent` Pod's torrent traffic through Proton VPN, while preserving the existing cluster networking:

- Cilium remains the Kubernetes datapath.
- Existing host WireGuard interfaces remain untouched.
- Node routing tables and host firewall rules are not modified by the VPN client.
- The qBittorrent WebUI remains reachable through Traefik and oauth2-proxy.

## Current State

- qBittorrent is a hand-written Deployment at `cluster/apps/jellyfin/qbittorrent-deployment.yaml`.
- It is pinned to `penguin`.
- It currently exposes torrent TCP/UDP through `hostPort: 6881`.
- Its WebUI is exposed only through the `qbittorrent` ClusterIP Service on port `8080`.
- Cilium is IPv6-only for pods:
  - `ipv4.enabled=false`
  - `ipv6.enabled=true`
  - native routing
  - BGP enabled
  - kube-proxy replacement enabled
- The qBittorrent Pod has no real IPv4 route today. It only has loopback IPv4 and Cilium-provided IPv6.
- The nodes already have host-level WireGuard interfaces for cluster and user networking.
- `/dev/net/tun` exists on `penguin`.

## Design

Run Gluetun as a sidecar in the same qBittorrent Pod.

Kubernetes containers in one Pod share the same network namespace. That lets Gluetun create `tun0`, install its kill-switch rules, and route qBittorrent's traffic without touching the node network namespace.

Target shape:

```text
qbittorrent Pod network namespace
  eth0: Cilium IPv6 Pod interface
  tun0: Gluetun Proton VPN interface

  gluetun sidecar:
    - owns VPN connection
    - owns kill-switch firewall inside the Pod namespace
    - obtains Proton NAT-PMP forwarded port
    - updates qBittorrent listen port over localhost

  qbittorrent container:
    - keeps WebUI on port 8080
    - binds torrent traffic to tun0
    - stops using hostPort
```

## Critical Constraint

The generated Proton WireGuard config includes both an IPv4 endpoint and a commented IPv6 endpoint. This cluster does not provide IPv4 routing to Pods, so the qBittorrent VPN path must use Proton's IPv6 endpoint.

Current tested endpoint:

```text
[2a02:6ea0:d101:6221::10]:51820
```

Therefore, do not modify the live qBittorrent Deployment until a canary proves Gluetun can establish the Proton tunnel from this IPv6-only Pod network.

If the canary cannot dial Proton:

1. Prefer selecting a Proton endpoint that is reachable from the Pod network.
2. Ensure the Proton underlay endpoint leaves through the wired `enp4s0` interface, which is already in Cilium's masquerade device list.
3. If that is not possible, add a narrowly scoped hostNetwork UDP relay for the single Proton WireGuard endpoint.
4. Do not run Gluetun with `hostNetwork: true`.
5. Do not install Proton WireGuard on the node.
6. Do not enable cluster-wide IPv4 just for this workload.

## Phase 1 Finding: Proton Underlay Egress

The canary initially created `tun0` but did not complete a WireGuard handshake. `wg show` inside the Pod network namespace showed transmitted bytes and `0 B received`.

Tcpdump on `penguin` showed Proton UDP packets leaving `wlp7s0` with the Pod ULA source address:

```text
fd00:10:96:2::2a8d > 2a02:6ea0:d101:6221::10 UDP 51820
```

That source address is not globally routable, so Proton cannot reply.

Live Cilium status on `penguin` showed IPv6 BPF masquerading attached to:

```text
enp4s0, nut-gc1-penguin, nut-gc2-penguin
```

It did not include `wlp7s0`, even though `wlp7s0` is the lower-metric default route on `penguin`. `wlp7s0` is the Wi-Fi interface; the intended durable path is the wired `enp4s0` interface.

A temporary `/128` route for only the Proton IPv6 endpoint via `enp4s0` made the canary work:

```sh
ssh penguin.wireguard sudo -n ip -6 route replace 2a02:6ea0:d101:6221::10/128 via fe80::1 dev enp4s0 metric 100
```

After that route, tcpdump showed SNAT to `enp4s0`'s global IPv6 address and replies from Proton. `wg show` inside the canary namespace showed a recent handshake, and `ifconfig.co` returned Proton's public IPv6 address:

```text
2a02:6ea0:d101:6221::22
```

Permanent options, in order of preference:

1. Add a NixOS-managed `/128` route on `penguin` for the pinned Proton endpoint via `enp4s0`.
2. Make `enp4s0` win the host's normal default route by assigning it lower IPv4 and IPv6 route metrics than Wi-Fi.
3. Keep a Kubernetes-managed privileged routing helper only if host-level Nix changes are not acceptable.

Chosen fix:

```nix
networking.networkmanager.ensureProfiles.profiles.enp4s0 = {
  ipv4.route-metric = 100;
  ipv6.route-metric = 100;
  ipv6.route1 = "2a02:6ea0:d101:6221::10/128,fe80::1,50";
};
```

This keeps the Proton underlay on `enp4s0`, which Cilium already handles with BPF masquerading through:

```yaml
devices: ens3,enp4s0,nut-+
```

A temporary Cilium change adding `wlp+` was applied during validation and did make the canary work, but that is not the preferred final design because it makes Cilium attach to the Wi-Fi interface. The GitOps source is now intended to use `ens3,enp4s0,nut-+`; apply that after the NixOS route fix is deployed to `penguin`.

Validation from the temporary `wlp+` test:

- `cilium status` returned OK.
- `penguin`'s Cilium agent reported BPF masquerading on `enp4s0`, `wlp7s0`, `nut-gc1-penguin`, and `nut-gc2-penguin`.
- Tcpdump on `wlp7s0` showed Proton UDP traffic SNATed to `wlp7s0`'s global IPv6 address, with replies from Proton.
- `wg show` in the canary network namespace showed a recent handshake and received bytes.
- `ifconfig.co` from inside the canary returned Proton public IPv6 `2a02:6ea0:d101:6221::22`.

The temporary `/128` route was removed after this verification.

## Secret Plan

Create a new 1Password item:

```text
vaults/cluster/items/jellyfin-qbittorrent-protonvpn
```

Expected Kubernetes Secret name after the 1Password operator syncs it:

```text
qbittorrent-protonvpn
```

The `OnePasswordItem` reference for this has been added to `cluster/apps/jellyfin/onepassworditem.yaml`. It will only sync successfully after the item exists in 1Password.

Required fields:

- `WIREGUARD_PRIVATE_KEY`
- `WIREGUARD_ADDRESSES`

Optional fields:

- `SERVER_COUNTRIES`
- `SERVER_REGIONS`
- `SERVER_CITIES`
- `SERVER_HOSTNAMES`

Generate the Proton WireGuard config with:

- a paid Proton VPN plan
- a P2P-capable server
- NAT-PMP / port forwarding enabled
- Moderate NAT disabled
- a fresh config that includes IPv6 support

Do not commit the generated WireGuard config or plaintext key material.

## Phase 1: Canary

Use `.planning/qbittorrent-protonvpn-canary.yaml` as the starting manifest.

Apply it manually only after the 1Password item exists:

```sh
nix develop -c kubectl apply -f .planning/qbittorrent-protonvpn-canary.yaml
```

Watch logs:

```sh
nix develop -c kubectl -n jellyfin logs pod/qbittorrent-protonvpn-canary -c gluetun -f
```

Validate inside the canary:

```sh
nix develop -c kubectl -n jellyfin exec pod/qbittorrent-protonvpn-canary -c gluetun -- ip addr
nix develop -c kubectl -n jellyfin exec pod/qbittorrent-protonvpn-canary -c gluetun -- ip route
nix develop -c kubectl -n jellyfin exec pod/qbittorrent-protonvpn-canary -c gluetun -- ip -6 route
```

Validate the host did not receive VPN routes or rules:

```sh
ssh penguin.wireguard ip route
ssh penguin.wireguard ip -6 route
ssh penguin.wireguard sudo -n wg show
ssh penguin.wireguard sudo -n nft list ruleset
```

Success criteria:

- Gluetun reports the VPN as healthy.
- Gluetun creates `tun0` inside the Pod.
- Proton port forwarding succeeds or logs a forwarded port.
- No Proton default route appears on `penguin`.
- Existing Cilium and host WireGuard state remain healthy.

Clean up the canary:

```sh
nix develop -c kubectl delete -f .planning/qbittorrent-protonvpn-canary.yaml
```

## Phase 2: qBittorrent Deployment Change

Only after Phase 1 succeeds:

1. Add Gluetun to `cluster/apps/jellyfin/qbittorrent-deployment.yaml`.
2. Mount `/dev/net/tun` into the Gluetun container.
3. Give only Gluetun `NET_ADMIN`.
4. Remove qBittorrent `hostPort: 6881` for TCP and UDP.
5. Keep the existing `qbittorrent` ClusterIP Service on port `8080`.
6. Configure Gluetun:
   - `VPN_SERVICE_PROVIDER=protonvpn`
   - `VPN_TYPE=wireguard`
   - `VPN_PORT_FORWARDING=on`
   - `PORT_FORWARD_ONLY=on`
   - `FIREWALL_INPUT_PORTS=8080`
   - start with `FIREWALL_OUTBOUND_SUBNETS=fd00:10:96::/48`
   - add broader cluster-local ranges only if they are proven necessary and route cleanly inside the Cilium Pod namespace
7. Configure qBittorrent to bind torrent traffic to `tun0`.
8. Use Gluetun's `VPN_PORT_FORWARDING_UP_COMMAND` to update qBittorrent's listen port through `http://127.0.0.1:8080/api/v2/app/setPreferences`.

The qBittorrent config currently has `WebUI\LocalHostAuth=false`, so Gluetun can update qBittorrent over localhost without needing to store qBittorrent credentials in Kubernetes.

Applied state:

- Gluetun is running in the qBittorrent Pod as a native sidecar init container.
- The qBittorrent torrent `hostPort: 6881` entries were removed.
- Gluetun is pinned to Proton's IPv6 WireGuard endpoint and uses the `qbittorrent-protonvpn` Secret for the private key and interface addresses.
- Proton port forwarding is enabled with `VPN_PORT_FORWARDING_PROVIDER=protonvpn`.
- Gluetun updates qBittorrent's listen port and network interface over the localhost WebUI API.
- qBittorrent WebUI remains exposed through the existing `qbittorrent` ClusterIP Service on port `8080`.

Verification after rollout:

- `kubectl -n jellyfin rollout status deploy/qbittorrent` succeeded.
- qBittorrent Pod is `2/2 Running`.
- Gluetun logs show Proton WireGuard connected, DNS ready, and forwarded port `57993`.
- qBittorrent config shows `Session\Port=57993`.
- From the qBittorrent container:
  - IPv4 egress returns Proton public IPv4 `159.26.115.14`.
  - IPv6 egress returns Proton public IPv6 `2a02:6ea0:d101:6221::22`.
- A separate in-cluster curl Pod received HTTP `200` from `http://qbittorrent.jellyfin.svc.k8s.internal:8080/`.

## Phase 3: Defense In Depth

After the sidecar deployment works, add a Cilium egress policy for `app.kubernetes.io/name=qbittorrent`:

- allow cluster-local IPv6 ranges required for DNS, WebUI, oauth2-proxy, and service replies
- allow the Proton underlay endpoint or the narrow UDP relay if one is needed
- deny other direct `eth0` internet egress

This is not the primary kill switch. Gluetun's Pod-local firewall is the primary kill switch. The Cilium policy reduces blast radius if the Pod is ever changed incorrectly.

## Rollback

Rollback is simple because the current Deployment is single-container:

1. Revert the qBittorrent Deployment to the current manifest.
2. Restore `hostPort: 6881` if direct node torrent exposure is still desired.
3. Remove the Gluetun sidecar, `/dev/net/tun` volume, and Proton secret references.
4. Reconcile Flux.

## Validation Before Finalizing

Run:

```sh
nix develop -c kubectl kustomize cluster
nix develop -c flux get kustomizations
nix develop -c kubectl -n jellyfin rollout status deploy/qbittorrent
```

Then verify:

- `https://qbittorrent.yadunut.dev` still works.
- qBittorrent reports the Proton forwarded port, not `6881`.
- qBittorrent's visible public IP is Proton's VPN IP.
- Stopping Gluetun blocks torrent egress instead of leaking through Cilium.
- `penguin` host routes and nftables are materially unchanged.
