# DNS64 + NAT64: Enabling IPv6-Only Networks to Reach IPv4 Services

## The Problem

You have an IPv6-only Kubernetes cluster, but many internet services (like GitHub) only support IPv4. When a pod tries to connect to `github.com`:

1. DNS returns only an IPv4 address: `20.205.243.166`
2. The pod tries to connect to this IPv4 address
3. **Connection fails** - there's no IPv4 route from the pod network

```
dial tcp 20.205.243.166:443: connect: network is unreachable
```

## The Solution: DNS64 + NAT64

DNS64 and NAT64 work together to allow IPv6-only clients to communicate with IPv4-only servers.

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                           How DNS64 + NAT64 Works                           │
└─────────────────────────────────────────────────────────────────────────────┘

  IPv6-only Pod                                              IPv4-only Server
       │                                                          │
       │  1. "What's the IP for github.com?"                      │
       ▼                                                          │
  ┌─────────┐                                                     │
  │  DNS64  │  2. Queries upstream DNS, gets: 20.205.243.166      │
  │ Server  │  3. No AAAA record? Synthesize one!                 │
  │         │  4. Returns: 64:ff9b::14cd:f3a6                     │
  └─────────┘     (IPv4 embedded in IPv6 address)                 │
       │                                                          │
       │  5. Pod connects to 64:ff9b::14cd:f3a6                   │
       ▼                                                          │
  ┌─────────┐                                                     │
  │  NAT64  │  6. Recognizes the 64:ff9b::/96 prefix              │
  │ Gateway │  7. Extracts IPv4: 20.205.243.166                   │
  │         │  8. Translates packet: IPv6 → IPv4                  │
  └─────────┘                                                     │
       │                                                          │
       └──────────────── IPv4 packet ────────────────────────────►│
                                                                  │
       ◄─────────────── IPv4 response ────────────────────────────┘
       │
  ┌─────────┐
  │  NAT64  │  9. Translates response: IPv4 → IPv6
  │ Gateway │
  └─────────┘
       │
       ▼
  IPv6-only Pod receives response
```

---

## What is DNS64?

**DNS64** is a DNS server feature that synthesizes AAAA (IPv6) records for domains that only have A (IPv4) records.

### How it works:

1. Client asks DNS64 server: "What's the AAAA record for github.com?"
2. DNS64 queries upstream DNS and finds only an A record: `20.205.243.166`
3. DNS64 synthesizes an AAAA record by:
   - Taking a well-known prefix (typically `64:ff9b::/96`)
   - Embedding the IPv4 address in the last 32 bits
   - `20.205.243.166` → `0x14.0xcd.0xf3.0xa6` → `64:ff9b::14cd:f3a6`
4. Returns the synthesized AAAA record to the client

### The NAT64 Well-Known Prefix

The prefix `64:ff9b::/96` is the **well-known NAT64 prefix** defined in [RFC 6052](https://tools.ietf.org/html/rfc6052). The last 32 bits hold the IPv4 address:

```
64:ff9b::14cd:f3a6
├──────┤ ├───────┤
 Prefix   IPv4 (20.205.243.166 in hex)
```

You can also use a custom prefix from your own IPv6 allocation.

---

## What is NAT64?

**NAT64** is a network address translation mechanism that translates IPv6 packets to IPv4 packets (and vice versa).

### How it works:

1. NAT64 gateway receives an IPv6 packet destined for `64:ff9b::14cd:f3a6`
2. Recognizes the NAT64 prefix (`64:ff9b::/96`)
3. Extracts the IPv4 address from the last 32 bits: `20.205.243.166`
4. Translates the IPv6 packet to an IPv4 packet
5. Sends it to the IPv4 destination
6. When the response comes back, translates IPv4 → IPv6 and returns to the client

---

## Public DNS64 Services

Several providers offer free DNS64 servers that use the well-known `64:ff9b::/96` prefix:

| Provider   | DNS64 Servers                                      |
|------------|---------------------------------------------------|
| Cloudflare | `2606:4700:4700::64`, `2606:4700:4700::6400`     |
| Google     | `2001:4860:4860::64`, `2001:4860:4860::6464`     |

**Note:** These DNS64 servers synthesize AAAA records, but you still need a NAT64 gateway to actually route the traffic!

---

## NAT64 Gateway Options

### Option 1: Public NAT64 (If Available)

Some ISPs and cloud providers offer NAT64 gateways that route the `64:ff9b::/96` prefix. Test if yours works:

```bash
# From an IPv6-only host
ping6 64:ff9b::8.8.8.8  # 8.8.8.8 = Google DNS
```

If this works, you just need DNS64 and can use the public NAT64.

### Option 2: Self-Hosted NAT64 with Jool

[Jool](https://www.jool.mx/) is a Linux kernel module that provides NAT64 translation.

```bash
# Install Jool (on each node that needs NAT64)
modprobe jool
jool instance add "nat64" --iptables --pool6 64:ff9b::/96

# Add SNAT for outgoing IPv4
ip6tables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
```

### Option 3: Self-Hosted NAT64 with Tayga

[Tayga](http://www.litech.org/tayga/) is a userspace stateless NAT64 implementation.

```bash
# /etc/tayga.conf
tun-device nat64
ipv4-addr 192.168.255.1
ipv6-addr 2001:db8::1
prefix 64:ff9b::/96
dynamic-pool 192.168.255.0/24
```

### Option 4: In-Cluster NAT64 with kindnet

The [kindnet](https://github.com/aojea/kindnet) CNI has built-in NAT64 support using nftables TPROXY.

---

## Implementation for Your Cluster

### Current State

Your cluster:
- **Cilium** with `enable-ipv4: false` (IPv6-only pods)
- **Nodes** have both IPv4 and IPv6 connectivity
- **CoreDNS** forwards to IPv6 DNS servers (Cloudflare, Google)
- **No NAT64 gateway** - the public `64:ff9b::/96` route doesn't work

### Recommended Implementation

Since your nodes have IPv4, the simplest approach is:

#### Step 1: Update CoreDNS with DNS64

Add the `dns64` plugin to CoreDNS to synthesize AAAA records:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns
  namespace: kube-system
data:
  Corefile: |
    .:53 {
        errors
        health {
            lameduck 5s
        }
        ready
        kubernetes k8s.internal in-addr.arpa ip6.arpa {
            pods insecure
            fallthrough in-addr.arpa ip6.arpa
            ttl 30
        }
        # DNS64: Synthesize AAAA records for IPv4-only domains
        dns64 64:ff9b::/96 {
            prefix 64:ff9b::/96
            translate_all  # Translate even if real AAAA exists (optional)
        }
        forward . 2606:4700:4700::1111 2001:4860:4860::8888 {
            max_concurrent 1000
        }
        cache 30
        reload
        loadbalance
    }
```

#### Step 2: Deploy NAT64 on Each Node

Since public NAT64 doesn't work from your network, you need to run NAT64 on each node.

**Option A: Jool (Kernel Module)**

Create a NixOS module:

```nix
# modules/nat64.nix
{ config, pkgs, ... }:
{
  boot.extraModulePackages = [ pkgs.linuxPackages.jool ];
  boot.kernelModules = [ "jool" ];
  
  systemd.services.jool-nat64 = {
    description = "Jool NAT64";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.jool-cli}/bin/jool instance add nat64 --iptables --pool6 64:ff9b::/96";
      ExecStop = "${pkgs.jool-cli}/bin/jool instance remove nat64";
    };
  };
  
  # Route NAT64 prefix to the local Jool instance
  networking.localCommands = ''
    ip -6 route add local 64:ff9b::/96 dev lo
  '';
}
```

**Option B: Tayga (Userspace)**

```nix
# modules/nat64-tayga.nix
{ config, pkgs, ... }:
{
  environment.etc."tayga.conf".text = ''
    tun-device nat64
    ipv4-addr 192.168.255.1
    prefix 64:ff9b::/96
    dynamic-pool 192.168.255.0/24
    data-dir /var/lib/tayga
  '';
  
  systemd.services.tayga = {
    description = "Tayga NAT64";
    after = [ "network.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.tayga}/bin/tayga -d --config /etc/tayga.conf";
      Restart = "always";
    };
  };
}
```

#### Step 3: Route NAT64 Prefix Through Cilium

Ensure Cilium routes traffic for `64:ff9b::/96` to the node's NAT64 gateway. This may require adding the prefix to Cilium's configuration or using a static route.

---

## Alternative: Just Enable Dual-Stack

If NAT64 complexity isn't worth it, the simpler solution is enabling dual-stack in Cilium:

```yaml
# Cilium Helm values
ipv4:
  enabled: true
ipv6:
  enabled: true
ipam:
  operator:
    clusterPoolIPv4PodCIDRList: ["10.244.0.0/16"]
    clusterPoolIPv6PodCIDRList: ["fd00:10:96::/48"]
```

Pods will get both IPv4 and IPv6 addresses and can reach any destination.

---

## Testing

### Test DNS64

```bash
# Should return a synthesized AAAA record
kubectl run test-dns64 --rm -it --image=nicolaka/netshoot -- \
  dig @fd00:10:97::a AAAA github.com

# Expected: 64:ff9b::14cd:f3a6 (or similar)
```

### Test NAT64 Connectivity

```bash
# Should successfully connect through NAT64
kubectl run test-nat64 --rm -it --image=nicolaka/netshoot -- \
  curl -6 -I https://github.com

# Expected: HTTP/2 200
```

---

## Summary

| Component | Purpose | Implementation |
|-----------|---------|----------------|
| **DNS64** | Synthesizes AAAA records for IPv4-only domains | CoreDNS `dns64` plugin |
| **NAT64** | Translates IPv6↔IPv4 packets | Jool, Tayga, or public gateway |

Together, they create a transparent bridge allowing IPv6-only clients to reach IPv4-only servers without any application changes.

---

## References

- [RFC 6146 - NAT64](https://tools.ietf.org/html/rfc6146)
- [RFC 6147 - DNS64](https://tools.ietf.org/html/rfc6147)
- [RFC 6052 - IPv6 Addressing of IPv4/IPv6 Translators](https://tools.ietf.org/html/rfc6052)
- [Jool NAT64](https://www.jool.mx/)
- [Tayga NAT64](http://www.litech.org/tayga/)
- [CoreDNS dns64 plugin](https://coredns.io/plugins/dns64/)

