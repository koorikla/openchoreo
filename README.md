# OpenChoreo GitOps Repository

This repository is a self-contained GitOps repository for provisioning a local **OpenChoreo** developer platform on a **Kind** (Kubernetes in Docker) cluster, along with Flux CD configuration for resource synchronization.

---

## Architecture Overview

This local setup deploys OpenChoreo v1.1.6 across four planes:
*   **Control Plane:** The central API and Console (Backstage) orchestrating operations.
*   **Data Plane:** Workloads are deployed and managed here.
*   **Workflow Plane:** Executes CI/CD pipelines (Argo Workflows) and hosts a local Docker Registry.
*   **Observability Plane:** Aggregates logs (Fluent Bit + OpenSearch), traces (OTel + OpenSearch), and metrics (Prometheus).

All domain names like `*.localhost` resolve locally to `127.0.0.1`. Inside the cluster, CoreDNS rewrites them to the host gateway (`host.k3d.internal` / `host.kind.internal`) so that pods can reach services exposed via Docker port mappings.

---

## Getting Started

### 1. Prerequisites
Ensure you have the following installed on your host system:
*   **Docker** (Engine 26.0+ recommended)
*   **Kind** (v0.20.0+)
*   **kubectl** (v1.30+)
*   **Helm** (v3.12+)
*   **Python 3** (used during setup for CoreDNS config updates)

Ensure Docker has at least **8 GB RAM** and **4 CPUs** allocated to run all planes comfortably.

### 2. Provision Cluster and Install OpenChoreo
To create the Kind cluster, patch internal DNS, and install OpenChoreo planes automatically:
```bash
./bootstrap/setup.sh
```

### 3. Expose Services to Host Machine
Because local environments lack public load balancers, start the background port-forwarding daemon:
```bash
./bootstrap/port-forward.sh
```
This script runs `kubectl port-forward` in the background and writes logs to `bootstrap/.port-forward-*.log`.

To stop the port forwards at any time, run:
```bash
./bootstrap/port-forward.sh --stop
```

### 4. Access OpenChoreo
Once the port forwards are running, you can access the platform at:
*   **Console:** [http://openchoreo.localhost:8080](http://openchoreo.localhost:8080) (Log in with `admin@openchoreo.dev` / `Admin@123`)
*   **API:** [http://api.openchoreo.localhost:8080](http://api.openchoreo.localhost:8080)
*   **Argo Workflows Dashboard:** [http://host.k3d.internal:10081](http://host.k3d.internal:10081)
*   **OpenSearch Dashboard:** [http://host.k3d.internal:11081](http://host.k3d.internal:11081)

---

## GitOps Directory Layout

The repository is structured to separate platform-level resources from application resources using Flux CD:

```
├── bootstrap/             # Kind cluster bootstrap scripts & configuration values
│   ├── config/            # Helm values overrides for all OpenChoreo components
│   ├── samples/           # Getting-started templates and default resources
│   ├── setup.sh           # Main cluster build and installation script
│   └── port-forward.sh    # Port-forwarding daemon manager
├── flux/                  # Flux CD operator source repository and kustomization configs
├── namespaces/            # App namespaces and workloads definition
└── platform-shared/      # Bounded contexts, global components, roles, and traits
```

---

## Cleanup
To delete the Kind cluster and clear all Docker containers:
```bash
kind delete cluster --name openchoreo
```
