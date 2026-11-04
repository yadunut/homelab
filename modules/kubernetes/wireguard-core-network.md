# WireGuard Core Network

Kubernetes node transport uses a dedicated IPv6 WireGuard core network instead
of ZeroTier node addresses. BIRD routes node loopbacks and Cilium-assigned
PodCIDRs across the WireGuard mesh.

## Topology

| Node | Core loopback |
| --- | --- |
| `nut-gc1` | `fd5f:97ba:c64d::1/128` |
| `nut-gc2` | `fd5f:97ba:c64d::2/128` |
| `penguin` | `fd5f:97ba:c64d::3/128` |

| Link | Port | Addresses |
| --- | --- | --- |
| `nut-gc1-nut-gc2` | `51831` | `fe80::1/64` <-> `fe80::2/64` |
| `nut-gc1-penguin` | `443` | `fe80::1/64` <-> `fe80::2/64` |
| `nut-gc2-penguin` | `8443` | `fe80::1/64` <-> `fe80::2/64` |

Existing Kubernetes ranges stay unchanged:

- pods: `fd00:10:96::/48`
- services: `fd00:10:97::/108`
- CoreDNS service: `fd00:10:97::a`

## Route Ownership

```text
PodCIDR allocation: Cilium/Kubernetes
Local PodCIDR advertisement: Cilium BGP control plane
Core propagation: BIRD Babel over WireGuard
Remote PodCIDR kernel routes: BIRD
Local PodCIDR route: Cilium on cilium_host
```

Nix stores only the pod aggregate `fd00:10:96::/48`, not per-node PodCIDRs.
Cilium advertises each node's current PodCIDR to local BIRD.

## WireGuard

`modules/kubernetes/10-core-network.nix` creates one WireGuard interface for
each direct node pair involving the current node. WireGuard does not install
routes directly: `allowedIPsAsRoutes = false`.

Peer `AllowedIPs` include:

- remote core loopbacks
- pod aggregate `fd00:10:96::/48`
- Babel transport/control: `fe80::/64`, `ff02::1:6/128`

`nut.kubernetes.coreNetwork.nodes.<name>.publicIp` controls WireGuard
endpoint generation. Nodes with a public IP are directly dialable. Nodes with
`publicIp = null` omit the peer endpoint on other machines; those machines
learn the current endpoint from incoming authenticated WireGuard packets. When
a node without a public IP peers with a directly dialable node, it sends
`PersistentKeepalive = 25` so endpoint changes are refreshed promptly.

## BIRD

`modules/kubernetes/11-core-network-bird.nix` runs BIRD 3.

Babel runs on the `nut-*` WireGuard interfaces with `type tunnel`. It imports
and exports:

- core loopback `/128`s
- PodCIDRs inside `fd00:10:96::/48`

Cilium peers with local BIRD over BGP:

```bird
protocol bgp cilium_bgp {
  local ::1 port 1179 as 64512;
  neighbor <local core node IP> as 64512;
  passive on;
  ipv6 {
    import filter core_pod_routes;
    export none;
  };
}
```

BIRD imports Cilium routes matching:

```bird
net ~ [ fd00:10:96::/48{64,128} ]
```

BIRD exports PodCIDRs to the kernel only when learned from Babel. That keeps the
local PodCIDR on `cilium_host` while installing remote PodCIDRs via WireGuard.

## Cilium

The relevant Helm values live in
`cluster/infrastructure/cilium/helmrelease.yaml`:

```yaml
routingMode: native
autoDirectNodeRoutes: false
ipv6NativeRoutingCIDR: fd00:10:96::/48
k8sServiceHost: fd5f:97ba:c64d::1
devices: ens3,enp4s0,nut-+
extraConfig:
  direct-routing-device: en+
bgpControlPlane:
  enabled: true
  routerIDAllocation:
    mode: ip-pool
    ipPool: 10.255.1.0/24
```

The BGP resources live in `cluster/infrastructure/cilium/bgp.yaml`.
They are node-generic:

```yaml
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: local-bird
spec:
  transport:
    peerPort: 1179
    sourceInterface: lo
```

`sourceInterface: lo` makes Cilium source BGP from the node's stable core
loopback, matching BIRD's `neighbor <local core node IP>`. There are no
`CiliumBGPNodeConfigOverride` resources.

Important invariant: each node should have exactly one usable non-link-local
IPv6 address on `lo` besides `::1`: its stable `fd5f:97ba:c64d::* /128`.

## Kubernetes

Kubernetes node identity and endpoints are derived from
`nut.kubernetes.coreNetwork.nodes`:

- `nut.kubernetes.nodeIP`
- control-plane IP
- generated node maps
- kubelet kubeconfig endpoint
- certificate SANs

Services are ordered after `kubernetes-core-network-ready`, which checks local
loopback, WireGuard interfaces, BIRD, Babel neighbors to directly dialable
peers, and routes to directly dialable remote core loopbacks. Nodes without a
public IP can be absent without blocking stable nodes from starting.

## Validation

On nodes:

```sh
wg show
birdc show protocols
birdc show protocols all cilium_bgp
birdc show babel neighbors
birdc show route for fd5f:97ba:c64d::1
birdc show route for fd5f:97ba:c64d::2
birdc show route for fd5f:97ba:c64d::3
ip -6 route show | grep fd00:10:96
```

In Kubernetes:

```sh
kubectl get nodes -o wide
kubectl -n kube-system exec ds/cilium -- cilium status --brief
kubectl get ciliumbgpnodeconfigs
kubectl get ciliumbgpnodeconfigoverrides
for pod in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$pod" -- cilium bgp peers
done
```

Expected:

- no `CiliumBGPNodeConfigOverride` resources
- Cilium router IDs allocated from `10.255.1.0/24`
- BGP sessions established
- local PodCIDR via `cilium_host`
- remote PodCIDRs via BIRD/Babel over `nut-*`
