#!/usr/bin/env bash
# Port forwards all OpenChoreo services inside the Kind container to utilize kind.yaml port-mappings.

set -euo pipefail

CLUSTER_NAME="openchoreo"
KUBECTL="kubectl --context kind-${CLUSTER_NAME}"
CONTAINER_NAME="openchoreo-control-plane"

stop_forwards() {
    echo "Stopping active port forwards inside container..."
    docker exec "$CONTAINER_NAME" pkill -f "/tmp/forwarder.py" 2>/dev/null || true
    echo "Port forwards stopped."
}

# Check command line flags
if [ $# -gt 0 ] && [ "$1" = "--stop" ]; then
    stop_forwards
    exit 0
fi

# Stop any already running forwards first
stop_forwards

echo "Querying Kubernetes service IPs..."

# 1. Control Plane Gateway (HTTP: 8080)
CP_GATEWAY_IP=$($KUBECTL get svc -n openchoreo-control-plane -l gateway.networking.k8s.io/gateway-name=gateway-default -o jsonpath='{.items[0].spec.clusterIP}')

# 2. Control Plane Cluster Gateway (8443)
CP_GATEWAY_SECURE_IP=$($KUBECTL get svc -n openchoreo-control-plane cluster-gateway -o jsonpath='{.spec.clusterIP}')

# 3. Data Plane Gateway (HTTP: 19080)
DP_GATEWAY_IP=$($KUBECTL get svc -n openchoreo-data-plane -l gateway.networking.k8s.io/gateway-name=gateway-default -o jsonpath='{.items[0].spec.clusterIP}')

# 4. Workflow Plane Registry (10082)
REGISTRY_IP=$($KUBECTL get svc -n openchoreo-workflow-plane registry -o jsonpath='{.spec.clusterIP}')

# 5. Argo Workflows (10081)
ARGO_IP=$($KUBECTL get svc -n openchoreo-workflow-plane argo-server -o jsonpath='{.spec.clusterIP}')

# 6. Observability Plane Gateway (HTTP: 11080)
OP_GATEWAY_IP=$($KUBECTL get svc -n openchoreo-observability-plane -l gateway.networking.k8s.io/gateway-name=gateway-default -o jsonpath='{.items[0].spec.clusterIP}')

# 7. OpenSearch API (9200)
OPENSEARCH_IP=$($KUBECTL get svc -n openchoreo-observability-plane opensearch -o jsonpath='{.spec.clusterIP}')

echo "Writing port-forwarder daemon to node..."

docker exec "$CONTAINER_NAME" sh -c "cat <<'EOF' > /tmp/forwarder.py
import socket
import threading
import sys
import time

def forward(local_port, remote_ip, remote_port):
    server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    try:
        server.bind(('0.0.0.0', local_port))
    except Exception as e:
        print(f'Failed to bind {local_port}: {e}')
        return
    server.listen(100)
    print(f'Forwarding port {local_port} to {remote_ip}:{remote_port}')
    
    while True:
        try:
            local_conn, addr = server.accept()
        except Exception:
            break
        
        remote_conn = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        try:
            remote_conn.connect((remote_ip, remote_port))
        except Exception as e:
            print(f'Failed to connect to remote {remote_ip}:{remote_port}: {e}')
            local_conn.close()
            continue
            
        def pipe(src, dst):
            try:
                while True:
                    data = src.recv(4096)
                    if not data:
                        break
                    dst.sendall(data)
            except Exception:
                pass
            finally:
                src.close()
                dst.close()
                
        threading.Thread(target=pipe, args=(local_conn, remote_conn), daemon=True).start()
        threading.Thread(target=pipe, args=(remote_conn, local_conn), daemon=True).start()

for arg in sys.argv[1:]:
    lp, rip, rp = arg.split(':')
    threading.Thread(target=forward, args=(int(lp), rip, int(rp)), daemon=True).start()

while True:
    time.sleep(1)
EOF"

echo "Starting port-forwarder daemon inside container..."

docker exec -d "$CONTAINER_NAME" python3 /tmp/forwarder.py \
    "8080:${CP_GATEWAY_IP}:8080" \
    "8443:${CP_GATEWAY_SECURE_IP}:8443" \
    "19080:${DP_GATEWAY_IP}:19080" \
    "10081:${ARGO_IP}:10081" \
    "10082:${REGISTRY_IP}:10082" \
    "11080:${OP_GATEWAY_IP}:11080" \
    "9200:${OPENSEARCH_IP}:9200"

echo "--------------------------------------------------------"
echo "All port forwards established via Kind node."
echo "Console:                 http://openchoreo.localhost:8080"
echo "API:                     http://api.openchoreo.localhost:8080"
echo "Argo Workflows:          http://host.k3d.internal:10081"
echo "OpenSearch API:          http://host.k3d.internal:11082"
echo "--------------------------------------------------------"
echo "To stop them, run: ./bootstrap/port-forward.sh --stop"
