# HTTP Proxy for IPv6-Only Kubernetes Cluster

This cluster is IPv6-only, meaning pods cannot directly reach IPv4-only services like GitHub, Docker Hub, or npm registry. An HTTP proxy running on the nodes provides access to these services.

## Proxy Details

| Setting | Value |
|---------|-------|
| Proxy URL | `http://http-proxy.kube-system.svc.k8s.internal:8888` |
| Port | `8888` |
| Type | HTTP CONNECT proxy (tinyproxy) |

## Environment Variables

Most applications respect these standard environment variables:

```yaml
env:
  - name: HTTPS_PROXY
    value: "http://http-proxy.kube-system.svc.k8s.internal:8888"
  - name: HTTP_PROXY
    value: "http://http-proxy.kube-system.svc.k8s.internal:8888"
  - name: NO_PROXY
    value: ".k8s.internal,.svc,localhost,127.0.0.1,10.0.0.0/8,fd00::/8"
```

**Important:** `NO_PROXY` excludes internal cluster traffic from the proxy. Always include:
- `.k8s.internal` - cluster DNS domain
- `.svc` - service short names  
- `fd00::/8` - cluster IPv6 ranges

---

## Configuration Methods

### Method 1: Inline in Deployment/Pod

Add env vars directly to your container spec:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  template:
    spec:
      containers:
        - name: my-app
          image: my-image
          env:
            - name: HTTPS_PROXY
              value: "http://http-proxy.kube-system.svc.k8s.internal:8888"
            - name: HTTP_PROXY
              value: "http://http-proxy.kube-system.svc.k8s.internal:8888"
            - name: NO_PROXY
              value: ".k8s.internal,.svc,localhost,127.0.0.1,10.0.0.0/8,fd00::/8"
```

### Method 2: Using a ConfigMap

Create a reusable ConfigMap for proxy settings:

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: proxy-config
  namespace: default  # or your namespace
data:
  HTTPS_PROXY: "http://http-proxy.kube-system.svc.k8s.internal:8888"
  HTTP_PROXY: "http://http-proxy.kube-system.svc.k8s.internal:8888"
  NO_PROXY: ".k8s.internal,.svc,localhost,127.0.0.1,10.0.0.0/8,fd00::/8"
```

Then reference it in your deployment:

```yaml
spec:
  containers:
    - name: my-app
      envFrom:
        - configMapRef:
            name: proxy-config
```

### Method 3: Kustomize Patch

Use a JSON patch to add proxy vars to any existing deployment:

```yaml
# kustomization.yaml
patches:
  - target:
      kind: Deployment
      name: my-app
    patch: |
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: HTTPS_PROXY
          value: "http://http-proxy.kube-system.svc.k8s.internal:8888"
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: HTTP_PROXY
          value: "http://http-proxy.kube-system.svc.k8s.internal:8888"
      - op: add
        path: /spec/template/spec/containers/0/env/-
        value:
          name: NO_PROXY
          value: ".k8s.internal,.svc,localhost,127.0.0.1,10.0.0.0/8,fd00::/8"
```

### Method 4: Helm Values

For Helm charts, look for proxy configuration options:

```yaml
# values.yaml
env:
  - name: HTTPS_PROXY
    value: "http://http-proxy.kube-system.svc.k8s.internal:8888"
  - name: HTTP_PROXY
    value: "http://http-proxy.kube-system.svc.k8s.internal:8888"
  - name: NO_PROXY
    value: ".k8s.internal,.svc,localhost,127.0.0.1,10.0.0.0/8,fd00::/8"

# Or if the chart has specific proxy settings:
proxy:
  httpProxy: "http://http-proxy.kube-system.svc.k8s.internal:8888"
  httpsProxy: "http://http-proxy.kube-system.svc.k8s.internal:8888"
  noProxy: ".k8s.internal,.svc,localhost,127.0.0.1,10.0.0.0/8,fd00::/8"
```

---

## Common Applications

| Application | Needs Proxy For | Config Location |
|-------------|-----------------|-----------------|
| Flux source-controller | GitHub, GitLab | Kustomize patch in `cluster/flux-system/kustomization.yaml` |
| ArgoCD repo-server | Git repos | `argocd-cmd-params-cm` ConfigMap |
| Tekton | Git clone, image pull | Pipeline env vars |
| cert-manager | ACME HTTP challenges | Deployment env |
| External Secrets | External APIs | Deployment env |
| Renovate | GitHub API | Deployment env |

### Flux Example

See `cluster/flux-system/kustomization.yaml` for how Flux is configured to use the proxy.

---

## Testing

```bash
# Test proxy connectivity from a pod
kubectl run test-proxy --rm -it --image=nicolaka/netshoot -- \
  curl -x "http://http-proxy.kube-system.svc.k8s.internal:8888" -I https://github.com

# Expected output:
# HTTP/1.0 200 Connection established
# HTTP/2 200
```

---

## Troubleshooting

### Connection timeouts

1. Verify http-proxy pods are running:
   ```bash
   kubectl -n kube-system get pods -l app=http-proxy
   ```

2. Check if the node has IPv4 connectivity:
   ```bash
   ssh <node> "curl -4 -I https://github.com"
   ```

### DNS resolution failures in proxy logs

The proxy uses the node's DNS, not cluster DNS. Internal `.k8s.internal` domains won't resolve through the proxy - ensure they're in `NO_PROXY`.

### Application not using proxy

- Some apps use lowercase vars (`http_proxy`), add both cases if needed
- Some apps have their own proxy config (e.g., Git's `http.proxy` setting)
- Check if the app supports `HTTPS_PROXY` at all

### Proxy logs

```bash
kubectl -n kube-system logs -l app=http-proxy --tail=50
```

---

## How It Works

```
Pod sets HTTPS_PROXY=http://http-proxy.kube-system.svc.k8s.internal:8888
  → Pod connects to github.com through proxy
    → Proxy resolves github.com to IPv4 (using node's dual-stack DNS)
      → Proxy connects to GitHub over IPv4 (via hostNetwork)
        → Response returned to pod over IPv6
```

The proxy runs as a DaemonSet with `hostNetwork: true`, giving it access to the node's IPv4 connectivity while being accessible to pods via the cluster service.

