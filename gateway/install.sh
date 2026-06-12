#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy the shared Cilium Gateway and TLS certificate for all applications.

Options:
  --hosts HOSTS   Comma-separated hostnames for TLS certificate
                  (default: llama.k8s.junjie.pro,grafana.k8s.junjie.pro)
  --help          Show this help
EOF
    exit "${1:-0}"
}

GATEWAY_HOSTS="llama.k8s.junjie.pro,grafana.k8s.junjie.pro"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --hosts) GATEWAY_HOSTS="$2"; shift 2 ;;
        --help)  usage 0 ;;
        *)       echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster." >&2
    exit 1
fi

echo "Deploying shared Gateway..."

echo "-> Creating Gateway..."
kubectl apply -f "${SCRIPT_DIR}/gateway.yaml"

if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    echo "-> Creating Certificate..."
    export GATEWAY_HOSTS
    GATEWAY_HOSTS=$(echo "$GATEWAY_HOSTS" | tr ',' '\n' | sed 's/^/    - /')
    CERTIFICATE_YAML="$(mktemp)"
    cleanup() { rm -f "$CERTIFICATE_YAML"; }
    trap cleanup EXIT
    envsubst '$GATEWAY_HOSTS' < "${SCRIPT_DIR}/certificate.yaml" > "$CERTIFICATE_YAML"
    kubectl apply -f "$CERTIFICATE_YAML"
    rm -f "$CERTIFICATE_YAML"
fi

echo ""
echo "Gateway deployed."
echo "  Gateway:   $(kubectl get gateway llama-server -n llama-server -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo '<pending>')"
