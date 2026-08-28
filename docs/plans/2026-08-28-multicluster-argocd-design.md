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
| k3s 1.36.4 (target) | accepted — all 32/32 CRDs |

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
      setup.sh                      # clusters -> machine-id -> DNS -> Gateway API CRDs
                                    #   -> Argo CD -> register dp-prod -> root app -> link
      link-planes.sh                # the CA exchanges (see below)
      teardown.sh
      clusters/{cp,dp-prod}.yaml    # k3d configs, host-side, never synced
      coredns-custom.yaml
    argocd/
      project.yaml                  # AppProject, applied BEFORE the root app
      root-application.yaml         # the ONLY manifest applied by hand
      apps/
        00-infrastructure-appset.yaml   # one ApplicationSet, RollingSync, 6 layers
        platform/
          00-platform-shared.yaml       # Application, wave 0 - the CRD barrier
          10-namespaces-appset.yaml     # git generator over namespaces/*
          20-platform-appset.yaml       # git generator over namespaces/*/platform
          30-projects-appset.yaml       # git generator over namespaces/*/projects/*
      charts/                       # wrapper charts: Chart.yaml + Chart.lock + values.yaml
        addons/       (7)
        planes/       (5)
        observability/(3)           # receivers, cp only
        telemetry/    (4)           # agents and cross-cluster exporters
      manifests/                    # plain YAML, not charts
        common/       ClusterSecretStore + ServiceAccount, both clusters
        cp/           platform ExternalSecrets
        dp-prod/      observability ExternalSecret
        cp-routes/    Argo CD HTTPRoute
    platform-shared/                # cluster-scoped CRs incl. all four plane registrations
    namespaces/default/{platform,projects}

**Superseded during implementation.** The design originally called for a top-level `values/`
tree referenced by multi-source Applications via `$values`, and per-cluster app directories
(`argocd/apps/{cp,dp-prod}/`) holding one Application per chart. Both were replaced:

- Values moved next to their version pins as wrapper charts, so each deployable is one
  directory with `Chart.yaml` (dependency pin), `Chart.lock` (sha256 digest) and
  `values.yaml` (overrides nested under the dependency name). Applications became
  single-source git paths.
- The 18 per-chart Applications collapsed into one ApplicationSet with a list generator,
  and the platform Applications became git directory generators over `namespaces/*`,
  `namespaces/*/platform` and `namespaces/*/projects/*` so the destination namespace is
  derived from the tree rather than hardcoded.

## Sync ordering

The original bug: sync-waves order resources *inside* one Application, not across separate
Applications, so the three original apps raced. That is fixed, but the mechanism changed
during implementation.

An **ApplicationSet has no Argo CD health check**, so the root app-of-apps marks it Healthy
the instant it exists. Sync-waves on an ApplicationSet therefore order only its own
creation, never the readiness of the Applications it generates. Ordering comes from two
places instead:

**1. RollingSync inside `00-infrastructure-appset`** gates six layers, matching on the
`openchoreo.dev/layer` label. It requires
`applicationsetcontroller.enable.progressive.syncs=true`, set by `bootstrap/setup.sh`;
without the flag the strategy is silently ignored.

| Layer | Count | Why it must follow the previous one |
|---|---|---|
| addons | 12 | cert-manager CRDs + webhook, ESO CRDs, kgateway CRDs, OpenBao |
| secrets | 4 | ExternalSecrets need ESO's CRDs and a running OpenBao |
| planes | 5 | Backstage needs `backstage-secrets`, Observer needs `observer-secret` |
| observability | 3 | receivers need the planes' namespaces and the observability gateway |
| telemetry | 6 | Fluent Bit must not create `container-logs-*` before `openSearchSetup`'s PostSync hook applies the index template |
| routes | 1 | the Argo CD HTTPRoute needs `gateway-default`, created in `planes` |

**2. `platform/00-platform-shared` is a real Application at wave 0**, so root genuinely
gates on it. Since it applies only OpenChoreo `Cluster*` custom resources, it acts as a
**CRD barrier**: waves 10/20/30 cannot be created until the control-plane chart has
installed the CRDs. Expect it to retry with `no matches for kind ClusterDataPlane` during
bring-up; that is normal and self-correcting.

Waves 20 and 30 race each other, which is benign — the API server does not validate
cross-resource references, so Projects and ReleaseBindings apply immediately and their
controllers reconcile once Environments and pipelines exist.

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
