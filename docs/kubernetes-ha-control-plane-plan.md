# Kubernetes HA Control Plane Plan

Host module paths in this plan refer to this homelab repository. Publish module
changes here and update nix's homelab input before running Nix evaluation,
build, secret-management, or Clan commands from the nix checkout. See
[host module integration](host-modules.md).

## Summary

The current `modules/kubernetes/` design is single-control-plane. `nut-gc1`
is hard-coded as the API server, the only etcd member, and the kubelet API
endpoint for every node.

This plan changes the cluster to support an odd number of control-plane nodes
with stacked etcd. Worker and control-plane kubelets will use a stable API VIP
on the Kubernetes core WireGuard network. Admin kubeconfig access remains over
Yggdrasil and is intentionally not made highly available in this iteration.

Assumption: the request is to support multiple control-plane nodes. The repo
already supports multiple compute/worker nodes.

## Research Conclusion

Do not use Cilium to own the Kubernetes API server VIP.

Cilium is still the right tool for pod networking, kube-proxy replacement,
service load balancing, BGP advertisement, LB IPAM, and Hubble. It is not the
right owner for the apiserver endpoint that kubelets and Cilium itself need
before the cluster is fully running.

Relevant docs:

- Kubernetes HA topology documents stacked etcd as control-plane nodes with
  co-located etcd members, and says worker access to the apiserver is via a
  load balancer.
- Kubernetes HA setup recommends an odd number of control-plane nodes and a
  load balancer that can reach every apiserver.
- Cilium's kube-proxy replacement setup requires `k8sServiceHost` and
  `k8sServicePort`.
- Cilium LB IPAM assigns IPs to Kubernetes `LoadBalancer` Services and relies
  on BGP Control Plane or L2 announcements to advertise those service IPs.
- Cilium BGP Control Plane advertises Kubernetes Service VIPs as exact routes.
- Cilium L2 Announcements responds to ARP/NDP for `ExternalIP` and
  `LoadBalancer` service IPs on a local L2 network.
- The Cilium upstream issue for apiserver load balancing describes the
  circular dependency: kubelet needs the apiserver endpoint before Cilium can
  start, but a Cilium-managed Service VIP needs Cilium and Kubernetes to be
  running first.

Sources:

- <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/ha-topology/>
- <https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/high-availability/>
- <https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/>
- <https://docs.cilium.io/en/latest/network/lb-ipam/>
- <https://docs.cilium.io/en/latest/network/bgp-control-plane/bgp-control-plane-configuration/>
- <https://docs.cilium.io/en/latest/network/l2-announcements/>
- <https://github.com/cilium/cilium/issues/29323>

## Target Architecture

Use a three-node stacked control plane first:

- `nut-gc1`
- `nut-gc2`
- `penguin`

Every control-plane node runs:

- `kube-apiserver`
- `kube-scheduler`
- `kube-controller-manager`
- `etcd`
- `kubelet`
- `containerd`
- Cilium agent

Every etcd peer/client endpoint uses the stable core WireGuard node IP from
`nut.kubernetes.coreNetwork.nodes`.

Worker/bootstrap Kubernetes API endpoint:

- Add a core-network VIP, for example `fd5f:97ba:c64d::100/128`.
- Kubelet kubeconfigs use `https://[fd5f:97ba:c64d::100]:6443`.
- Cilium Helm values use:
  - `k8sServiceHost=fd5f:97ba:c64d::100`
  - `k8sServicePort=6443`

Admin endpoint:

- Keep `nut.kubernetes.apiServer.adminEndpoint` pointed at one control-plane
  node's Yggdrasil address.
- Add every control-plane node's Yggdrasil address to apiserver cert SANs, so
  `~/.kube/config` can be repointed manually when the current admin node is
  down.

## VIP Recommendation

Use keepalived for a routed VIP on the core WireGuard network. Do not add
HAProxy in the first implementation.

The simple first design:

- keepalived runs only on control-plane nodes.
- The VIP is assigned as `/128` on `lo` on the elected node.
- `kube-apiserver` already binds on `:6443`; when the VIP is on the elected
  node, it serves the VIP directly.
- keepalived uses unicast peers over the core network, not multicast.
- A track script checks the local apiserver readiness endpoint.
- BIRD imports the VIP when it is present on `lo` and exports it over Babel to
  the other core nodes.
- WireGuard peer `AllowedIPs` include the API VIP `/128`, so encrypted traffic
  can follow the BIRD-selected next hop.

This provides failover, not active traffic distribution. That is acceptable for
the first HA control-plane step and avoids the bind/admin-path complexity of
running HAProxy on the same port as `kube-apiserver`.

Add HAProxy later only if we need active load distribution or richer backend
health behavior. If HAProxy is added, explicitly choose one of these approaches:

- Move `kube-apiserver --bind-address` to the core node IP and have HAProxy
  bind the VIP on `:6443`.
- Or keep direct apiserver binds and make the worker endpoint use a separate
  HAProxy port, such as `:7443`.

## Nix Option Changes

Replace singleton control-plane modeling:

```nix
nut.kubernetes.controlPlane = {
  name = "nut-gc1";
  ip = "fd5f:97ba:c64d::1";
};
```

with a set/list based model:

```nix
nut.kubernetes.controlPlane = {
  nodes = {
    nut-gc1 = { ip = "fd5f:97ba:c64d::1"; };
    nut-gc2 = { ip = "fd5f:97ba:c64d::2"; };
    penguin = { ip = "fd5f:97ba:c64d::3"; };
  };

  apiVip = {
    address = "fd5f:97ba:c64d::100";
    prefixLength = 128;
  };
};

nut.kubernetes.apiServer = {
  workerEndpoint = "https://[fd5f:97ba:c64d::100]:6443";
  adminEndpoint = "https://[<selected-yggdrasil-address>]:6443";
  certSans = [
    "fd5f:97ba:c64d::100"
    # all control-plane core IPs
    # all control-plane Yggdrasil addresses
  ];
};
```

Keep the old singleton shape temporarily if needed for a compatibility
transition, but all modules should consume the new derived values.

## Module Work

### `00-kubernetes.nix`

- Define the control-plane node set once.
- Derive `nut.kubernetes.nodes` from `coreNetwork.nodes` as today.
- Derive `controlPlane.nodes` from the selected control-plane names.
- Derive all control-plane Yggdrasil addresses via `clanLib.getPublicValue`.
- Add the API VIP to `apiServer.certSans`.
- Import `kubernetes-control-plane` for each selected control-plane machine.
- Keep `kubernetes-compute` on every Kubernetes node, including
  control-plane nodes.
- Add assertions:
  - control-plane node count is odd
  - every control-plane node exists in `coreNetwork.nodes`
  - API VIP is not equal to any node IP
  - every Kubernetes node has a core-network entry

### `04-etcd.nix`

- Build `services.etcd.initialCluster` from all control-plane nodes:

  ```text
  nut-gc1=https://[fd5f:97ba:c64d::1]:2380
  nut-gc2=https://[fd5f:97ba:c64d::2]:2380
  penguin=https://[fd5f:97ba:c64d::3]:2380
  ```

- Build `nut.kubernetes.etcd.endpoints` as a comma-separated list of all
  control-plane client endpoints:

  ```text
  https://[fd5f:97ba:c64d::1]:2379,https://[fd5f:97ba:c64d::2]:2379,https://[fd5f:97ba:c64d::3]:2379
  ```

- Keep listen/advertise URLs on the local core node IP.
- Keep etcd peer and client TLS on the etcd CA.
- Add an option for `initialClusterState`, defaulting to `new` for a fresh
  cluster. Existing single-node clusters must not be expanded by only changing
  `initialCluster`; use an etcd member-add or snapshot/restore migration.

### `05-control-plane.nix`

- Keep each apiserver `--advertise-address` set to the local core node IP.
- Pass all etcd endpoints to `--etcd-servers`.
- Keep scheduler leader election enabled.
- Set controller-manager leader election explicitly with
  `--leader-elect=true`.
- Keep scheduler/controller-manager kubeconfigs pointed at the local apiserver
  on the core node IP.

### `06-compute-node.nix`

- Replace the kubelet kubeconfig server endpoint with
  `nut.kubernetes.apiServer.workerEndpoint`.
- This applies to workers and control-plane nodes, because control-plane nodes
  also run kubelet.

### `01-ca.nix`

- Add the API VIP to the apiserver certificate SANs.
- Add every control-plane core node IP to the apiserver SANs.
- Add every control-plane Yggdrasil address to the apiserver SANs.
- Keep per-node etcd server/peer certs scoped to the local hostname and core
  node IP.

### `10-core-network.nix`

- Add `nut.kubernetes.coreNetwork.virtualIPs` or a dedicated API VIP option.
- Include the API VIP `/128` in WireGuard peer `allowedIPs`.
- Keep `allowedIPsAsRoutes = false`; BIRD still owns route installation.

### `11-core-network-bird.nix`

- Add core service VIP prefixes to the direct/Babel filters.
- Import the API VIP from `lo` only when keepalived has assigned it locally.
- Export the active VIP route through Babel.
- Accept the VIP route from Babel on non-owner nodes and install it into the
  kernel.
- Do not require the VIP in `kubernetes-core-network-ready.service`, otherwise
  keepalived and readiness can deadlock during boot.

### New keepalived Module

Create a focused module, likely:

```text
modules/kubernetes/12-api-vip.nix
```

Responsibilities:

- Enable keepalived only on control-plane nodes.
- Configure one VRRP instance for the API VIP.
- Use unicast peers from the control-plane core node IPs.
- Assign the VIP as `/128` on `lo`.
- Track local `https://[<node-core-ip>]:6443/readyz`.
- Order after `kubernetes-core-network-ready.service` and
  `kube-apiserver.service`.
- Ensure firewall policy allows VRRP traffic on the trusted core WireGuard
  interfaces.

## Cilium Work

Keep Cilium responsible for Kubernetes networking after the apiserver endpoint
is reachable:

- Continue kube-proxy replacement.
- Change `k8sServiceHost` from `fd5f:97ba:c64d::1` to the API VIP.
- Keep IPv6-only native routing.
- Keep BGP Control Plane peering with local BIRD for PodCIDR advertisements.
- Keep `autoDirectNodeRoutes=false` for the WireGuard/BIRD design.
- Increase `operator.replicas` from `1` to at least `2`.
- For future Service `LoadBalancer` IPs, prefer Cilium LB IPAM plus Cilium BGP
  Control Plane into local BIRD. Avoid L2 Announcements for this core network
  because the WireGuard mesh is routed, not a shared L2 segment.

## Migration Plan

1. Refactor options with a singleton-compatible default.
   - The generated config for the current single-control-plane cluster should
     be unchanged.

2. Add the API VIP plumbing while still running one control-plane node.
   - Add the VIP option.
   - Add keepalived on `nut-gc1`.
   - Add BIRD/WireGuard VIP route handling.
   - Switch kubelet kubeconfigs and Cilium `k8sServiceHost` to the VIP.
   - Validate that all nodes can reach `https://[<vip>]:6443/readyz`.

3. Convert to three stacked control-plane nodes.
   - Add `kubernetes-control-plane` imports for `nut-gc2` and `penguin`.
   - Generate/distribute per-node apiserver, etcd peer, and etcd server certs.
   - Update etcd endpoints and initial cluster config.
   - Use a deliberate etcd migration path:
     - For disposable state: stop the cluster, snapshot anything important,
       wipe/restore etcd as a new three-member cluster, and deploy all
       control-plane nodes together.
     - For preserving state live: add etcd members one at a time with
       `etcdctl member add`, deploy the matching node config, wait for health,
       then continue. Do not just change `initialCluster` on an existing
       single-member data directory.

4. Update Cilium values.
   - Set `k8sServiceHost` to the VIP.
   - Set `operator.replicas >= 2`.
   - Keep BGP resources node-generic.

5. Document the admin failover operation.
   - To switch admin access, edit/regenerate kubeconfig to point at a different
     control-plane node's Yggdrasil address.
   - This is manual by design for now.

## Validation

Before deployment:

```sh
nix flake check
nix build .#nixosConfigurations.nut-gc1.config.system.build.toplevel
nix build .#nixosConfigurations.nut-gc2.config.system.build.toplevel
nix build .#nixosConfigurations.penguin.config.system.build.toplevel
```

After deployment:

```sh
curl -k "https://[fd5f:97ba:c64d::100]:6443/readyz"
kubectl get nodes -o wide
kubectl get --raw=/readyz?verbose
```

On each control-plane node:

```sh
systemctl status etcd kube-apiserver kube-scheduler kube-controller-manager keepalived
etcdctl endpoint status --cluster -w table
etcdctl member list -w table
ip -6 addr show dev lo
birdc show route for fd5f:97ba:c64d::100
```

On worker nodes:

```sh
ip -6 route get fd5f:97ba:c64d::100
curl -k "https://[fd5f:97ba:c64d::100]:6443/readyz"
journalctl -u kubelet -b --no-pager
```

Cilium:

```sh
cilium status --wait
kubectl -n kube-system get pods -l k8s-app=cilium -o wide
kubectl -n kube-system exec ds/cilium -- cilium status --brief
for pod in $(kubectl -n kube-system get pods -l k8s-app=cilium -o name); do
  kubectl -n kube-system exec "$pod" -- cilium bgp peers
done
```

Failover:

```sh
# On the current VIP owner
systemctl stop kube-apiserver

# From another node
watch -n1 'ip -6 route get fd5f:97ba:c64d::100; curl -ks https://[fd5f:97ba:c64d::100]:6443/readyz'
```

Expected result:

- The VIP route moves to another control-plane node.
- kubelets reconnect to the VIP.
- `kubectl get nodes` continues to work once pointed at any alive admin
  Yggdrasil endpoint.
- etcd remains healthy with quorum.

## Open Decisions

- Confirm whether `penguin` should be a permanent control-plane node despite
  also being the NVIDIA/GPU node.
- Choose the exact API VIP address inside `fd5f:97ba:c64d::/48`.
- Decide whether the initial HA migration can recreate etcd from scratch or
  must preserve current state live.
- Decide whether HAProxy is needed after the failover-only VIP is deployed and
  measured.
