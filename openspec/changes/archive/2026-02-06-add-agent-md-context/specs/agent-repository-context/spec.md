## ADDED Requirements

### Requirement: Agent guidance SHALL be consolidated in AGENTS.md
The repository SHALL maintain a single authoritative agent guidance file at `/Users/yadunut/dev/src/git.yadunut.dev/yadunut/homelab/AGENTS.md`, and changes in this capability SHALL overwrite and expand that file instead of introducing a parallel `AGENT.md` file.

#### Scenario: Existing AGENTS.md is present
- **WHEN** an agent context change is implemented
- **THEN** the change updates `/Users/yadunut/dev/src/git.yadunut.dev/yadunut/homelab/AGENTS.md` and does not create a second top-level agent-guidance file with overlapping scope

### Requirement: Agent guidance SHALL document reconciliation scope and ordering
Agent guidance SHALL state that Flux reconciles from repository branch `main` and path `./cluster`, and SHALL state that app kustomizations depend on infrastructure reconciliation.

#### Scenario: Agent plans a manifest change
- **WHEN** an agent proposes changes in app or infrastructure manifests
- **THEN** the guidance provides enough context to preserve reconciliation scope/order assumptions (cluster root path and infrastructure-first dependency)

### Requirement: Agent guidance SHALL define cluster DNS and networking invariants
Agent guidance SHALL document that the cluster domain is `k8s.internal`, the cluster is IPv6-only for pod/service networking, and IPv4 egress for pods requires proxy configuration with explicit `NO_PROXY` internal-domain exclusions.

#### Scenario: Agent configures external egress for a workload
- **WHEN** a workload needs to reach IPv4-only upstream services
- **THEN** the guidance instructs using `HTTP_PROXY`/`HTTPS_PROXY` and a `NO_PROXY` that includes cluster-internal domains and ranges

### Requirement: Agent guidance SHALL define ingress and exposure patterns
Agent guidance SHALL document that Traefik runs on ingress-designated nodes with host networking, and SHALL document that some services use Traefik CRDs including TCP TLS passthrough (for example Kanidm via `IngressRouteTCP`).

#### Scenario: Agent adds or modifies service exposure
- **WHEN** an agent designs ingress for a new or existing service
- **THEN** the guidance directs the agent to use the repository's Traefik CRD patterns and preserve passthrough behavior where required

### Requirement: Agent guidance SHALL define DNS management conventions
Agent guidance SHALL document that public DNS records are managed through `DNSEndpoint` CRDs consumed by ExternalDNS, and SHALL document that service domains commonly require paired `AAAA` and `A` records.

#### Scenario: Agent introduces a new public hostname
- **WHEN** an agent adds DNS records for a new service endpoint
- **THEN** the guidance directs the agent to add/update `DNSEndpoint` resources in line with existing CRD-driven patterns

### Requirement: Agent guidance SHALL define storage selection rules
Agent guidance SHALL document that `longhorn` is the replicated default storage class and `longhorn-local-1r` is non-replicated strict-local storage intended for workloads that require node-local placement.

#### Scenario: Agent creates or edits persistent storage
- **WHEN** an agent adds or updates PVC or database storage configuration
- **THEN** the guidance provides criteria to choose between replicated `longhorn` and strict-local `longhorn-local-1r`

### Requirement: Agent guidance SHALL define secret and identity conventions
Agent guidance SHALL require secrets to be sourced via 1Password operator resources (`OnePasswordItem`) rather than plaintext secret values in Git, and SHALL document existing OIDC/group-based access patterns for protected admin surfaces.

#### Scenario: Agent configures credentials for an application
- **WHEN** an agent needs to reference secrets or auth settings
- **THEN** the guidance directs the agent to use existing 1Password-backed secret references and established OIDC conventions

### Requirement: Agent guidance SHALL identify generated manifests and canonical references
Agent guidance SHALL identify generated Flux bootstrap manifests as non-edit targets and SHALL reference canonical detail documents for proxy and storage operations.

#### Scenario: Agent modifies Flux bootstrap configuration
- **WHEN** an agent needs to change Flux runtime behavior
- **THEN** the guidance distinguishes generated `gotk-*` files from editable overlay files and points to canonical docs for operational details
