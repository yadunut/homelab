# Kubernetes The Hard Way - NixOS

This directory defines an IPv6-only Kubernetes cluster built from individual
NixOS services and orchestrated with clan. It does not use kubeadm.

The nix repository imports these modules through `flakeModules.kubernetes`.
See [host module integration](../../docs/host-modules.md) for the consumer
contract and validation workflow.

## Architecture

| Role | Nodes |
| --- | --- |
| Control plane and compute | `nut-gc1` |
| Compute | `nut-gc2`, `penguin` |
| Container runtime | containerd |
| CNI and service proxy | Cilium with kube-proxy replacement |
| Node transport | WireGuard |
| Core routing | BIRD: Babel between nodes, BGP from local Cilium |
| IPv4 compatibility | CoreDNS DNS64 and per-node Jool NAT64 |

The network has four distinct address planes:

```text
Public IPv4/IPv6 underlay
        |
        | WireGuard
        v
Stable node network: fd5f:97ba:c64d::/48
        |
        | BIRD and Cilium native routing
        v
Pod network:          fd00:10:96::/48
Service network:      fd00:10:97::/108
IPv4 translation:     64:ff9b::/96
```

## Cluster Addresses

| Setting | Value |
| --- | --- |
| Pod CIDR | `fd00:10:96::/48` |
| Service CIDR | `fd00:10:97::/108` |
| CoreDNS service | `fd00:10:97::a` |
| Cluster domain | `k8s.internal` |
| NAT64 prefix | `64:ff9b::/96` |
| API server port | `6443` |

Each node has a stable core address on `lo`:

| Node | Core address |
| --- | --- |
| `nut-gc1` | `fd5f:97ba:c64d::1/128` |
| `nut-gc2` | `fd5f:97ba:c64d::2/128` |
| `penguin` | `fd5f:97ba:c64d::3/128` |

Kubelet, etcd, and the API server use these addresses for cluster traffic. The
admin kubeconfig uses the control plane's Yggdrasil address so administrative
access does not depend on joining the WireGuard core network.

## WireGuard Core Network

`10-core-network.nix` creates a point-to-point WireGuard interface for every
configured node pair:

```text
             nut-gc1
          /           \
     UDP 51831        UDP 443
       /                 \
 nut-gc2 ---- UDP 8443 ---- penguin
```

The two sides of each interface use `fe80::1/64` and `fe80::2/64`. Reusing
these addresses is safe because every link is a separate interface.

`nut-gc1` and `nut-gc2` have directly dialable public addresses. `penguin`
dials their IPv4 endpoint overrides and uses a persistent keepalive; the
public nodes learn Penguin's endpoint from incoming authenticated packets.

WireGuard validates the permitted node, Pod, and Babel addresses but does not
install routes itself:

```nix
allowedIPsAsRoutes = false;
```

BIRD owns route selection and installation. See
[`wireguard-core-network.md`](./wireguard-core-network.md) for the detailed
link and routing design.

## Routing

`11-core-network-bird.nix` runs BIRD 3 with two routing protocols.

### Babel between nodes

Babel runs over the WireGuard interfaces and distributes:

- stable node loopback `/128`s;
- per-node PodCIDRs within `fd00:10:96::/48`.

The triangular topology permits alternate paths when a direct path is
unavailable.

### BGP from Cilium to local BIRD

Kubernetes allocates each node a PodCIDR. Cilium advertises that local PodCIDR
to BIRD over an on-node BGP session:

```text
Cilium (node loopback) -> BIRD (::1:1179), ASN 64512
```

BIRD accepts only Pod prefixes inside `fd00:10:96::/48`, then propagates them
to other nodes using Babel. BIRD installs only remote PodCIDRs into the kernel;
Cilium retains ownership of the local route through `cilium_host`.

A cross-node packet therefore follows this path:

```text
Pod -> local Cilium -> BIRD-learned kernel route -> WireGuard
    -> remote kernel/Cilium -> Pod
```

## Cilium

The NixOS modules prepare containerd, CNI paths, forwarding, and firewall
rules. Flux deploys Cilium from:

[`cluster/infrastructure/cilium/helmrelease.yaml`](../../cluster/infrastructure/cilium/helmrelease.yaml)

The important values are:

```yaml
ipam:
  mode: kubernetes
ipv4:
  enabled: false
ipv6:
  enabled: true
routingMode: native
autoDirectNodeRoutes: false
ipv6NativeRoutingCIDR: fd00:10:96::/48
kubeProxyReplacement: true
k8sServiceHost: fd5f:97ba:c64d::1
k8sServicePort: 6443
bgpControlPlane:
  enabled: true
```

`autoDirectNodeRoutes` must remain disabled because BIRD and Babel distribute
remote PodCIDRs. Cilium replaces kube-proxy with eBPF service handling, so the
Service CIDR is not advertised through Babel.

The BGP resources are in:

[`cluster/infrastructure/cilium/bgp.yaml`](../../cluster/infrastructure/cilium/bgp.yaml)

## DNS and IPv4 Compatibility

Kubelet configures pods to use CoreDNS at `fd00:10:97::a`. CoreDNS serves the
`k8s.internal` cluster domain and applies DNS64 for external IPv4-only names.
Its manifests are in:

[`cluster/infrastructure/coredns/coredns.yaml`](../../cluster/infrastructure/coredns/coredns.yaml)

For an IPv4-only destination, traffic follows:

```text
DNS64 synthesizes 64:ff9b::<IPv4>
        |
        v
IPv6-only pod
        |
        v
Jool NAT64 on the local node
        |
        v
IPv4 destination
```

`12-nat64-jool.nix` configures a stateful translator on each node. Each
translator uses that node's IPv4 address and reserves ports `61001-65535` for
translations. An nftables rule clears Cilium packet marks before Jool evaluates
NAT64 traffic.

## Service Startup

Cluster services depend on `kubernetes-core-network-ready.service`:

```text
WireGuard -> BIRD -> core-network-ready
                         |
                  +------+------+
                  |      |      |
                 etcd   API   kubelet
```

The readiness check verifies:

- the stable loopback address;
- all configured local WireGuard interfaces;
- BIRD availability;
- Babel neighbors for directly dialable peers;
- routes to directly dialable remote loopbacks.

Public nodes can start while the non-public `penguin` node is absent. Penguin
waits for its directly dialable public peers.

## Deployment and Verification

Publish changes here and update nix's homelab input lock first. Then deploy
NixOS changes with clan from the nix checkout:

```sh
nix develop
agenix rekey
clan machines update nut-gc1
clan machines update nut-gc2
clan machines update penguin
```

Certificates, kubeconfigs and network keys are managed by agenix-rekey; see
[secret management](https://git.yadunut.dev/yadunut/nix/src/branch/main/docs/secrets.md) for generation and rotation.

Cilium and CoreDNS are managed by Flux in this repository. After both
the host configuration and cluster resources have reconciled, verify:

```sh
kubectl get nodes -o wide
kubectl -n kube-system get pods
kubectl -n kube-system exec ds/cilium -- cilium status --brief
```

Inspect the core network on a node with:

```sh
wg show
birdc show protocols
birdc show protocols all cilium_bgp
birdc show babel neighbors
ip -6 route show | grep fd00:10:96
```

Expected results:

- all Kubernetes nodes are `Ready`;
- each Cilium-to-BIRD BGP session is established;
- the local PodCIDR is routed through `cilium_host`;
- remote PodCIDRs are installed by BIRD through WireGuard interfaces;
- stable remote core loopbacks are reachable.

Test cluster and IPv4 connectivity:

```sh
nix run "nixpkgs#cilium-cli" -- connectivity test

kubectl run nat64-test --rm -it --restart=Never \
  --image=curlimages/curl -- curl -I https://github.com
```

## Troubleshooting

### Core network is not ready

```sh
systemctl status kubernetes-core-network-ready
journalctl -u kubernetes-core-network-ready -b
wg show
birdc show protocols
birdc show babel neighbors
```

Check that the WireGuard endpoint is reachable and that the expected UDP port
is open. For Penguin links, verify that Penguin initiated the tunnel and that
persistent keepalives are visible in `wg show`.

### Nodes are `NotReady`

```sh
journalctl -u kubelet -f
ls -la /etc/cni/net.d/
ls -la /opt/cni/bin/
kubectl -n kube-system logs -l k8s-app=cilium --tail=100
```

### Cross-node pods cannot communicate

```sh
birdc show protocols all cilium_bgp
birdc show babel neighbors
birdc show route for fd00:10:96::
ip -6 route show | grep fd00:10:96
```

Confirm that Cilium advertises a local PodCIDR, Babel propagates it, and the
remote node installs it through the expected WireGuard interface.

### IPv4-only destinations fail

```sh
kubectl -n kube-system get service kube-dns
journalctl -u jool -b
jool instance display
```

Confirm that CoreDNS synthesizes an address under `64:ff9b::/96`, Jool is
active on the pod's node, and the configured node IPv4 address is valid.

### API server connectivity fails

```sh
systemctl status kube-apiserver etcd
curl -k 'https://[fd5f:97ba:c64d::1]:6443/healthz'
```

The internal endpoint requires the core network. Administrative kubeconfigs
instead use the Yggdrasil endpoint configured in `00-kubernetes.nix`.

## Module Map

| File | Responsibility |
| --- | --- |
| `00-kubernetes.nix` | Cluster addresses, topology, and node identity |
| `01-ca.nix` | Cluster certificates and network-address SANs |
| `02-kubeconfig.nix` | Administrative kubeconfig |
| `04-etcd.nix` | etcd core-network listeners |
| `05-control-plane.nix` | API server and controller networking |
| `06-compute-node.nix` | Kubelet, containerd, CNI paths, and firewall rules |
| `10-core-network.nix` | WireGuard mesh |
| `11-core-network-bird.nix` | Babel, local Cilium BGP, routes, and readiness |
| `12-nat64-jool.nix` | Per-node NAT64 |
| `13-frp.nix` | TCP port `2200` firewall opening |

## References

- [Kubernetes The Hard Way](https://github.com/kelseyhightower/kubernetes-the-hard-way)
- [Cilium documentation](https://docs.cilium.io/)
- [BIRD documentation](https://bird.nic.cz/doc/bird-3.1.0.html)
- [Jool documentation](https://www.jool.mx/)
