#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy the shared Cilium Gateway and wildcard TLS certificate for all applications.

Options:
  --wildcard WILDCARD   Wildcard DNS name for TLS certificate
                        (default: *.k8s.junjie.pro)
  --help                Show this help
EOF
    exit "${1:-0}"
}

GATEWAY_WILDCARD="${GATEWAY_WILDCARD:-*.k8s.junjie.pro}"

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not found. Install it first: https://kubernetes.io/docs/tasks/tools/" >&2
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --wildcard) GATEWAY_WILDCARD="$2"; shift 2 ;;
        --help)     usage 0 ;;
        *)          echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster." >&2
    exit 1
fi

echo "Deploying shared Gateway..."

echo "-> Creating namespace..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

echo "-> Creating Gateway..."
kubectl apply -f "${SCRIPT_DIR}/gateway.yaml"

if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    echo "-> Creating Certificate..."
    export GATEWAY_WILDCARD
    CERTIFICATE_YAML="$(mktemp)"
    cleanup() { rm -f "$CERTIFICATE_YAML"; }
    trap cleanup EXIT
    envsubst '$GATEWAY_WILDCARD' < "${SCRIPT_DIR}/certificate.yaml" > "$CERTIFICATE_YAML"
    kubectl apply -f "$CERTIFICATE_YAML"
    rm -f "$CERTIFICATE_YAML"
fi

# Clean up old v1 resources (migrated from llama-server namespace)
if kubectl get gateway llama-server -n llama-server >/dev/null 2>&1; then
    echo "-> Removing legacy Gateway 'llama-server' in llama-server namespace..."
    kubectl delete gateway llama-server -n llama-server
fi
if kubectl get certificate llama-server-tls -n llama-server >/dev/null 2>&1; then
    echo "-> Removing legacy Certificate 'llama-server-tls' in llama-server namespace..."
    kubectl delete certificate llama-server-tls -n llama-server
fi

echo ""
echo "Gateway deployed."
echo "  Gateway:     $(kubectl get gateway gateway -n gateway -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo '<pending>')"
echo "  Certificate: ${GATEWAY_WILDCARD}"
