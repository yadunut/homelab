---
name: flux-deploy-loop
description: Commit and push this homelab's GitOps changes, trigger Flux reconciliation, verify the affected Kubernetes workloads become healthy, and iteratively diagnose, fix, commit, push, and redeploy failures. Use only when explicitly invoked or when the user explicitly requests the full commit-to-deployment loop; do not use for an ordinary commit-only request.
compatibility: Requires this homelab repository, jj, flux, kubectl, authenticated origin push access, a working cluster kubeconfig, and macOS launchctl/sudo for optional Yggdrasil recovery.
metadata:
  version: "1.0"
---

# Flux Deploy Loop

Commit the requested GitOps change, push it to `main`, force the relevant Flux
reconciliation, and do not stop at “manifests applied”: wait for the affected
workload to become healthy. If it fails, diagnose and make safe declarative
fixes in this repository, commit and push each fix, then repeat.

The skill invocation authorizes normal validation, task-scoped commits, moving
and pushing `main`, Flux reconciliation, read-only cluster diagnostics, the
Yggdrasil recovery below, and non-drastic repository fixes. Do not ask for
confirmation for those routine actions.

## Inputs

- **Commit message** (optional): use it if supplied; otherwise infer a short,
  lowercase, imperative message consistent with `AGENTS.md`.
- **Flux target** (optional): use it if supplied; otherwise infer it from the
  changed paths.
- **Corrective iteration limit** (optional): default to 5. The initial deploy is
  not a corrective iteration.

## Non-negotiable safety rules

1. Read and follow the repository `AGENTS.md` before acting.
2. This repository uses Jujutsu. Use `jj`, not Git, for commit workflow.
3. The push to `main` authorizes deployment. Establish cluster connectivity
   before pushing so the deployment can be observed.
4. Commit only files belonging to the current task. Preserve unrelated working
   copy changes. With `jj commit`, pass the task-owned paths explicitly when
   unrelated changes exist.
5. Before moving `main`, fetch `origin` and inspect unpublished commits. Never
   silently deploy unrelated local commits, rewrite published history, force
   push, discard changes, or resolve a divergence by guessing.
6. Never commit plaintext secrets or edit generated
   `cluster/flux-system/gotk-*` manifests.
7. Fix desired state in Git. Do not use `kubectl edit`, `apply`, `patch`,
   `delete`, `rollout restart`, or other imperative cluster mutations to make a
   deployment appear successful.
8. Do not create an empty commit for a transient or environmental failure.
9. Do not declare success based only on the Flux Kustomization being Ready.
   Verify the affected workload and relevant dependencies too.

## 1. Inspect and scope

From the repository root:

```bash
jj status
jj diff
jj bookmark list --all
jj git fetch --remote origin
jj log -r 'main@origin..@' --no-graph
```

Identify:

- task-owned changed paths;
- pre-existing or unrelated working-copy changes;
- every commit that moving `main` to the pending commit would push;
- affected Flux Kustomizations, namespaces, workload controllers, HelmReleases,
  and other health-bearing resources;
- task-specific validation and end-to-end checks.

If the outgoing commit chain contains changes not authorized by the current
request, stop before pushing and ask the user after showing the commits and
why they would be deployed. A safe rebase onto a newly advanced `main@origin`
is allowed only when it preserves the task changes and does not rewrite a
published commit; otherwise escalate.

### Infer Flux targets

Use these defaults:

| Changed path | Reconcile target |
| --- | --- |
| `cluster/apps/<app>/**` or `cluster/apps/<app>.yaml` | `<app>` |
| `cluster/infrastructure/**` or `cluster/infrastructure.yaml` | `infrastructure` |
| `cluster/flux-system/**`, `cluster/kustomization.yaml`, or app assembly | `flux-system`, then any affected child target |
| Non-cluster files only | `flux-system` to confirm source/root sync; there is no workload rollout |

Always reconcile `flux-system` first after pushing. Reconcile multiple child
targets in dependency order, with `infrastructure` before applications.

## 2. Establish cluster connectivity

Before pushing, run a bounded API check:

```bash
kubectl --request-timeout=10s get --raw=/readyz
```

### Yggdrasil recovery

If `kubectl` fails with a transport/connectivity error such as `no route to
host`, connection timeout, I/O timeout, or connection refused, restart the
local Yggdrasil LaunchDaemon using these two commands in separate calls so the
bootstrap is still attempted if bootout says the service is not loaded:

```bash
sudo launchctl bootout system /Library/LaunchDaemons/org.nixos.yggdrasil.plist
sudo launchctl bootstrap system /Library/LaunchDaemons/org.nixos.yggdrasil.plist
```

Then poll the API check for up to 60 seconds. Retry the Yggdrasil restart at
most twice per skill invocation.

Do **not** restart Yggdrasil for authentication failures, certificate/TLS
errors, RBAC denials, an incorrect kube context, or Kubernetes resource errors;
diagnose those separately. If `sudo` requires an interactive password that the
agent cannot provide, ask the user to run the two commands, include the exact
error, and resume once connectivity returns. If two restarts do not restore
connectivity, stop before pushing and provide the network evidence.

## 3. Validate before every commit

Run at least:

```bash
kubectl kustomize cluster >/tmp/homelab-rendered.yaml
jj diff
jj status
```

Also:

- run task-specific tests or rendering checks;
- verify reconciliation ordering still makes sense;
- check that generated `gotk-*` files were not edited;
- inspect the diff for plaintext credentials or secret values;
- apply the networking, DNS, storage, and identity constraints in `AGENTS.md`.

When useful, run `flux diff kustomization` against the inferred local path.
Exit code 1 means expected differences; an exit code greater than 1 is a
validation failure. Do not commit until local validation succeeds.

## 4. Commit and push

Choose a short lowercase imperative message. If unrelated changes are present,
commit explicit task paths:

```bash
jj commit -m "<message>" <task-owned-paths...>
```

If every working-copy change belongs to this task, omitting paths is allowed.
After `jj commit`, the new committed revision is `@-` and the new working copy
is `@`.

Record the full commit ID, ensure the move is a fast-forward from
`main@origin`, move `main`, and push it explicitly:

```bash
DEPLOY_REV=$(jj log -r @- --no-graph -T 'commit_id ++ "\n"')
jj bookmark set main -r @-
jj git push --remote origin --bookmark main
jj git fetch --remote origin
```

Confirm `main@origin` is the pushed revision or a descendant containing it.
This matters because Flux image automation may race and add a newer commit.
Never force push over an automation commit. If the remote diverged, preserve
both sides and escalate when a clearly safe rebase is not possible.

For every corrective fix, repeat validation and create a new focused commit;
do not amend a commit that has already been pushed.

## 5. Reconcile the exact pushed desired state

First refresh the root source and Kustomization:

```bash
flux reconcile kustomization flux-system \
  --namespace flux-system \
  --with-source \
  --timeout=5m
```

Then reconcile each affected child target:

```bash
flux reconcile kustomization <target> \
  --namespace flux-system \
  --timeout=10m
```

Check the source and target revisions:

```bash
kubectl -n flux-system get gitrepository flux-system \
  -o jsonpath='{.status.artifact.revision}{"\n"}'
kubectl -n flux-system get kustomization <target> \
  -o jsonpath='{.status.lastAppliedRevision}{"\n"}'
```

Require the reconciled revision to be the pushed commit or a newer remote
revision that contains it. A Ready condition for an older revision is not
success.

If API connectivity drops during reconciliation or health checks, apply the
Yggdrasil recovery and resume observation. Do not make or commit a manifest
change for a local connectivity outage.

## 6. Wait for actual deployment health

Inspect the rendered affected component and the commit diff to identify the
resources that must become healthy. Use a default bounded timeout of 10 minutes,
extending it only when the workload has a known legitimate reason.

At minimum:

- require the affected Flux Kustomization condition `Ready=True` at the expected
  revision;
- use `kubectl rollout status` for changed Deployments, StatefulSets, and
  DaemonSets;
- wait for changed HelmReleases and operators' custom resources to report their
  Ready condition;
- wait for relevant Jobs to complete and newly created PVCs to bind;
- inspect affected pods for readiness, crash loops, image pull failures,
  scheduling failures, and abnormal restart counts;
- run task-specific service, ingress, DNS, certificate, or application health
  checks when the change affects them.

Examples (adapt names and namespaces; do not blindly run `--all` across
unrelated namespaces):

```bash
kubectl rollout status deployment/<name> -n <namespace> --timeout=10m
kubectl rollout status statefulset/<name> -n <namespace> --timeout=10m
kubectl wait helmrelease/<name> -n <namespace> \
  --for=condition=Ready --timeout=10m
kubectl wait certificate/<name> -n <namespace> \
  --for=condition=Ready --timeout=10m
kubectl get pods -n <namespace> -o wide
```

For a ConfigMap or Secret reference change that does not trigger a rollout,
verify whether the application reloads it safely. If a restart is required,
encode a declarative rollout trigger in Git rather than running an imperative
restart.

Success means the intended revision is applied, affected controllers completed
their rollout, required dependencies are Ready, pods are healthy, and relevant
end-to-end behavior works.

## 7. Failure diagnosis and correction loop

On failure, collect evidence before editing:

```bash
flux get kustomizations -A
flux get helmreleases -A
flux logs --kind=Kustomization --name=<target> \
  --namespace=flux-system --since=15m
kubectl -n flux-system describe kustomization <target>
kubectl get pods -n <namespace> -o wide
kubectl get events -n <namespace> --sort-by=.lastTimestamp
kubectl describe <kind>/<name> -n <namespace>
kubectl logs <pod> -n <namespace> --all-containers --tail=200
kubectl logs <pod> -n <namespace> --all-containers --previous --tail=200
```

Use only the commands relevant to the failing resource. Also compare live
status with the rendered desired state and confirm Flux observed the intended
revision.

Classify the failure:

1. **Local connectivity:** recover Yggdrasil and resume; no commit.
2. **Transient external/cluster condition:** wait and retry reconciliation once
   if evidence indicates progress; no empty commit.
3. **Safe declarative defect:** fix it in the repository, rerun validation,
   commit only the fix, move/push `main`, reconcile, and repeat health checks.
4. **Unrelated pre-existing failure:** show why it is unrelated; do not mutate
   unrelated desired state merely to make the check green.
5. **Drastic, ambiguous, or destructive remedy:** stop and ask the user using
   the escalation format below.

Examples of normally safe fixes include schema/API mistakes, bad references,
missing Kustomization resources, namespace/name mismatches, invalid image tags,
incorrect health checks, and reconciliation ordering errors—provided the fix
preserves the intended architecture and data.

Continue until healthy or until the configured corrective iteration limit
(default 5) has been reached. Stop earlier if the same root cause survives two
reasonable fixes, there is no
evidence-backed repository fix, or the next action crosses an escalation
boundary. Never churn speculative commits.

## Escalation boundary

Ask before any action involving:

- data deletion, PVC recreation, storage-class migration, or database recovery;
- namespace/resource deletion, disabling Flux prune/safety controls, or an
  intentional broad outage;
- Cilium, CoreDNS, NAT64/Jool, Traefik exposure, cluster-wide networking, or
  NixOS/node changes outside this repository;
- secret rotation/schema changes, identity/OIDC policy changes, or weakening
  security controls;
- image downgrades, broad version-policy changes, or rollback of the requested
  feature;
- force pushing, rewriting published commits, discarding user changes, or
  deploying unrelated commits;
- imperative cluster changes beyond the explicitly authorized local Yggdrasil
  restart;
- exceeding the corrective iteration limit.

Before asking, provide:

1. pushed commit IDs and affected Flux targets;
2. the current Flux revision and Ready conditions;
3. concise exact failure evidence (events/log excerpts/status);
4. the root-cause assessment and what was already attempted;
5. viable options, risks, and the recommended next action.

## Final report

On success, report:

```text
Flux deploy loop complete.
  Initial commit:     <id> <message>
  Corrective commits: <count and ids, or 0>
  Remote revision:    <main@origin id>
  Flux targets:       <targets>
  Workloads checked:  <resources>
  Yggdrasil restarts: <count>
  Result:             healthy
```

Also mention preserved unrelated working-copy changes. If stopped, report the
same fields, mark the result as blocked, and include the escalation context and
specific user decision needed.
