#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="llama-server"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy llama-server on GPU worker nodes.

Options:
  --api-key KEY       LLAMA_API_KEY secret value (generate with: uuidgen)
  --host HOSTNAME     Ingress hostname (default: llama.k8s.junjie.pro)
  --dry-run           Print resources without applying
  --help              Show this help
EOF
    exit "${1:-0}"
}

API_KEY=""
INGRESS_HOST="llama.k8s.junjie.pro"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --api-key) API_KEY="$2"; shift 2 ;;
        --host)    INGRESS_HOST="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
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
if ! kubectl get nodes -l nvidia.com/gpu=true --no-headers 2>/dev/null | grep -q .; then
    echo "Error: no GPU nodes found (label nvidia.com/gpu=true). Install GPU Operator first." >&2
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

# Ingress
echo "-> Detecting IngressClass..."
INGRESS_CLASS=$(kubectl get ingressclass -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)

if [[ -z "$INGRESS_CLASS" ]]; then
    echo "  Warning: no IngressClass found, skipping Ingress creation" >&2
else
    echo "  IngressClass: ${INGRESS_CLASS}, host: ${INGRESS_HOST}"
    export INGRESS_CLASS INGRESS_HOST
    INGRESS_YAML="$(mktemp)"
    # shellcheck disable=SC2064
    trap "rm -f \"$INGRESS_YAML\"" EXIT
    envsubst '$INGRESS_CLASS $INGRESS_HOST' < "${SCRIPT_DIR}/ingress.yaml" > "$INGRESS_YAML"
    kubectl apply -f "$INGRESS_YAML"
    rm -f "$INGRESS_YAML"
fi

# Wait for readiness
echo "-> Waiting for deployment to be ready..."
kubectl rollout status deployment/llama-server -n "${NAMESPACE}" --timeout=600s

echo ""
echo "llama-server deployed."
echo "  Namespace: ${NAMESPACE}"
echo "  Health:    kubectl exec -n ${NAMESPACE} deployment/llama-server -- curl -s http://localhost:8080/health"
if [[ -n "${INGRESS_CLASS:-}" ]]; then
    echo "  Ingress:   https://${INGRESS_HOST}"
fi
