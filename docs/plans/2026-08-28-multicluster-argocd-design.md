# Multi-Cluster OpenChoreo Demo on k3d + Argo CD — Design

Date: 2026-08-28
Status: approved

## Goal

Turn this repo into a self-contained demo of **OpenChoreo running across multiple
clusters**, driven entirely by Argo CD. The headline moment: promoting a component
from `staging` to `production` moves it **across a cluster boundary**, using the same
immutable `ComponentRelease` and only a new `ReleaseBinding`.

## Decisions

| Decision | Choice | Why |
|---|---|---|
| Runtime | k3d (was kind) | Upstream's multi-cluster reference is k3d; its loadbalancer removes the in-node port forwarder |
| Topology | 2 clusters: `cp` (also hosting data plane `dp-nonprod`), `dp-prod` | Keeps the cross-cluster promotion story at half the resource cost |
| Observability | Folded into `cp` | Data planes export to it cross-cluster, which is itself a multi-cluster demo |
| Workflow plane | On `cp` | Needed for build→PR→deploy loop and the shared registry |
| GitOps scope | Argo CD owns addons + planes + CRs | Only the two CA exchanges stay imperative |
| OpenChoreo version | 1.2.3 (was 1.1.6) | Latest available |
| All addon versions | Current releases, not the doc-pinned ones | Clean install; validated with `helm template` |
| Forked control-plane chart | **Deleted** | Proven unnecessary on k8s >= 1.32 (see below) |

## The forked chart: deleted, with evidence

`bootstrap/config/charts/openchoreo-control-plane` was a copy of the upstream 1.1.6
chart with two CEL escapes applied to its CRDs:

- `self.var` -> `self.__var__` (5 CRDs)
- `self.scope.namespace` -> `self.scope.__namespace__` (1 CRD)

`var` and `namespace` are CEL reserved words. Tested empirically:

| apiserver | upstream CRDs |
|---|---|
| k8s 1.31.2 (the old kind node) | REJECTED — `compilation failed: undefined field 'var'` |
| k8s 1.32.10 | accepted |
| k8s 1.33.6 | accepted |
| k3s 1.36.1 (target) | accepted — all 32/32 CRDs |

Kubernetes 1.32 relaxed reserved-word handling. The fork was a correct workaround for a
1.31 node and is obsolete on the target stack. The diff contained *nothing* but those
escapes, so it is deleted outright along with the byte-identical duplicate in
`bootstrap/config/crds/`. The k3s image is pinned at v1.36.1, so the floor cannot regress.

## Topology

Two clusters. The `cp` cluster runs the control, workflow and observability planes, Argo CD,
**and** a local data plane serving the non-production environments — the same shape as the
single-cluster quickstart. Production gets its own cluster.

| Cluster | kubeAPI | Ports | Contents |
|---|---|---|---|
| `openchoreo-cp` | 6550 | 8080/8443, 10081/10082, 11080-11086, 19080/19443 | control, workflow, observability planes; Argo CD; data plane `dp-nonprod` |
| `openchoreo-dp-prod` | 6551 | 29080/29443 | data plane `dp-prod` |

The local `dp-nonprod` agent reaches the cluster-gateway over its in-cluster service address.
The remote `dp-prod` agent dials `wss://cluster-gateway.openchoreo.localhost:8443/ws`,
resolved to `host.k3d.internal` by the CoreDNS rewrite and terminating on the CP
cluster-gateway TLSRoute. `dp-prod` mirrors `host.k3d.internal:10082` for registry pulls and
exports logs/metrics/traces to the CP observability plane in `multiClusterExporter` mode.

Environment -> data plane mapping:

    development -> ClusterDataPlane/dp-nonprod   (cp cluster)
    staging     -> ClusterDataPlane/dp-nonprod   (cp cluster)
    production  -> ClusterDataPlane/dp-prod      (dp-prod cluster)

So `staging -> production` promotion still moves the workload across a cluster boundary,
using the same immutable ComponentRelease and only a new ReleaseBinding.

## Repository layout

    bootstrap/
      setup.sh                      # clusters -> Argo CD -> register -> root app -> link
      link-planes.sh                # the two CA exchanges
      teardown.sh
      clusters/{cp,dp-prod}.yaml    # k3d configs, host-side, never synced
      coredns-custom.yaml
    argocd/
      root-application.yaml         # the ONLY kubectl apply
      project.yaml
      apps/{cp,dp-prod,platform}/*.yaml
    values/{cp,dp-prod}/*.yaml      # Helm values, referenced via $values
    platform-shared/                # cluster-scoped CRs (see below)
    namespaces/default/{platform,projects}     # namespaced CRs, upstream layout

Each file under `argocd/apps/` is one Argo CD Application: a multi-source Helm release
(chart from OCI, `valueFiles: [$values/values/<cluster>/<x>.yaml]` from this repo) with
`destination.name` selecting the cluster. Which chart, which version, which values, which
cluster — all readable in one file.

## Sync ordering

The current bug: sync-waves order resources *inside* one Application; they do not order
across separate Applications. The three existing apps therefore race. Fix: a root
app-of-apps whose children carry the waves, since child Applications are resources of the
root.

| Wave | Contents |
|---|---|
| -20 | addons: cert-manager, ESO, kgateway, OpenBao, Thunder, registry, opensearch-operator |
| -10 | planes: control/workflow/observability + data-plane `dp-nonprod` (cp), data-plane `dp-prod` (dp-prod) |
| 0 | `platform-shared/` — ClusterProjectType, ClusterComponentTypes, ClusterResourceTypes, ClusterTraits, ClusterWorkflows, ClusterWorkflowTemplates, ClusterDataPlanes |
| 10 | `namespaces/` — namespace.yaml only |
| 20 | `namespaces/default/platform/` — Environments, ComponentTypes, Traits, Workflows, DeploymentPipeline |
| 30 | `namespaces/default/projects/` — Projects, Components, Workloads, Releases, ReleaseBindings |

Waves 10-30 reproduce upstream's Flux `dependsOn` chain. `namespaces` must sync *only*
`default/namespace.yaml`; upstream does this with a `kustomization.yaml` that this fork
dropped, which is why recursing `namespaces/` currently races platform against projects.

## Bootstrap, and what stays imperative

Two CA exchanges cannot be pure GitOps, because the certificates do not exist until the
charts have run:

    setup.sh
      1. k3d cluster create x2            (installs k3d if absent)
      2. helm install argocd on cp + HTTPRoute argocd.openchoreo.localhost:8080
      3. register dp-prod as an Argo CD cluster secret
         (server URL rewritten to https://host.k3d.internal:6551)
      4. kubectl apply -f argocd/root-application.yaml
      5. link-planes.sh
           cp  cluster-gateway-ca secret -> configmap in both data-plane namespaces
           dp  cluster-agent-tls  secret -> secrets dp-{nonprod,prod}-agent-ca in cp

`ClusterDataPlane` uses `clusterAgent.clientCA.secretKeyRef` (verified present in the
CRD), so the manifests stay static in git and go valid once step 5 creates the secrets.
`bootstrap/install-argocd.sh` is absorbed into steps 2-4 and deleted.

## 1.2.3 upgrade impact

Verified against the CRD schemas. `Component`, `ComponentRelease`, `ReleaseBinding` and
`Workload` required fields are unchanged. The break is in `Project`:

- `Project.spec.type` is now **required**, referencing a `(Cluster)ProjectType`.
- Add `ClusterProjectType/default` to `platform-shared/`.
- Add `spec.type: {kind: ClusterProjectType, name: default}` to `doclet/project.yaml`.
- Add `ProjectReleaseBinding` per environment under the doclet project.

## Cleanup

- Delete `bootstrap/config/charts/` and `bootstrap/config/crds/` (see above).
- Delete `kind.yaml` and `bootstrap/port-forward.sh` — k3d's loadbalancer replaces the
  in-node python forwarder.
- Delete `bootstrap/install-argocd.sh` (absorbed into `setup.sh`).
- Delete `bootstrap/samples/all.yaml` from the install path. It creates
  `Environment/{development,staging,production}` which the GitOps tree *also* creates —
  two owners for the same objects, against `selfHeal: true`. Its cluster-scoped contents
  move into `platform-shared/`. This is what upstream's Flux guide means by "do not
  install the OpenChoreo default resources".
- Delete untracked `bootstrap/config/coredns-*.json`; fix `.gitignore`, which references
  `.yaml` paths that no longer exist.
- Rewrite `README.md` — it still documents Flux and a `flux/` directory that is not here.
