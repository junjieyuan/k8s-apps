#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster." >&2
    exit 1
fi

echo "Deploying shared Gateway..."

echo "-> Creating Gateway..."
kubectl apply -f "${SCRIPT_DIR}/gateway.yaml"

if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    echo "-> Creating Certificate..."
    kubectl apply -f "${SCRIPT_DIR}/certificate.yaml"
fi

echo ""
echo "Gateway deployed."
echo "  Gateway:   $(kubectl get gateway llama-server -n llama-server -o jsonpath='{.status.addresses[0].value}' 2>/dev/null || echo '<pending>')"
