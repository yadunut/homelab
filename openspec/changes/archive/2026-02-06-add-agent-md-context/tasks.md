## 1. Source Audit

- [x] 1.1 Inventory existing guidance and source files (`AGENTS.md`, `Readme.md`, `docs/http-proxy-guide.md`, `docs/storage.md`) to collect canonical content
- [x] 1.2 Verify core cluster invariants in manifests (Flux scope/order, `k8s.internal` DNS, Traefik ingress model, ExternalDNS CRD mode, storage classes)
- [x] 1.3 Confirm secret and identity conventions from manifests (1Password `OnePasswordItem`, OIDC/group-gated admin access)

## 2. AGENTS.md Rewrite

- [x] 2.1 Replace `/Users/yadunut/dev/src/git.yadunut.dev/yadunut/homelab/AGENTS.md` content with consolidated agent guidance (no parallel `AGENT.md` file)
- [x] 2.2 Add networking/proxy section with required proxy endpoint and `HTTP_PROXY`/`HTTPS_PROXY`/`NO_PROXY` defaults for IPv4-only egress
- [x] 2.3 Add reconciliation section documenting Flux source branch/path and infrastructure-before-apps ordering
- [x] 2.4 Add DNS/ingress/auth section documenting `k8s.internal`, ExternalDNS `DNSEndpoint` usage, Traefik patterns, and Kanidm passthrough/OIDC conventions
- [x] 2.5 Add storage section documenting `longhorn` vs `longhorn-local-1r` selection intent and link to storage operational reference

## 3. Consistency and Safety Checks

- [x] 3.1 Ensure guidance explicitly marks generated `cluster/flux-system/gotk-*.yaml` files as non-edit targets
- [x] 3.2 Ensure guidance explicitly requires 1Password-backed secret sourcing and prohibits plaintext secrets in Git
- [x] 3.3 Validate all referenced paths and URLs in `AGENTS.md` and remove stale/ambiguous wording

## 4. Validation and Handoff

- [x] 4.1 Render manifests with `kubectl kustomize cluster` to verify no manifest regressions from documentation changes
- [x] 4.2 Review rewritten `AGENTS.md` against spec requirements and close any missing requirement coverage
- [x] 4.3 Summarize final guidance scope and key conventions for reviewer handoff
