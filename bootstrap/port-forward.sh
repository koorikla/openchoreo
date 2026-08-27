#!/usr/bin/env bash
# Port forwards all OpenChoreo services to host ports

set -euo pipefail

CLUSTER_NAME="openchoreo"
KUBECTL="kubectl --context kind-${CLUSTER_NAME}"
PID_FILE="bootstrap/.port-forwards.pids"

# Function to stop running port forwards
stop_forwards() {
    if [ -f "$PID_FILE" ]; then
        echo "Stopping active port forwards..."
        while read -r pid; do
            if kill -0 "$pid" 2>/dev/null; then
                kill "$pid"
            fi
        done < "$PID_FILE"
        rm -f "$PID_FILE"
        echo "Port forwards stopped."
    else
        echo "No active port forwards found."
    fi
}

# Check command line flags
if [ $# -gt 0 ] && [ "$1" = "--stop" ]; then
    stop_forwards
    exit 0
fi

# Stop any already running forwards first
stop_forwards

echo "Starting OpenChoreo port forwards..."
echo "Log outputs are written to bootstrap/.port-forward-*.log"

forward() {
    local ns="$1"
    local svc="$2"
    local ports="$3"
    local logname="$4"
    
    echo "Forwarding $ns/$svc ($ports)..."
    $KUBECTL port-forward -n "$ns" "svc/$svc" $ports --address 0.0.0.0 > "bootstrap/.port-forward-$logname.log" 2>&1 &
    local pid=$!
    echo "$pid" >> "$PID_FILE"
}

# 1. Control Plane Gateway (HTTP: 8080, HTTPS: 8443)
# We find the service dynamically matching Gateway API naming conventions
CP_SVC=$($KUBECTL get svc -n openchoreo-control-plane -l gateway.networking.k8s.io/gateway-name=gateway-default -o jsonpath='{.items[0].metadata.name}')
forward "openchoreo-control-plane" "$CP_SVC" "8080:8080 8443:8443" "control-plane"

# 2. Data Plane Gateway (HTTP: 19080, HTTPS: 19443)
DP_SVC=$($KUBECTL get svc -n openchoreo-data-plane -l gateway.networking.k8s.io/gateway-name=gateway-default -o jsonpath='{.items[0].metadata.name}')
forward "openchoreo-data-plane" "$DP_SVC" "19080:19080 19443:19443" "data-plane"

# 3. Workflow Plane Registry (10082) and Argo Workflows (10081)
forward "openchoreo-workflow-plane" "registry" "10082:10082" "registry"
forward "openchoreo-workflow-plane" "argo-workflows-server" "10081:10081" "argo"

# 4. Observability Plane Gateway (11080)
OP_SVC=$($KUBECTL get svc -n openchoreo-observability-plane -l gateway.networking.k8s.io/gateway-name=gateway-default -o jsonpath='{.items[0].metadata.name}')
forward "openchoreo-observability-plane" "$OP_SVC" "11080:11080 11085:11085" "observability"

# 5. OpenSearch Dashboards (5601 mapped to host 11081)
forward "openchoreo-observability-plane" "opensearch-dashboards" "11081:5601" "opensearch-dashboards"

# 6. OpenSearch API (9200 mapped to host 11082)
forward "openchoreo-observability-plane" "opensearch" "11082:9200" "opensearch-api"

echo "--------------------------------------------------------"
echo "All port forwards started in background."
echo "Console:                 http://openchoreo.localhost:8080"
echo "API:                     http://api.openchoreo.localhost:8080"
echo "Argo Workflows:          http://host.k3d.internal:10081"
echo "OpenSearch Dashboard:    http://host.k3d.internal:11081"
echo "--------------------------------------------------------"
echo "To stop them, run: ./bootstrap/port-forward.sh --stop"
