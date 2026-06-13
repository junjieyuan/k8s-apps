#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="llama-server"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy llama-server on GPU worker nodes. Exposes the server via Cilium Gateway API.

Options:
  --api-key KEY       LLAMA_API_KEY secret value (generate with: uuidgen)
  --host HOSTNAME     Gateway HTTPRoute hostname (default: llama.k8s.junjie.pro)
  --dry-run           Print resources without applying
  --help              Show this help
EOF
    exit "${1:-0}"
}

API_KEY=""
GATEWAY_HOST="llama.k8s.junjie.pro"
DRY_RUN=false

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not found. Install it first: https://kubernetes.io/docs/tasks/tools/" >&2
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key) API_KEY="$2";         shift 2 ;;
        --host)    GATEWAY_HOST="$2";    shift 2 ;;
        --dry-run) DRY_RUN=true;         shift ;;
        --help)    usage 0 ;;
        *)         echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

# Verify cluster access
if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster. Check that kubectl is configured." >&2
    exit 1
fi

# Verify GPU node exists
if ! kubectl get nodes -l feature.node.kubernetes.io/pci-10de.present=true --no-headers 2>/dev/null | grep -q .; then
    echo "Error: no GPU nodes found (label feature.node.kubernetes.io/pci-10de.present=true). Install GPU Operator first." >&2
    exit 1
fi

# Verify models.ini
if [[ ! -f "${SCRIPT_DIR}/models.ini" ]]; then
    echo "Error: models.ini not found at ${SCRIPT_DIR}/models.ini" >&2
    exit 1
fi

# Verify key
if [[ -z "$API_KEY" ]]; then
    if kubectl get secret llama-server-key -n "${NAMESPACE}" >/dev/null 2>&1; then
        echo "Using existing secret llama-server-key" >&2
    else
        echo "Error: --api-key is required (generate with: uuidgen)." >&2
        echo "  Or create secret manually from ${SCRIPT_DIR}/secret.yaml.example" >&2
        exit 1
    fi
fi

echo "Deploying llama-server..."

# Namespace
echo "-> Creating namespace..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

# ConfigMap from models.ini
echo "-> Creating/updating ConfigMap from models.ini..."
kubectl create configmap models-config --from-file="${SCRIPT_DIR}/models.ini" \
    -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

# Secret
if [[ -n "$API_KEY" ]]; then
    echo "-> Creating/updating Secret..."
    kubectl create secret generic llama-server-key --from-literal="LLAMA_API_KEY=${API_KEY}" \
        -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -
fi

# PV + PVC
echo "-> Applying PersistentVolume + PersistentVolumeClaim..."
kubectl apply -f "${SCRIPT_DIR}/persistentvolume.yaml"
kubectl apply -f "${SCRIPT_DIR}/persistentvolumeclaim.yaml"

# Deployment
echo "-> Deploying llama-server..."
kubectl apply -f "${SCRIPT_DIR}/deployment.yaml"

# Service
echo "-> Creating Service..."
kubectl apply -f "${SCRIPT_DIR}/service.yaml"

# ServiceMonitor (for Prometheus)
if kubectl get crd servicemonitors.monitoring.coreos.com >/dev/null 2>&1; then
    echo "-> Creating ServiceMonitor..."
    kubectl apply -f "${SCRIPT_DIR}/servicemonitor.yaml"
fi

# HTTPRoute (via shared Gateway)
echo "-> Checking Gateway..."
if ! kubectl get gateway gateway -n gateway >/dev/null 2>&1; then
    echo "  Warning: Gateway 'gateway' not found in namespace 'gateway'. Run ../gateway/install.sh first." >&2
else
    echo "  Gateway: $(kubectl get gateway gateway -n gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo '<pending>')"

    echo "-> Creating HTTPRoute..."
    export GATEWAY_HOST
    HTTPROUTE_YAML="$(mktemp)"
    cleanup() { rm -f "$HTTPROUTE_YAML"; }
    trap cleanup EXIT
    envsubst '$GATEWAY_HOST' < "${SCRIPT_DIR}/httproute.yaml" > "$HTTPROUTE_YAML"
    kubectl apply -f "$HTTPROUTE_YAML"
    rm -f "$HTTPROUTE_YAML"
fi

# Wait for readiness
echo "-> Waiting for deployment to be ready..."
kubectl rollout status deployment/llama-server -n "${NAMESPACE}" --timeout=600s

echo ""
echo "llama-server deployed."
echo "  Namespace: ${NAMESPACE}"
echo "  Health:    kubectl exec -n ${NAMESPACE} deployment/llama-server -- curl -s http://localhost:8080/health"
echo "  Gateway:   https://${GATEWAY_HOST}"
echo "  Gateway:   http://${GATEWAY_HOST}"
