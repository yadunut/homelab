# Homelab Architecture

This document describes the homelab’s multi‑node Kubernetes (k3s) cluster, node roles and capacities, networking (ZeroTier overlay and Tailscale admin plane), traffic flow (DNS, Ingress, LoadBalancing), core infrastructure services, and deployed applications. A Mermaid diagram at the end visualizes the topology and flows.

## Overview
- Orchestrator: k3s with embedded etcd on all nodes; cluster init is `premhome-gc1`.
- Overlay network: ZeroTier (`10.222.0.0/23`) used for k8s node IPs and flannel (host-gw) via interface `ztxh6lvd6t`.
- Admin plane: Tailscale on all nodes, used only for SSH/admin access.
- Ingress: Traefik with a single external LoadBalancer via MetalLB; internal access via ClusterIP/Ingress.
- DNS: Cloudflare via external-dns.
- TLS: cert-manager using Let’s Encrypt with wildcard certs for `yadunut.dev` and `i.yadunut.dev`.
- Secrets: 1Password Connect + Operator.
- Storage: Longhorn across all 4 nodes.
- SSO: Authentik (OIDC) + forwardAuth middleware; `i.yadunut.dev` endpoints are behind Authentik by default.

## Nodes
- premhome-gc1
  - Role: k3s control-plane/etcd (cluster init). Label: `ingress=true` (schedules Traefik).
  - IPs: Public `167.253.159.47`; ZeroTier `10.222.0.13`.
  - Services: Hosts public Traefik LoadBalancer via MetalLB; participates in Longhorn.
- premhome-falcon-1
  - Role: k3s control-plane/etcd.
  - IPs: Private `10.0.0.55`; ZeroTier `10.222.0.198`.
  - Services: Runs Proxmox proxy deployment; participates in Longhorn.
- premhome-eagle-1
  - Role: k3s control-plane/etcd.
  - IPs: Private `10.0.0.248`; ZeroTier `10.222.0.118`.
  - Services: Participates in Longhorn.
- penguin
  - Role: k3s control-plane/etcd.
  - Capacity: 32 cores, 64 GB RAM, 2 TB storage.
  - IPs: ZeroTier `10.222.0.249`.
  - Labels: `nixos-nvidia-cdi=enabled` (GPU CDI). Hosts GPU workloads (e.g., Open‑WebUI + Ollama).

All nodes run Tailscale for admin/SSH. All four nodes are Longhorn data nodes.

## Networking
- ZeroTier (k8s overlay)
  - Network: `10.222.0.0/23` (e.g., `10.222.0.13` gc1, `10.222.0.198` falcon, `10.222.0.118` eagle, `10.222.0.249` penguin).
  - Flannel: `--flannel-iface=ztxh6lvd6t`, backend `host-gw`. k3s `--node-ip` set to ZT IP.
- Tailscale (admin plane)
  - Used only for SSH/admin; not used for service exposure or cluster networking.
- MetalLB (LoadBalancer IPs)
  - External pool: `167.253.159.47/32` (named `premhome-gc1`) for public ingress.
- Ingress and traffic flow
  - Traefik controller runs on node(s) labeled `ingress=true` (currently `premhome-gc1`).
  - External Service `traefik-external` (MetalLB) advertises `167.253.159.47` and exposes 80/443 plus `git-ssh` on 2222.
  - Internal endpoints (including `*.i.yadunut.dev`) are routed via Traefik to ClusterIP Services; `traefik-internal` is ClusterIP and only used as an Ingress backend for the dashboard.
- DNS and TLS
  - external-dns manages records in Cloudflare for `yadunut.dev`. Public ingress uses `*.yadunut.dev`.
  - cert-manager issues wildcard certs for `yadunut.dev` and `i.yadunut.dev`. Secrets are auto-reflected to namespaces via emberstack/reflector.

## Core Infrastructure
- Traefik (Helm)
  - External LB: `traefik-external` on `167.253.159.47` exposing 80/443/2222.
  - Internal access: ClusterIP Services (including `traefik-internal`) used by Ingress only; no internal MetalLB VIPs.
  - TCP Ingress (git-ssh 2222) routes to Gitea SSH.
- MetalLB (Helm): address pools as above.
- external-dns (Helm): Cloudflare provider, token from 1Password.
- cert-manager (Helm): issuers `letsencrypt-staging` and `letsencrypt-prod` + wildcard certs.
- 1Password Connect + Operator (Helm): sources secrets for apps and infra (e.g., Cloudflare token, app credentials).
- Reflector (Helm): syncs TLS secrets to app namespaces.
- Longhorn (Helm): distributed storage across all four nodes.
- Authentik (Helm): OIDC provider + forwardAuth middleware used by internal ingresses and selected public endpoints.
- GPU CDI Plugin: generic CDI plugin DaemonSet scheduled on nodes with `nixos-nvidia-cdi=enabled` (penguin).

## Applications (GitOps)
- Harbor: `harbor.yadunut.dev` (public), TLS via wildcard `yadunut.dev`.
- Gitea: `git.yadunut.dev` (public), HTTP via Traefik; SSH via Traefik TCP on 2222.
- Open‑WebUI (+ Ollama): `chat.yadunut.dev` (public), OIDC via Authentik, GPU on penguin.
- Proxmox Proxy: `proxmox.i.yadunut.dev` (internal, behind Authentik), proxies to `10.0.0.5:8006`.
- Longhorn UI: `longhorn.i.yadunut.dev` (internal, behind Authentik).
- Podinfo: `podinfo.i.yadunut.dev` (internal, behind Authentik).
- Yadunut.dev site: `yadunut.dev` (public).

Note: Grafana manifests exist but observability is intentionally out-of-scope here.

## Mermaid Diagram
```mermaid
flowchart TB
  subgraph Internet
    U[Users] --> DNS[Cloudflare DNS<br/>(yadunut.dev)]
  end

  DNS -->|A/CNAME: *.yadunut.dev| EXT_IP[167.253.159.47<br/>(MetalLB external)]
  EXT_IP -->|80/443/2222| TRX[Traefik External<br/>LoadBalancer]

  TRX --> Harbor[Harbor]
  TRX --> Gitea[Gitea HTTP]
  TRX -->|TCP 2222| GiteaSSH[Gitea SSH<br/>(IngressRouteTCP)]
  TRX --> OpenWebUI[Open‑WebUI]
  TRX --> Site[yadunut.dev app]
  TRX --> Authn[Authentik (OIDC)]

  subgraph ZT[ZeroTier Overlay: 10.222.0.0/23]
    subgraph K3s[ k3s Cluster (flannel host-gw on ztxh6lvd6t) ]
      GC1[premhome-gc1\n10.222.0.13\nlabel: ingress=true]:::cp
      FAL[premhome-falcon-1\n10.222.0.198]:::cp
      EAG[premhome-eagle-1\n10.222.0.118]:::cp
      PENG[penguin\n10.222.0.249\nlabel: nixos-nvidia-cdi]:::cp

      TraefikCtl[Traefik Controller]:::ing
      Longhorn[Longhorn Storage]:::stor
      OnePass[1Password Connect+Operator]:::sec
      CertMgr[cert-manager]:::tls
      ExtDNS[external-dns]:::dns
      Reflector[reflector]:::infra
      Authentik[Authentik]:::auth
    end
  end

  TRX -->|i.yadunut.dev| LonghornUI[Longhorn UI]
  TRX -->|i.yadunut.dev| ProxmoxProxy[Proxmox Proxy]
  TRX -->|i.yadunut.dev| Podinfo[Podinfo]

  subgraph AdminPlane[Admin Plane]
    TS[Tailscale (SSH/Admin on all nodes)]:::infra
  end
  TS --> GC1
  TS --> FAL
  TS --> EAG
  TS --> PENG

  classDef cp fill:#eef,stroke:#55f,stroke-width:1px
  classDef ing fill:#efe,stroke:#4a4,stroke-width:1px
  classDef stor fill:#ffe,stroke:#aa0,stroke-width:1px
  classDef sec fill:#fef,stroke:#a4a,stroke-width:1px
  classDef tls fill:#eef,stroke:#88a,stroke-width:1px
  classDef dns fill:#eef,stroke:#88a,stroke-width:1px
  classDef infra fill:#eee,stroke:#888,stroke-width:1px
  classDef auth fill:#eef,stroke:#68a,stroke-width:1px
  classDef int fill:#ddd,stroke:#777,stroke-width:1px
```

## Notes and Observations
- Internal MetalLB pool has been removed; internal Services are ClusterIP and reached via Traefik/Ingress.
- `*.i.yadunut.dev` resolves to the public Traefik IP and is protected by Authentik.
- Traefik `git-ssh` entrypoint (2222/TCP) terminates on `167.253.159.47` and routes via `IngressRouteTCP` to Gitea’s SSH service.
- Minor consistency to review: Gitea’s Ingress uses host `git.yadunut.dev` while its TLS secret in GitOps references `wildcard-cert-i.yadunut.dev-prod`; consider switching to `wildcard-cert-yadunut.dev-prod` for that ingress.
- No taints are set on nodes today; Traefik tolerates `dedicated=ingress:NoSchedule`, but such a taint is not applied.

---
Generated from the repo’s GitOps manifests and a live cluster snapshot (`kubectl get nodes/svc/ingress`).
