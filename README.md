# OpenChoreo on two clusters — a k3d + Argo CD demo

A self-contained demo of **OpenChoreo 1.2.3** running across **two Kubernetes clusters**,
with **Argo CD owning every addon, plane and custom resource** in the repository.

The headline moment: promoting a component from `staging` to `production` moves it
**across a cluster boundary**, using the same immutable `ComponentRelease` and only a new
`ReleaseBinding`. Nothing is rebuilt, nothing is re-pushed — the promotion is one more
declarative object in git.

Everything except one CA push and the Gateway API CRDs is declarative. See
[The two imperative steps](#the-two-imperative-steps-and-why) for exactly what is not, and why.

---

## Topology

Two k3d clusters:

| Cluster | kubeAPI | Contents | Environments |
|---|---|---|---|
| `openchoreo-cp` | 6550 | control, workflow and observability planes; Argo CD; data plane `dp-nonprod` | `development`, `staging` |
| `openchoreo-dp-prod` | 6551 | data plane `dp-prod` | `production` |

`dp-nonprod` is a separate OpenChoreo **plane** — its own `ClusterDataPlane`, its own agent,
its own gateway on its own ports — but it is *not* a separate Kubernetes cluster; it runs
inside `openchoreo-cp`. That is what keeps the demo at two clusters instead of three while
still preserving the cross-cluster promotion story, because `production` is the environment
that lives in the other cluster.

Environment to data-plane mapping (from `namespaces/default/platform/infra/environments/`):

```
development -> ClusterDataPlane/dp-nonprod   (openchoreo-cp cluster)
staging     -> ClusterDataPlane/dp-nonprod   (openchoreo-cp cluster)
production  -> ClusterDataPlane/dp-prod      (openchoreo-dp-prod cluster)
```

### Published ports

From `bootstrap/clusters/cp.yaml`:

| Host port | Maps to | Purpose |
|---|---|---|
| 8080 | 8080 | control-plane gateway: console, API, Thunder |
| 8443 | 8443 | control-plane HTTPS + cluster-gateway mTLS for the remote `dp-prod` agent |
| 10081 | 10081 | Argo Workflows UI |
| 10082 | 10082 | container registry |
| 11080 | 11080 | observer API (observability gateway HTTP) |
| 11081 | 5601 | OpenSearch Dashboards |
| 11082 | 9200 | OpenSearch API |
| 11084 | 9091 | Prometheus remote-write |
| 11085 | 11085 | kgateway TLS passthrough for OpenSearch |
| 11086 | 4317 | OTel collector |
| 19080 | 19080 | `dp-nonprod` workload ingress (HTTP) |
| 19443 | 19443 | `dp-nonprod` workload ingress (HTTPS) |

From `bootstrap/clusters/dp-prod.yaml`:

| Host port | Maps to | Purpose |
|---|---|---|
| 29080 | 29080 | `dp-prod` workload ingress (HTTP) |
| 29443 | 29443 | `dp-prod` workload ingress (HTTPS) |

Both clusters run `--disable=traefik`; kgateway is the only gateway. Both mirror
`host.k3d.internal:10082` so `dp-prod` can pull images from the registry that lives on the
`cp` cluster.

`bootstrap/coredns-custom.yaml` rewrites `*.openchoreo.localhost` and
`*.openchoreoapis.localhost` to `host.k3d.internal` inside both clusters, so pods reach
host-published ports — including across the cluster boundary. That is how the `dp-prod`
agent dials `wss://cluster-gateway.openchoreo.localhost:8443/ws` and lands on the control
plane in the other cluster.

---

## Prerequisites

| Tool | Notes |
|---|---|
| Docker | at least **10 GB RAM** allocated; the two clusters together run a lot of pods |
| k3d | **>= 5.9** (the cluster configs use `k3d.io/v1alpha5`) |
| kubectl | — |
| helm | — |

The k3s image is pinned to `rancher/k3s:v1.36.4-k3s1` in both cluster configs. The pin
matters: OpenChoreo's CRDs use CEL expressions that a Kubernetes 1.31 API server rejects.

### inotify limits

On Linux, and on macOS under Colima or Docker Desktop, raise the inotify limits in the
Docker VM before creating the clusters — this is the same step as upstream's multi-cluster
guide. Without it, controllers across two clusters exhaust the default instance limit and
crash in ways that look like unrelated failures:

```bash
docker run --rm --privileged alpine sysctl -w fs.inotify.max_user_instances=1024
docker run --rm --privileged alpine sysctl -w fs.inotify.max_user_watches=524288
```

---

## Quickstart

```bash
./bootstrap/setup.sh
```

That one script creates both clusters, patches CoreDNS, installs the Gateway API CRDs and
Argo CD, registers `dp-prod` as an Argo CD cluster, applies the `AppProject` and the root
app-of-apps, and finally runs `bootstrap/link-planes.sh`.

**Expect a cold run to take 20–40 minutes**, almost all of it image pulls. `link-planes.sh`
sits in a visible polling loop for a large part of that; it is waiting for Helm charts that
Argo CD is still installing, and it prints a dot every 10 seconds so a long wait is
distinguishable from a wedged script.

### Access

| What | URL |
|---|---|
| Console (Backstage) | http://openchoreo.localhost:8080 |
| API | http://api.openchoreo.localhost:8080 |
| Argo Workflows | http://localhost:10081 |
| Observer | http://observer.openchoreo.localhost:11080 |
| OpenSearch Dashboards | http://localhost:11081 |

Console sign-in uses the demo users seeded by Thunder, e.g. `admin@openchoreo.dev` /
`Admin@123` (see `argocd/charts/addons/thunder/values.yaml`).

Argo CD admin password:

```bash
kubectl --context k3d-openchoreo-cp -n argocd get secret argocd-initial-admin-secret \
  -o jsonpath='{.data.password}' | base64 -d
```

> **Note.** `setup.sh` prints `http://argocd.openchoreo.localhost:8080` for the Argo CD UI,
> but no manifest in this repository creates an `HTTPRoute` for it and the Helm install sets
> no ingress, so that hostname does not resolve to Argo CD yet. Reach the UI with a forward
> instead:
> ```bash
> kubectl --context k3d-openchoreo-cp -n argocd port-forward svc/argocd-server 8081:80
> ```
> then open http://localhost:8081.

### Teardown

```bash
./bootstrap/teardown.sh          # prompts; pass --yes to skip
```

---

## Repository layout

```
bootstrap/
  setup.sh                      # clusters -> DNS -> Gateway API CRDs -> Argo CD -> root app -> link
  link-planes.sh                # pushes the control plane mTLS CA to every plane (see below)
  teardown.sh                   # deletes both k3d clusters
  coredns-custom.yaml           # *.openchoreo(apis).localhost -> host.k3d.internal
  clusters/
    cp.yaml                     # k3d config for openchoreo-cp (kubeAPI 6550)
    dp-prod.yaml                # k3d config for openchoreo-dp-prod (kubeAPI 6551)

argocd/
  project.yaml                  # AppProject "openchoreo": both clusters, cluster-scoped resources
  root-application.yaml         # the ONLY manifest applied by hand
  apps/
    00-infrastructure-appset.yaml   # addons + planes, one ApplicationSet, RollingSync
    platform/
      00-platform-shared.yaml       # wave 0, a real Application (the CRD barrier)
      10-namespaces-appset.yaml     # wave 10, git generator over namespaces/*
      20-platform-appset.yaml       # wave 20, git generator over namespaces/*/platform
      30-projects-appset.yaml       # wave 30, git generator over namespaces/*/projects/*
  charts/
    addons/<name>/              # wrapper charts pinning upstream addon charts
    planes/<name>/              # wrapper charts pinning the OpenChoreo 1.2.3 plane charts

platform-shared/                # cluster-scoped OpenChoreo CRs, applied to the cp cluster
  cluster-dataplanes/           # dp-nonprod, dp-prod
  cluster-project-types/        # default
  cluster-component-types/      # service, webapp, worker, scheduled-task
  cluster-resource-types/       # nats, postgres, valkey
  cluster-traits/               # alert-rule
  cluster-workflows/            # buildpack / dockerfile builders
  cluster-workflow-templates/   # Argo Workflow templates for build and GitOps release

namespaces/
  default/
    namespace.yaml              # the Namespace itself (wave 10)
    platform/                   # Environments, DeploymentPipeline, ComponentTypes,
                                #   Traits, Workflows (wave 20)
    projects/doclet/            # Project, Components, Workloads, Releases,
                                #   ReleaseBindings, ProjectReleaseBindings (wave 30)

docs/plans/                     # design and implementation plan for this layout
```

---

## How the GitOps layering works

```
root app-of-apps  (the only manifest applied by hand)
  └── argocd/apps/  (recursed)
        ├── 00-infrastructure-appset   ApplicationSet, RollingSync
        │     step 1: addons  (13 apps)  cert-manager, ESO, kgateway(+crds),
        │                                OpenBao, Thunder, registry, opensearch-operator
        │     step 2: planes  (5 apps)   control, workflow, observability, dp-nonprod, dp-prod
        ├── platform/00-platform-shared  Application, wave 0
        ├── platform/10-namespaces-appset  git generator over namespaces/*
        ├── platform/20-platform-appset    git generator over namespaces/*/platform
        └── platform/30-projects-appset    git generator over namespaces/*/projects/*
```

`bootstrap/setup.sh` applies `argocd/project.yaml` and `argocd/root-application.yaml`, in
that order. The order is load-bearing: `project.yaml` sits outside the root Application's
`path: argocd/apps`, so the root app never manages the `AppProject`, yet the root app and
every child reference `project: openchoreo`. Applied the other way round, the root
Application is rejected with *"Application referencing project openchoreo which does not
exist"*.

Everything below that point is discovered by recursing `argocd/apps/`.

### An ApplicationSet has no health check

This is the single fact that shapes the rest of the design.

Argo CD has no health assessment for the `ApplicationSet` kind, so the parent app-of-apps
considers an ApplicationSet **Healthy the instant it exists**. A sync-wave annotation on an
ApplicationSet therefore orders only *its own creation* — never the readiness of the
Applications it generates. Two ApplicationSets in waves -20 and -10 would both be Healthy
within a second of each other, and their generated Applications would race.

### So RollingSync does the infrastructure ordering

`argocd/apps/00-infrastructure-appset.yaml` is one ApplicationSet containing both layers,
with a `RollingSync` strategy whose two steps select on the `openchoreo.dev/layer` label
stamped onto the generated Applications. RollingSync only orders steps *within a single*
ApplicationSet, which is exactly why addons and planes live in the same file rather than in
two.

RollingSync requires `applicationsetcontroller.enable.progressive.syncs=true`, which
`bootstrap/setup.sh` sets on the Argo CD Helm install. **Without that flag the `strategy`
block is silently ignored** and everything applies concurrently — no error, just a
different and worse ordering.

### `platform-shared` is the CRD barrier

`argocd/apps/platform/00-platform-shared.yaml` is a real **Application** at sync-wave 0, not
an ApplicationSet — so the root app *does* gate on its health. It applies only OpenChoreo
`Cluster*` custom resources (`ClusterDataPlane`, `ClusterComponentType`,
`ClusterResourceType`, `ClusterTrait`, `ClusterWorkflow`, `ClusterWorkflowTemplate`,
`ClusterProjectType`), which means it cannot go Healthy until the OpenChoreo CRDs exist.

That makes it a **CRD barrier**: waves 10, 20 and 30 cannot be created until the
control-plane chart has installed the OpenChoreo CRDs. This is what makes the downstream
ordering safe despite the ApplicationSets above having no health of their own.

During bring-up, expect `platform-shared` to sit red and retry with
`no matches for kind "ClusterDataPlane" in version "openchoreo.dev/v1alpha1"`. **That is
normal and self-correcting** — the retry budget (20 attempts, 15s backoff, 5m cap) is sized
for it. It is not a failure.

### Waves 20 and 30 race, and that is fine

Because waves 10/20/30 are ApplicationSets, once the barrier opens they are all created at
roughly the same moment, and the Applications they generate race each other. This is benign:
the Kubernetes API server does not validate cross-resource references, so `Project`,
`Component` and `ReleaseBinding` objects apply immediately even if the `Environment` and
`DeploymentPipeline` they name do not exist yet. OpenChoreo's controllers reconcile them
once those objects show up.

### The git generators derive path *and* namespace from the tree

Each platform ApplicationSet uses a git directory generator and derives **both** the source
path and the destination namespace from the folder structure. Onboarding a namespace or a
project is creating a directory — there is no Argo CD manifest to edit.

Current expansion:

| ApplicationSet | Directory | Generated Application | Destination namespace |
|---|---|---|---|
| `namespaces` (wave 10) | `namespaces/default` | `default-namespace` | `default` |
| `platform` (wave 20) | `namespaces/default/platform` | `default-platform` | `default` |
| `projects` (wave 30) | `namespaces/default/projects/doclet` | `default-doclet` | `default` |

The wave-10 generator sets `directory.include: namespace.yaml` and does not recurse, so it
creates *only* the Namespace; `platform/` and `projects/` belong to waves 20 and 30. Waves
20 and 30 recurse. All three target `in-cluster` — these are OpenChoreo control-plane CRs,
not data-plane workloads.

---

## Charts and version pinning

Every deployable is a **wrapper chart** under `argocd/charts/{addons,planes}/<name>/`
holding three files:

| File | Role |
|---|---|
| `Chart.yaml` | pins the upstream chart as a `dependencies` entry (name, version, repository) |
| `Chart.lock` | records a `sha256` digest of the resolved dependency |
| `values.yaml` | the overrides, nested under the dependency's name as Helm requires for subcharts |

Because the overrides live in the wrapper, each generated Application needs only a **single
git source** — no `$values` multi-source plumbing. Argo CD's repo-server runs
`helm dependency build`, which restores the upstream chart from the committed `Chart.lock`.

`argocd/charts/addons/cert-manager/values.yaml` illustrates the nesting rule:

```yaml
cert-manager:          # <- the dependency name from Chart.yaml
  crds:
    enabled: true
```

To upgrade something:

```bash
cd argocd/charts/addons/cert-manager
# edit the version in Chart.yaml
helm dependency update
git add Chart.yaml Chart.lock && git commit
```

The vendored `charts/*.tgz` files are gitignored (`argocd/charts/**/charts/`) because Argo
CD rebuilds them from the lock on every sync. And because the lock carries a digest, an
upstream that re-publishes a different artefact under the same version number surfaces as a
loud sync failure rather than silent drift.

Addon charts: cert-manager, external-secrets, kgateway-crds, kgateway, openbao, thunder,
registry, opensearch-operator. Plane charts: control-plane, workflow-plane,
observability-plane, data-plane-nonprod, data-plane-prod — all five pinned to OpenChoreo
1.2.3.

---

## The two imperative steps, and why

Almost everything is declarative. Two things cannot be, and the reasons are specific.

### 1. Gateway API CRDs

`bootstrap/setup.sh` applies them with `kubectl apply --server-side` from a raw GitHub
release URL, on both clusters. An Argo CD `Application` has no non-git source type that can
pull a plain manifest from an arbitrary HTTP address, so there is nowhere declarative to put
this. Server-side apply keeps the step re-runnable.

### 2. `bootstrap/link-planes.sh` — the one-way CA push

The control plane and the plane agents authenticate to each other with mTLS. The CA is
**minted by the control-plane Helm chart at install time**, so it does not exist until that
chart has actually run in a cluster. It can never be committed to git; the only thing that
can be declared statically is the *reference* to it, which is what
`platform-shared/cluster-dataplanes/*.yaml` does through `clusterAgent.clientCA.secretKeyRef`.

The script pushes that one CA outwards, and nothing comes back:

| Direction | What moves | Where it lands |
|---|---|---|
| control plane → every plane | secret `cluster-gateway-ca` (`openchoreo-control-plane`), all three keys | secret **and** configmap `cluster-gateway-ca` in each agent namespace, on both clusters |

Both objects are load-bearing. The secret (`clusterAgent.tls.caSecretName`) feeds the agent's
cert-manager CA `Issuer`, which needs `tls.key` to sign; the configmap
(`clusterAgent.tls.serverCAConfigMap`) is mounted at `/ca-certs` so the agent can verify the
gateway's server certificate. Dropping the configmap reintroduces the agent CrashLoop.

**It must run while the plane Applications are still unhealthy.** Each plane agent CrashLoops
until the `cluster-gateway-ca` configmap exists, and its client `Certificate` stays unissued
until the `cluster-gateway-ca` secret exists, so those Applications stay unhealthy until this
script has run. Waiting for the planes to go Healthy first would
deadlock: the script is the thing that makes them healthy. This is why `setup.sh` calls it
immediately after applying the root app rather than after any readiness gate, and why the
plane Applications carry a generous retry budget.

The script is **idempotent** — every write goes through `apply`, never a bare `create` — so
it is safe to re-run at any time. Its waits time out after 20 minutes per secret; on a slow
cold start, re-running it is the correct response.

### Trust model

Each plane's cluster-agent needs a client certificate the control plane will accept, and the
`openchoreo-*-plane` charts offer two ways to get one:

- **`clusterAgent.tls.generateCerts: true`** (upstream default) — the plane mints its own
  self-signed CA. The control plane has no idea it exists, so after install the plane's CA
  must be copied back into `openchoreo-control-plane` as a `<plane>-agent-ca` secret. That CA
  cannot be committed to git, so the trust setup can never be fully declarative.
- **`clusterAgent.tls.generateCerts: false`** (what this repo uses) — cert-manager issues the
  agent's certificate from the control plane's *own* `cluster-gateway-ca`. The control plane
  trusts that CA by definition, so there is no return leg and every plane CR can name
  `cluster-gateway-ca` as static YAML in git.

The catch: a cert-manager CA `Issuer` signs locally, so it needs the CA's **private key**.
`link-planes.sh` therefore copies the control plane's signing key into every plane namespace.
Any plane holding it can mint a certificate the control plane trusts — impersonating another
plane, or (since the same CA signs the gateway's server cert) the gateway itself. Upstream
defaults to `true` precisely to keep per-plane CA isolation. Trading that away for a
declarative bootstrap is fine for a laptop demo and wrong for a real deployment.

---

## The cross-cluster promotion walkthrough

This is the point of the demo. `development` and `staging` resolve to
`ClusterDataPlane/dp-nonprod` inside the `cp` cluster; `production` resolves to
`ClusterDataPlane/dp-prod`, which is a different Kubernetes cluster entirely. The
`DeploymentPipeline` named `standard` (`namespaces/default/platform/infra/deployment-pipelines/standard.yaml`)
defines the promotion paths `development -> staging -> production`.

Promoting means adding one `ReleaseBinding` that names the **same** `releaseName` and the
target `environment` — the `ComponentRelease` itself is immutable and untouched. For example,
`namespaces/default/projects/doclet/components/nats/release-bindings/nats-staging.yaml`
binds release `nats-20260223-1` to `staging`; a `nats-production.yaml` alongside it, pointing
at the same `releaseName`, is what carries that identical artefact into the other cluster.

Observe the split:

```bash
# dev + staging cells live in the cp cluster
kubectl --context k3d-openchoreo-cp      get ns | grep doclet

# production cells live in their own cluster
kubectl --context k3d-openchoreo-dp-prod get ns | grep doclet

# both planes and their agent connection status, from the control plane
kubectl --context k3d-openchoreo-cp get clusterdataplane
```

Workload ingress follows the same split: `dp-nonprod` publishes on
`nonprod.openchoreoapis.localhost:19080`, `dp-prod` on `prod.openchoreoapis.localhost:29080`.

---

## What you actually get on a cold run

Be clear about the finish line: a fresh `setup.sh` gives you **a working platform with two
components deployed**, not the full five-component Doclet application.

| Component | `component.yaml` | `workload.yaml` | `releases/` | Deployed after setup |
|---|---|---|---|---|
| `nats` | yes | yes | yes | development, staging |
| `postgres` | yes | yes | yes | development, staging |
| `collab-svc` | yes | yes | — | no |
| `document-svc` | yes | yes | — | no |
| `frontend` | yes | yes | — | no |

Only `nats` and `postgres` ship pre-built `ComponentRelease` objects, and only with bindings
for `development` and `staging`. The three application components have their `Component` and
`Workload` declared but no `releases/` directory, so they stay un-released until a build
workflow runs and produces one. Nothing is broken — the release simply does not exist yet.

---

## Troubleshooting

**`link-planes.sh` timed out.**
Re-run it. It is idempotent, and a timeout on a cold bootstrap usually means the chart
behind the secret was still pulling images.

```bash
./bootstrap/link-planes.sh
```

**"Argo CD isn't self-healing."**
Check the addons first. RollingSync strips the `automated` block from Applications parked in
a later step, so an addon stuck unhealthy in step 1 leaves the entire planes layer with
`selfHeal` effectively disabled. The symptom presents as nothing happening rather than as an
error:

```bash
kubectl --context k3d-openchoreo-cp -n argocd get applications -l openchoreo.dev/layer=addons
```

Fix the red addon and the planes layer resumes on its own.

**Partial teardown — removing the Applications but keeping the clusters.**
Delete the `default-namespace` Application with `--cascade=false`:

```bash
kubectl --context k3d-openchoreo-cp -n argocd delete application default-namespace --cascade=false
```

That Application adopts the pre-existing `default` Namespace, so a cascading delete tries to
delete `default` itself. Kubernetes forbids that, the request never completes, and the
Application hangs forever on a stuck finalizer.

**Full teardown.**

```bash
./bootstrap/teardown.sh
```

**General triage.** The Applications to look at, by name:

| Layer | Applications |
|---|---|
| addons | `cp-*` and `dp-prod-*` with label `openchoreo.dev/layer=addons` |
| planes | `cp-control-plane`, `cp-workflow-plane`, `cp-observability-plane`, `cp-data-plane-nonprod`, `dp-prod-data-plane` |
| platform | `platform-shared`, `default-namespace`, `default-platform`, `default-doclet` |

All of them live in the `argocd` namespace of the `k3d-openchoreo-cp` context.

---

## Before merging: the branch pin

Every Argo CD source in this repository currently points at the branch
`feat/multicluster-argocd`, not at `main`. There are **9 occurrences under `argocd/`** — 6
`targetRevision:` fields (the root Application, the infrastructure ApplicationSet template,
and the four platform manifests) and 3 `revision:` fields in the git generators of the
platform ApplicationSets. All nine must be flipped to `main` before or at merge, or a
merged `main` will still be syncing from the feature branch.

```bash
grep -rn "feat/multicluster-argocd" argocd/
```
