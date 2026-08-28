# Multi-Cluster OpenChoreo on k3d + Argo CD — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Rebuild this repo as a 2-cluster k3d OpenChoreo 1.2.3 demo where Argo CD owns every addon, plane and custom resource, and promoting `staging -> production` crosses a cluster boundary.

**Architecture:** A `cp` cluster running the control, workflow and observability planes, Argo CD, and a local data plane `dp-nonprod` serving development+staging; plus a `dp-prod` cluster running data plane `dp-prod` for production. Argo CD runs on `cp` and syncs to both via registered cluster secrets. A single root app-of-apps fans out to per-cluster Applications ordered by sync-wave. Only the CA exchanges remain imperative.

**Tech Stack:** k3d 5.9 / k3s v1.36.4, Argo CD (helm), OpenChoreo 1.2.3 helm charts (OCI), cert-manager, External Secrets Operator, kgateway, OpenBao, Thunder, Argo Workflows, OpenSearch/Prometheus.

**Design:** `docs/plans/2026-08-28-multicluster-argocd-design.md`

**Repo URL used in all Application manifests:** `https://github.com/koorikla/openchoreo.git`.
**Git revision during development.** Every Application's `targetRevision` must point at the
branch that actually contains these files. While developing on `feat/multicluster-argocd`,
write `targetRevision: feat/multicluster-argocd` in every Application manifest — otherwise
Argo CD syncs the old `main`, which has no `values/`, `argocd/apps/` or `platform-shared/`
additions, and every app fails. Task 26 flips them all to `main` as the last step before
merge. There is exactly one place this is easy to miss: the `ref: values` source in the
multi-source Applications carries its own `targetRevision` too.

---

## Version matrix (all latest as of 2026-08-28)

Every version below was resolved from the live registry, and each values file in this
repo was validated against its chart with `helm template` before this plan was written.

| Component | Source | Version |
|---|---|---|
| k3s (via k3d 5.9.0) | `rancher/k3s` | `v1.36.4-k3s1` |
| Gateway API CRDs | github kubernetes-sigs/gateway-api | `v1.6.1` |
| Argo CD | `https://argoproj.github.io/argo-helm` | chart `10.4.0` (app `v3.5.1`) |
| cert-manager | `quay.io/jetstack/charts` | `v1.21.1` |
| External Secrets Operator | `ghcr.io/external-secrets/charts` | `2.9.0` |
| kgateway / kgateway-crds | `cr.kgateway.dev/kgateway-dev/charts` | `2.4.3` |
| OpenBao | `ghcr.io/openbao/charts` | `0.29.3` |
| Thunder | `ghcr.io/asgardeo/helm-charts` | `0.36.0` |
| docker-registry | `https://twuni.github.io/docker-registry.helm` | `3.0.0` |
| opensearch-operator | `https://opensearch-project.github.io/opensearch-k8s-operator/` | `3.0.2` |
| OpenChoreo control/data/workflow/observability plane | `ghcr.io/openchoreo/helm-charts` | `1.2.3` |
| observability-logs-opensearch | `ghcr.io/openchoreo/helm-charts` | `0.5.4` |
| observability-tracing-opensearch | `ghcr.io/openchoreo/helm-charts` | `0.6.0` |
| observability-metrics-prometheus | `ghcr.io/openchoreo/helm-charts` | `0.7.0` |
| observability-events-otel-collector | `ghcr.io/openchoreo/helm-charts` | `0.1.2` |

**Where this deliberately runs ahead of OpenChoreo's docs.** The 1.2.3 install guide pins
Gateway API `v1.5.1`, kgateway `v2.3.1`, cert-manager `v1.19.4`, ESO `2.0.1`, OpenBao
`0.25.6` and Thunder `0.28.0`. This plan uses current releases instead. Pre-validated:
`helm template` succeeds for the Thunder, OpenBao and control-plane values against the new
charts, so there is no values-schema drift. The two with real runtime risk are **Gateway
API 1.6.1** and **kgateway 2.4.3**, since OpenChoreo's Gateway/HTTPRoute templates are only
tested against 1.5.1/2.3.1. If gateways fail to program during Task 24, pin those two back
to the doc versions first — it is a one-line change in each Application — and record it in
Task 25.

---

## Conventions

- Cluster contexts: `k3d-openchoreo-cp`, `k3d-openchoreo-dp-prod`.
- Argo CD cluster *names* (used in `destination.name`): `in-cluster` (the cp cluster) and `dp-prod`.
- Data plane `dp-nonprod` lives **inside** the cp cluster, in namespace `openchoreo-data-plane`. It is a separate OpenChoreo plane but not a separate Kubernetes cluster, so its Application targets `in-cluster`.
- Every YAML change is verified with `kubectl apply --dry-run=client -f <path>` before commit. Manifests whose CRDs are not installed locally use `--dry-run=client --validate=false`.
- Commit after every task. Never batch two tasks into one commit.

**One-time refinement over the design doc:** a `manifests/<cluster>/` tree is added for plain (non-Helm) cluster-local resources — the Argo CD HTTPRoute, ExternalSecrets, the ClusterSecretStore. The design doc listed only `values/`; this is the same idea for non-chart YAML.

---

## Phase 1 — Demolition

### Task 1: Delete the forked chart and duplicate CRDs

**Files:**
- Delete: `bootstrap/config/charts/` (entire tree)
- Delete: `bootstrap/config/crds/` (entire tree)

**Step 1:** Confirm nothing else references them.

```bash
grep -rn "config/charts\|config/crds" --include=*.sh --include=*.yaml --include=*.md . | grep -v docs/plans
```
Expected: only `bootstrap/setup.sh` (the `helm upgrade --install openchoreo-control-plane bootstrap/config/charts/...` line).

**Step 2:** Delete.

```bash
git rm -r -q bootstrap/config/charts bootstrap/config/crds
```

**Step 3:** Commit.

```bash
git commit -m "chore: drop forked control-plane chart and duplicate CRDs

The fork carried only two CEL escapes (self.var, self.scope.namespace)
needed on k8s <= 1.31. Verified upstream CRDs apply cleanly on 1.32+
and on the target k3s 1.36, so the fork is obsolete."
```

### Task 2: Delete kind, port-forward and install-argocd

**Files:**
- Delete: `kind.yaml`, `bootstrap/port-forward.sh`, `bootstrap/install-argocd.sh`
- Delete: untracked `bootstrap/config/coredns-original.json`, `bootstrap/config/coredns-patched.json`

**Step 1:**

```bash
git rm -q kind.yaml bootstrap/port-forward.sh
rm -f bootstrap/install-argocd.sh bootstrap/config/coredns-*.json bootstrap/.port-forward-*.log bootstrap/.port-forwards.pids
```
(`install-argocd.sh` is untracked, so plain `rm`.)

**Step 2:** Verify no references remain.

```bash
grep -rn "kind.yaml\|port-forward\|install-argocd" --include=*.sh --include=*.md . | grep -v docs/plans
```
Expected: matches only in `README.md` (rewritten in Task 20).

**Step 3:** Commit `chore: remove kind and port-forward tooling (replaced by k3d)`.

### Task 3: Fix .gitignore

**Files:** Modify `.gitignore`

Replace the stale `bootstrap/config/coredns-patched.yaml` / `coredns-original.yaml` lines with:

```
bootstrap/config/coredns-*.json
.argocd-admin-password
```

Keep the rest. Commit `chore: fix stale .gitignore paths`.

---

## Phase 2 — k3d cluster configs

### Task 4: Create the two k3d cluster configs

**Files:**
- Create: `bootstrap/clusters/cp.yaml`, `bootstrap/clusters/dp-prod.yaml`

`bootstrap/clusters/cp.yaml` — control, workflow and observability planes, Argo CD, **and** the
`dp-nonprod` data plane, so it also needs the 19xxx data-plane gateway ports:

```yaml
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: openchoreo-cp
image: rancher/k3s:v1.36.4-k3s1
servers: 1
agents: 0
kubeAPI:
  hostPort: "6550"
ports:
  # Control plane 8xxx: console, API, Thunder, Argo CD UI
  - port: 8080:8080
    nodeFilters: [loadbalancer]
  # Control plane HTTPS + cluster-gateway mTLS for the remote dp-prod agent
  - port: 8443:8443
    nodeFilters: [loadbalancer]
  # Workflow plane 10xxx
  - port: 10081:10081   # Argo Workflows UI
    nodeFilters: [loadbalancer]
  - port: 10082:10082   # container registry
    nodeFilters: [loadbalancer]
  # Observability plane 11xxx
  - port: 11080:11080   # observer API
    nodeFilters: [loadbalancer]
  - port: 11081:5601    # OpenSearch Dashboards
    nodeFilters: [loadbalancer]
  - port: 11082:9200    # OpenSearch API
    nodeFilters: [loadbalancer]
  - port: 11084:9091    # Prometheus remote-write
    nodeFilters: [loadbalancer]
  - port: 11085:11085   # kgateway TLS passthrough for OpenSearch
    nodeFilters: [loadbalancer]
  - port: 11086:4317    # OTel collector
    nodeFilters: [loadbalancer]
  # Local data plane dp-nonprod 19xxx: workload ingress
  - port: 19080:19080
    nodeFilters: [loadbalancer]
  - port: 19443:19443
    nodeFilters: [loadbalancer]
options:
  k3s:
    extraArgs:
      - arg: "--disable=traefik"
        nodeFilters: [server:*]
registries:
  config: |
    mirrors:
      "host.k3d.internal:10082":
        endpoint:
          - http://host.k3d.internal:10082
```

`bootstrap/clusters/dp-prod.yaml`:

```yaml
apiVersion: k3d.io/v1alpha5
kind: Simple
metadata:
  name: openchoreo-dp-prod
image: rancher/k3s:v1.36.4-k3s1
servers: 1
agents: 0
kubeAPI:
  hostPort: "6551"
ports:
  - port: 29080:29080
    nodeFilters: [loadbalancer]
  - port: 29443:29443
    nodeFilters: [loadbalancer]
options:
  k3s:
    extraArgs:
      # Required: Argo CD on the cp cluster reaches this API server as
      # https://host.k3d.internal:6551, so that name must be in the cert SANs.
      - arg: "--tls-san=host.k3d.internal"
        nodeFilters: [server:*]
      - arg: "--disable=traefik"
        nodeFilters: [server:*]
registries:
  config: |
    mirrors:
      "host.k3d.internal:10082":
        endpoint:
          - http://host.k3d.internal:10082
```

**Verify:** both files parse as YAML and field names match upstream
`install/k3d/multi-cluster/config-*.yaml`.

**Commit:** `feat: add k3d cluster configs for cp and dp-prod`

### Task 5: CoreDNS rewrite covering both domains

**Files:** Modify `bootstrap/config/coredns-custom.yaml` -> move to `bootstrap/coredns-custom.yaml`

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: coredns-custom
  namespace: kube-system
data:
  openchoreo.override: |
    rewrite stop {
      name regex (.+\.)?openchoreo\.localhost host.k3d.internal
      answer auto
    }
    rewrite stop {
      name regex (.+\.)?openchoreoapis\.localhost host.k3d.internal
      answer auto
    }
```

The second block is new — data-plane ingress hostnames use `openchoreoapis.localhost` and the old kind CoreDNS patch covered it, but the k3d `coredns-custom.yaml` in this repo did not.

**Verify:** `kubectl apply --dry-run=client -f bootstrap/coredns-custom.yaml`

**Commit:** `feat: add openchoreoapis.localhost to CoreDNS rewrite`

---

## Phase 3 — Helm values

### Task 6: Control-plane values

**Files:** Create `values/cp/control-plane.yaml` (from `bootstrap/config/values-cp.yaml` + upstream multi-cluster `values-cp.yaml`)

Key differences from today's single-cluster file: the `clusterGateway.tlsRoute` block must be enabled so remote data-plane agents can reach the cluster-gateway through the CP gateway on 8443, and the OIDC URLs go through the public hostname.

```yaml
openchoreoApi:
  http:
    hostnames: [api.openchoreo.localhost]
  config:
    server:
      publicUrl: "http://api.openchoreo.localhost:8080"

backstage:
  secretName: backstage-secrets
  baseUrl: "http://openchoreo.localhost:8080"
  http:
    hostnames: [openchoreo.localhost]

security:
  oidc:
    issuer: "http://thunder.openchoreo.localhost:8080"
    jwksUrl: "http://thunder-service.thunder.svc.cluster.local:8090/oauth2/jwks"
    authorizationUrl: "http://thunder.openchoreo.localhost:8080/oauth2/authorize"
    tokenUrl: "http://thunder-service.thunder.svc.cluster.local:8090/oauth2/token"

# Remote agents (dp-nonprod, dp-prod) connect through here.
clusterGateway:
  tlsRoute:
    enabled: true
    hosts:
      - host: cluster-gateway.openchoreo.localhost
        paths:
          - path: /
            pathType: Prefix
  tls:
    issuerRef:
      name: cluster-gateway-server-issuer
    dnsNames:
      - cluster-gateway.openchoreo-control-plane.svc
      - cluster-gateway.openchoreo-control-plane.svc.cluster.local
      - cluster-gateway.openchoreo.localhost

gateway:
  httpPort: 8080
  httpsPort: 8443
  tls:
    enabled: false

features:
  secretManagement:
    enabled: true
```

Note the jwks/token URLs deliberately stay on the in-cluster `thunder-service` address — commit `bd7ff8a` in this repo fixed back-channel OIDC that way, and that fix must survive.

**Verify:**

```bash
helm template cp oci://ghcr.io/openchoreo/helm-charts/openchoreo-control-plane \
  --version 1.2.3 -f values/cp/control-plane.yaml >/dev/null && echo OK
```
Expected: `OK`. Any "unknown field" error means the 1.2.3 schema moved and the key must be fixed.

**Commit:** `feat: add control-plane values for multi-cluster cp`

### Task 7: Workflow + observability values for cp

**Files:** Create `values/cp/workflow-plane.yaml`, `values/cp/observability-plane.yaml`, `values/cp/registry.yaml`

`workflow-plane.yaml` — the agent is in the same cluster, so it can use the in-cluster service URL:

```yaml
clusterAgent:
  serverUrl: "wss://cluster-gateway.openchoreo-control-plane.svc.cluster.local:8443/ws"
  planeID: default
argo-workflows:
  server:
    enabled: true
    serviceType: LoadBalancer
    servicePort: 10081
    authModes: [server]
```

`registry.yaml`:

```yaml
fullnameOverride: registry
persistence:
  enabled: true
service:
  type: LoadBalancer
  port: 10082
```

`observability-plane.yaml` — start from upstream `install/k3d/multi-cluster/values-op.yaml` verbatim, then set `clusterAgent.serverUrl` to the in-cluster service address (same reasoning as the workflow plane).

**Verify:** `helm template` each against its 1.2.3 chart as in Task 6.

**Commit:** `feat: add workflow, observability and registry values for cp`

### Task 8: Data-plane values for both data planes

**Files:** Create `values/cp/data-plane.yaml`, `values/dp-prod/data-plane.yaml`

`values/cp/data-plane.yaml` — the `dp-nonprod` plane, local to the cp cluster, so its agent
uses the in-cluster service address:

```yaml
clusterAgent:
  serverUrl: "wss://cluster-gateway.openchoreo-control-plane.svc.cluster.local:8443/ws"
  planeID: dp-nonprod
gateway:
  httpPort: 19080
  httpsPort: 19443
  tls:
    enabled: false
```

`values/dp-prod/data-plane.yaml` — remote, so it goes out through the CP gateway:

```yaml
clusterAgent:
  # Resolved to host.k3d.internal by the CoreDNS rewrite, terminating on the
  # cp cluster-gateway TLSRoute.
  serverUrl: "wss://cluster-gateway.openchoreo.localhost:8443/ws"
  planeID: dp-prod
gateway:
  httpPort: 29080
  httpsPort: 29443
  tls:
    enabled: false
```

`planeID` becomes the agent certificate's CN (`templates/cluster-agent/certificate.yaml` uses
`.Values.clusterAgent.planeID`), which is how the control plane distinguishes the two planes.

**Verify:**

```bash
helm template dp-nonprod oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
  --version 1.2.3 -f values/cp/data-plane.yaml >/dev/null && echo "dp-nonprod OK"
helm template dp-prod oci://ghcr.io/openchoreo/helm-charts/openchoreo-data-plane \
  --version 1.2.3 -f values/dp-prod/data-plane.yaml >/dev/null && echo "dp-prod OK"
```

**Commit:** `feat: add data-plane values for dp-nonprod and dp-prod`

### Task 9: OpenBao values, shared by both clusters

**Files:** Move `bootstrap/config/values-openbao.yaml` -> `values/common/openbao.yaml`; move `bootstrap/config/values-thunder.yaml` -> `values/cp/thunder.yaml`

The existing OpenBao values already seed every secret the platform needs via `server.postStart` and create both Kubernetes auth roles. Both clusters need a `ClusterSecretStore` named `default` (data planes because `ClusterDataPlane.spec.secretStoreRef.name: default`), so the same values file is reused by both OpenBao Applications.

**Verify:** `kubectl apply --dry-run=client -f values/common/openbao.yaml` is not meaningful (it is a values file); instead confirm it parses and that `helm template openbao oci://ghcr.io/openbao/charts/openbao --version 0.29.3 -f values/common/openbao.yaml >/dev/null`.

**Commit:** `refactor: move helm values into values/ tree`

---

## Phase 4 — Cluster-scoped resources

### Task 10: Move default cluster-scoped resources into platform-shared

**Files:**
- Create: `platform-shared/cluster-project-types/default.yaml`
- Create: `platform-shared/cluster-component-types/*.yaml` (4)
- Create: `platform-shared/cluster-resource-types/*.yaml` (3)
- Create: `platform-shared/cluster-traits/observability-alert-rule.yaml`
- Create: `platform-shared/cluster-workflows/*.yaml` (4)
- Delete: `bootstrap/samples/all.yaml`

Source these from upstream `openchoreo/openchoreo` `samples/getting-started/` at the 1.2.x revision (already fetched during design at `samples/getting-started/`), **excluding** the `Environment`, `DeploymentPipeline`, `Project` and `ProjectReleaseBinding` documents — those are namespaced and already live under `namespaces/default/`.

This removes the dual-ownership bug: `bootstrap/samples/all.yaml` created `Environment/development|staging|production`, and so does `namespaces/default/platform/infra/environments/`. With `selfHeal: true` the two fight.

**Verify:**

```bash
grep -rh "^kind:" platform-shared/ | sort | uniq -c
```
Expected: only `Cluster*` kinds — no `Environment`, `Project`, `DeploymentPipeline`.

**Commit:** `feat: move cluster-scoped defaults into platform-shared`

### Task 11: Add the two ClusterDataPlane registrations

**Files:** Create `platform-shared/cluster-dataplanes/dp-nonprod.yaml`, `platform-shared/cluster-dataplanes/dp-prod.yaml`

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ClusterDataPlane
metadata:
  name: dp-nonprod
spec:
  planeID: dp-nonprod
  clusterAgent:
    clientCA:
      # Populated by bootstrap/link-planes.sh once the agent has minted its CA.
      secretKeyRef:
        name: dp-nonprod-agent-ca
        namespace: openchoreo-control-plane
        key: ca.crt
  secretStoreRef:
    name: default
  gateway:
    ingress:
      external:
        http:
          host: nonprod.openchoreoapis.localhost
          listenerName: http
          port: 19080
        name: gateway-default
        namespace: openchoreo-data-plane
```

`dp-prod.yaml`: `name`/`planeID` `dp-prod`, secret `dp-prod-agent-ca`, host
`prod.openchoreoapis.localhost`, port `29080`.

Both are cluster-scoped resources on the **control plane**, regardless of which Kubernetes
cluster the data plane itself runs in — `dp-nonprod` happens to be local to `cp`, `dp-prod` is
remote, and the CR looks the same either way.

Using `secretKeyRef` (confirmed present in the CRD schema) rather than an inline `value` is what keeps these manifests static in git.

**Verify:** `kubectl apply --dry-run=client --validate=false -f platform-shared/cluster-dataplanes/`

**Commit:** `feat: register dp-nonprod and dp-prod as ClusterDataPlanes`

---

## Phase 5 — Namespaced resources

### Task 12: Restore the namespaces kustomization

**Files:** Create `namespaces/kustomization.yaml`

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
resources:
  - default/namespace.yaml
```

This is the file the fork dropped. Without it the `namespaces` Application recurses the whole tree and races `platform/` against `projects/`.

**Verify:** `kubectl kustomize namespaces/ | grep -c "^kind: Namespace"` -> `1`

**Commit:** `fix: restore namespaces kustomization so only namespaces sync`

### Task 13: Point environments at the two data planes

**Files:** Modify the three files in `namespaces/default/platform/infra/environments/`

- `development.yaml`, `staging.yaml`: `spec.dataPlaneRef` -> `{kind: ClusterDataPlane, name: dp-nonprod}`
- `production.yaml`: `spec.dataPlaneRef` -> `{kind: ClusterDataPlane, name: dp-prod}`

**Verify:**

```bash
grep -A2 dataPlaneRef namespaces/default/platform/infra/environments/*.yaml
```
Expected: `dp-nonprod` twice, `dp-prod` once.

**Commit:** `feat: map development/staging to dp-nonprod and production to dp-prod`

### Task 14: Bring the doclet project up to the 1.2.3 schema

**Files:**
- Modify: `namespaces/default/projects/doclet/project.yaml`
- Create: `namespaces/default/projects/doclet/project-release-bindings/doclet-{development,staging,production}.yaml`

`Project.spec.type` is required in 1.2.3. Add to `project.yaml`:

```yaml
spec:
  deploymentPipelineRef:
    name: standard
  type:
    kind: ClusterProjectType
    name: default
```

And one `ProjectReleaseBinding` per environment:

```yaml
apiVersion: openchoreo.dev/v1alpha1
kind: ProjectReleaseBinding
metadata:
  name: doclet-development
  namespace: default
  labels:
    openchoreo.dev/project: doclet
    openchoreo.dev/environment: development
spec:
  owner:
    projectName: doclet
  environment: development
```

Leave `spec.projectRelease` unset — the Project controller seeds it.

**Verify:** `kubectl apply --dry-run=client --validate=false -f namespaces/default/projects/doclet/ -R`

**Commit:** `feat: update doclet project for the 1.2.3 ProjectType schema`

---

## Phase 6 — Argo CD Applications

### Task 15: AppProject and root application

**Files:** Create `argocd/project.yaml`, rewrite `argocd/root-application.yaml`; delete `argocd/openchoreo-platform-application.yaml`, `argocd/platform-shared-application.yaml`

`argocd/project.yaml` — an `openchoreo` AppProject permitting both destinations and cluster-scoped resources:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: openchoreo
  namespace: argocd
spec:
  sourceRepos: ['*']
  destinations:
    - {server: '*', namespace: '*'}
  clusterResourceWhitelist:
    - {group: '*', kind: '*'}
  namespaceResourceWhitelist:
    - {group: '*', kind: '*'}
```

`argocd/root-application.yaml` — recurses `argocd/apps`:

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: root
  namespace: argocd
spec:
  project: openchoreo
  source:
    repoURL: https://github.com/koorikla/openchoreo.git
    targetRevision: feat/multicluster-argocd
    path: argocd/apps
    directory:
      recurse: true
  destination:
    server: https://kubernetes.default.svc
    namespace: argocd
  syncPolicy:
    automated: {prune: true, selfHeal: true}
```

**Verify:** `kubectl apply --dry-run=client -f argocd/project.yaml -f argocd/root-application.yaml`

**Commit:** `feat: add openchoreo AppProject and root app-of-apps`

### Task 16: Addon Applications (wave -20)

**Files:** Create under `argocd/apps/cp/`: `00-cert-manager.yaml`, `00-external-secrets.yaml`,
`01-kgateway-crds.yaml`, `02-kgateway.yaml`, `03-openbao.yaml`, `04-thunder.yaml`,
`05-registry.yaml`, `06-opensearch-operator.yaml`. Create cert-manager, ESO, kgateway(+crds)
and OpenBao equivalents under `argocd/apps/dp-prod/`.

Template (cert-manager on `dp-prod`):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dp-prod-cert-manager
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-20"
spec:
  project: openchoreo
  source:
    repoURL: quay.io/jetstack/charts
    chart: cert-manager
    targetRevision: v1.21.1
    helm:
      values: |
        crds:
          enabled: true
  destination:
    name: dp-prod
    namespace: cert-manager
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry:
      limit: 10
      backoff: {duration: 10s, factor: 2, maxDuration: 3m}
```

The cp copies are identical but for `destination.name: in-cluster` and the `cp-` name prefix.

Chart coordinates (all resolved live; see the version matrix):

| Addon | repoURL | chart | version | namespace | clusters |
|---|---|---|---|---|---|
| cert-manager | `quay.io/jetstack/charts` | `cert-manager` | `v1.21.1` | `cert-manager` | both |
| external-secrets | `ghcr.io/external-secrets/charts` | `external-secrets` | `2.9.0` | `external-secrets` | both |
| kgateway-crds | `cr.kgateway.dev/kgateway-dev/charts` | `kgateway-crds` | `2.4.3` | plane ns | both |
| kgateway | `cr.kgateway.dev/kgateway-dev/charts` | `kgateway` | `2.4.3` | plane ns | both |
| OpenBao | `ghcr.io/openbao/charts` | `openbao` | `0.29.3` | `openbao` | both |
| Thunder | `ghcr.io/asgardeo/helm-charts` | `thunder` | `0.36.0` | `thunder` | cp |
| docker-registry | `https://twuni.github.io/docker-registry.helm` | `docker-registry` | `3.0.0` | `openchoreo-workflow-plane` | cp |
| opensearch-operator | `https://opensearch-project.github.io/opensearch-k8s-operator/` | `opensearch-operator` | `3.0.2` | `openchoreo-observability-plane` | cp |

For charts taking a values file from this repo, use the multi-source form:

```yaml
  sources:
    - repoURL: https://github.com/koorikla/openchoreo.git
      targetRevision: feat/multicluster-argocd
      ref: values
    - repoURL: ghcr.io/openbao/charts
      chart: openbao
      targetRevision: 0.29.3
      helm:
        valueFiles: [$values/values/common/openbao.yaml]
```

Gateway API CRDs are a plain manifest release, not a chart, and Argo CD has no non-git source
for a raw URL — so **`setup.sh` applies Gateway API v1.6.1 directly** on both clusters before
the root app. Note this in the script and README as a third imperative step.

**Verify:** `kubectl apply --dry-run=client -f argocd/apps/ -R`

**Commit:** one commit per cluster directory: `feat: add addon applications for cp`, then
`feat: add addon applications for dp-prod`.

### Task 17: Plane Applications (wave -10)

**Files:** Create `argocd/apps/cp/{10-control-plane,11-workflow-plane,12-observability-plane,13-data-plane-nonprod,14-observability-modules}.yaml` and
`argocd/apps/dp-prod/{10-data-plane,11-observability-agents}.yaml`.

Template (the remote `dp-prod` data plane):

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: dp-prod-data-plane
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "-10"
spec:
  project: openchoreo
  sources:
    - repoURL: https://github.com/koorikla/openchoreo.git
      targetRevision: feat/multicluster-argocd
      ref: values
    - repoURL: ghcr.io/openchoreo/helm-charts
      chart: openchoreo-data-plane
      targetRevision: 1.2.3
      helm:
        valueFiles: [$values/values/dp-prod/data-plane.yaml]
  destination:
    name: dp-prod
    namespace: openchoreo-data-plane
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true, ServerSideApply=true]
    retry:
      limit: 20
      backoff: {duration: 15s, factor: 2, maxDuration: 5m}
```

`13-data-plane-nonprod.yaml` is the same chart with
`valueFiles: [$values/values/cp/data-plane.yaml]` and `destination.name: in-cluster`,
namespace `openchoreo-data-plane`.

The generous `retry` matters: each data-plane agent CrashLoops until `link-planes.sh` installs
the `cluster-gateway-ca` configmap, and the Application must keep retrying rather than settle
into a permanent Degraded state.

`14-observability-modules.yaml` on cp installs `observability-logs-opensearch` (0.5.4),
`observability-tracing-opensearch` (0.6.0) and `observability-metrics-prometheus` (0.7.0) in
receiver mode. `dp-prod/11-observability-agents.yaml` installs the same charts in
`multiClusterExporter` mode plus Fluent Bit, pointing at `host.k3d.internal:11085` / `:11080`
/ `:11084`. The local `dp-nonprod` plane needs no exporter — it shares the cluster with the
observability plane and can use in-cluster service addresses.

**Verify:** `kubectl apply --dry-run=client -f argocd/apps/ -R`

**Commit:** `feat: add plane applications for cp and dp-prod`

### Task 18: Platform Applications (waves 0-30)

**Files:** Create `argocd/apps/platform/{00-platform-shared,10-namespaces,20-platform,30-projects}.yaml`

All four target `in-cluster` / `default` namespace, differing only in path and wave:

| File | path | wave |
|---|---|---|
| `00-platform-shared.yaml` | `platform-shared` | `0` |
| `10-namespaces.yaml` | `namespaces` | `10` |
| `20-platform.yaml` | `namespaces/default/platform` | `20` |
| `30-projects.yaml` | `namespaces/default/projects` | `30` |

Each uses `directory: {recurse: true}` except `10-namespaces.yaml`, which relies on `namespaces/kustomization.yaml` (Task 12) and must **not** set `recurse`.

```yaml
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: platform-shared
  namespace: argocd
  annotations:
    argocd.argoproj.io/sync-wave: "0"
spec:
  project: openchoreo
  source:
    repoURL: https://github.com/koorikla/openchoreo.git
    targetRevision: feat/multicluster-argocd
    path: platform-shared
    directory: {recurse: true}
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated: {prune: true, selfHeal: true}
    syncOptions: [CreateNamespace=true]
    retry:
      limit: 20
      backoff: {duration: 15s, factor: 2, maxDuration: 5m}
```

**Verify:** `kubectl apply --dry-run=client -f argocd/apps/platform/ -R`

**Commit:** `feat: add wave-ordered platform applications`

### Task 19: Cluster-local plain manifests

**Files:** Create `manifests/cp/argocd-httproute.yaml`, `manifests/cp/backstage-externalsecret.yaml`, `manifests/cp/observability-externalsecrets.yaml`, `manifests/common/cluster-secret-store.yaml`; plus `argocd/apps/cp/07-manifests.yaml` and `argocd/apps/dp-prod/07-manifests.yaml` syncing `manifests/common/`.

`manifests/common/cluster-secret-store.yaml` is the ESO `ClusterSecretStore` named `default` (today created inline by `setup.sh`), pointing at `http://openbao.openbao.svc:8200`. It is needed on both clusters.

`manifests/cp/argocd-httproute.yaml` exposes Argo CD at `argocd.openchoreo.localhost:8080` through the control-plane gateway — the same HTTPRoute today's `install-argocd.sh` applies by hand.

These Applications carry wave `-15` (after addons, before planes) so ESO CRDs exist but the planes can already resolve their secrets.

**Verify:** `kubectl apply --dry-run=client --validate=false -f manifests/ -R`

**Commit:** `feat: add cluster-local manifests for secret store, secrets and argocd route`

---

## Phase 7 — Bootstrap scripts

### Task 20: setup.sh

**Files:** Create `bootstrap/setup.sh` (replacing the old one wholesale)

Structure, in order:

1. `require_tools` — `k3d kubectl helm docker`; if `k3d` is missing, fail with the
   `brew install k3d` hint.
2. `create_clusters` — `k3d cluster create --config` for `cp` and `dp-prod`, skipping any that
   already exist.
3. `patch_coredns` — apply `bootstrap/coredns-custom.yaml` to both, restart CoreDNS.
4. `install_gateway_api_crds` — `kubectl apply --server-side -f` the Gateway API v1.6.1
   `standard-install.yaml` on both (imperative; Argo CD has no non-git source for it).
5. `install_argocd` — helm install `argo/argo-cd` chart `10.4.0` into namespace `argocd` on cp
   with `server.extraArgs={--insecure}` (it sits behind the gateway).
6. `register_dp_prod` — build the Argo CD cluster Secret by hand from the dp-prod kubeconfig,
   **rewriting the server to `https://host.k3d.internal:6551`**.
7. `apply_root_app` — `kubectl apply -f argocd/project.yaml -f argocd/root-application.yaml`.
   ORDER IS LOAD-BEARING. `argocd/project.yaml` lives outside root's `path: argocd/apps`,
   so root does not manage it, yet root and all four platform children declare
   `project: openchoreo`. Apply the AppProject first or root fails with
   "Application referencing project openchoreo which does not exist" and nothing syncs.
   Moving `project.yaml` under `argocd/apps/` does NOT fix this — that is the
   chicken-and-egg it would create.
8. `link_planes` — call `bootstrap/link-planes.sh`.
9. `print_summary` — URLs and the Argo CD admin password.

Do **not** use `argocd cluster add` in step 6: it records the kubeconfig's `0.0.0.0` address,
which is unreachable from inside the cp cluster, and it would add a dependency on the argocd
CLI. Build the secret directly. Extract the credentials with `kubectl config view --raw
-o jsonpath=` rather than a YAML parser — PyYAML is not guaranteed to be installed (it was
absent on this machine during design):

```bash
register_dp_prod() {
    local ctx="k3d-openchoreo-dp-prod" name="dp-prod" port=6551
    local ca cert key
    ca=$(kubectl --context "$ctx" config view --raw --minify \
         -o jsonpath='{.clusters[0].cluster.certificate-authority-data}')
    cert=$(kubectl --context "$ctx" config view --raw --minify \
         -o jsonpath='{.users[0].user.client-certificate-data}')
    key=$(kubectl --context "$ctx" config view --raw --minify \
         -o jsonpath='{.users[0].user.client-key-data}')
    kubectl --context k3d-openchoreo-cp apply -f - <<EOF
apiVersion: v1
kind: Secret
metadata:
  name: cluster-$name
  namespace: argocd
  labels:
    argocd.argoproj.io/secret-type: cluster
stringData:
  name: $name
  server: https://host.k3d.internal:$port
  config: |
    {"tlsClientConfig":{"insecure":false,"caData":"$ca","certData":"$cert","keyData":"$key"}}
EOF
}
```

The `argocd` namespace must exist before step 6, so run it after step 5.

**Verify:** `bash -n bootstrap/setup.sh`, then `shellcheck bootstrap/setup.sh` if available.

**Commit:** `feat: rewrite setup.sh for two-cluster k3d bootstrap`

### Task 21: link-planes.sh

**Files:** Create `bootstrap/link-planes.sh`

Two exchanges. `dp-nonprod` lives in the cp cluster and `dp-prod` is remote, but the shape is
identical — only the context differs, so drive both from one table:

```bash
# context                      plane name
# k3d-openchoreo-cp            dp-nonprod
# k3d-openchoreo-dp-prod       dp-prod

# 1. cp cluster-gateway CA -> configmap in each data-plane namespace
wait_for_secret k3d-openchoreo-cp openchoreo-control-plane cluster-gateway-ca
ca=$(kubectl --context k3d-openchoreo-cp -n openchoreo-control-plane \
       get secret cluster-gateway-ca -o jsonpath='{.data.ca\.crt}' | base64 -d)
for entry in "k3d-openchoreo-cp:dp-nonprod" "k3d-openchoreo-dp-prod:dp-prod"; do
  ctx=${entry%%:*}
  kubectl --context "$ctx" create namespace openchoreo-data-plane \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
  kubectl --context "$ctx" -n openchoreo-data-plane \
    create configmap cluster-gateway-ca --from-literal=ca.crt="$ca" \
    --dry-run=client -o yaml | kubectl --context "$ctx" apply -f -
done

# 2. each data-plane agent CA -> secret in cp, referenced by ClusterDataPlane
for entry in "k3d-openchoreo-cp:dp-nonprod" "k3d-openchoreo-dp-prod:dp-prod"; do
  ctx=${entry%%:*}; plane=${entry##*:}
  wait_for_secret "$ctx" openchoreo-data-plane cluster-agent-tls
  agent_ca=$(kubectl --context "$ctx" -n openchoreo-data-plane \
               get secret cluster-agent-tls -o jsonpath='{.data.ca\.crt}' | base64 -d)
  kubectl --context k3d-openchoreo-cp -n openchoreo-control-plane \
    create secret generic "$plane-agent-ca" --from-literal=ca.crt="$agent_ca" \
    --dry-run=client -o yaml | kubectl --context k3d-openchoreo-cp apply -f -
done
```

`wait_for_secret` polls with a timeout and, on failure, names the Argo CD Application to go
look at. Every step is `apply`, never `create`, so the script is safe to re-run.

**Verify:** `bash -n bootstrap/link-planes.sh`

**Commit:** `feat: add link-planes.sh for the CA exchanges`

### Task 22: teardown.sh

**Files:** Create `bootstrap/teardown.sh`

```bash
k3d cluster delete openchoreo-cp openchoreo-dp-prod
```
with a confirmation prompt unless `--yes`.

If a partial teardown is ever wanted (removing Argo CD apps without deleting the
clusters), delete the `namespaces` Application with `--cascade=false`. It adopts the
pre-existing `default` Namespace, and a cascading delete would try to remove `default`,
which Kubernetes forbids — the deletion then hangs on a stuck finalizer.

**Commit:** `feat: add teardown.sh`

---

## Phase 8 — Docs

### Task 23: Rewrite README.md

**Files:** Modify `README.md`

Must cover: the two-cluster topology table, the port map, prerequisites (Docker with >= 10 GB RAM, k3d, kubectl, helm; note the inotify bump for Linux/Colima from upstream's guide), the two-command quickstart (`./bootstrap/setup.sh`, then the URLs), the repo layout, the sync-wave table, an explanation of the two imperative CA steps and *why* they are imperative, and the cross-cluster promotion walkthrough (`staging -> production` moves the workload from `dp-nonprod` to `dp-prod`).

Delete every reference to Flux, `flux/`, `kind`, and `port-forward.sh`.

**Verify:** `grep -in "flux\|kind\|port-forward" README.md` -> no matches.

**Commit:** `docs: rewrite README for the multi-cluster k3d Argo CD setup`

---

## Phase 9 — End-to-end validation

### Task 24: Full clean run

**Step 1:** `./bootstrap/teardown.sh --yes` then `./bootstrap/setup.sh`.

**Step 2:** Confirm both clusters and every Application:

```bash
k3d cluster list
kubectl --context k3d-openchoreo-cp -n argocd get applications
```
Expected: every Application `Synced` / `Healthy`.

**Step 3:** Confirm both agents connected:

```bash
kubectl --context k3d-openchoreo-cp get clusterdataplane
```
Expected: `dp-nonprod` and `dp-prod`, both showing a connected agent.

**Step 4:** Confirm the platform resources landed, and in order:

```bash
kubectl --context k3d-openchoreo-cp get environments,deploymentpipelines,componenttypes,projects
```
Expected: 3 environments, `standard` pipeline, 4 component types, `doclet` project.

**Step 5:** Confirm the cross-cluster split — the whole point of the demo:

```bash
# development and staging cells live in the cp cluster
kubectl --context k3d-openchoreo-cp      get ns | grep -i doclet
# the production cell lives in the other cluster
kubectl --context k3d-openchoreo-dp-prod get ns | grep -i doclet
```

**Step 6:** Open `http://openchoreo.localhost:8080` and `http://argocd.openchoreo.localhost:8080`;
confirm both load and the Argo CD tree shows two clusters.

**Step 7:** If gateways fail to program, the prime suspects are Gateway API `1.6.1` and
kgateway `2.4.3` running ahead of what OpenChoreo 1.2.3 is tested against. Pin them back to
`v1.5.1` / `v2.3.1`, re-sync, and record it in Task 25.

**Step 8:** Commit any fixes found, one commit per fix.

### Task 25: Record what actually happened

**Files:** Modify `docs/plans/2026-08-28-multicluster-argocd-design.md`

Append a "Deviations" section recording anything the run forced to change (chart versions that moved, values keys that were renamed in 1.2.3, waves that needed reordering). Commit.

### Task 26: Flip every targetRevision to main

**Files:** every `*.yaml` under `argocd/` containing `targetRevision: feat/multicluster-argocd`

Run only once Task 24 is green and the branch is ready to merge.

```bash
grep -rl "targetRevision: feat/multicluster-argocd" argocd/ \
  | xargs sed -i '' 's|targetRevision: feat/multicluster-argocd|targetRevision: main|'
grep -rn "targetRevision:" argocd/ | grep -v "targetRevision: main" | grep -vE "targetRevision: [0-9v]"
```
The second command must print nothing except chart version pins.

Push the branch, merge to `main`, then re-run `./bootstrap/setup.sh` once from `main` to
confirm the demo works from a clean clone of the default branch.

**Commit:** `chore: point argo applications at main`
