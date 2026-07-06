#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="headlamp"
CHART_REPO="https://kubernetes-sigs.github.io/headlamp"
CHART_NAME="headlamp/headlamp"
HEADLAMP_VERSION="${HEADLAMP_VERSION:-0.43.0}"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy Headlamp Kubernetes dashboard via Helm chart.
Exposes Headlamp via Cilium Gateway API.

Options:
  --host HOSTNAME     Gateway HTTPRoute hostname (default: headlamp.k8s.junjie.pro)
  --version VERSION   Headlamp Helm chart version (default: 0.43.0)
  --dry-run           Print helm diff without applying
  --help              Show this help
EOF
    exit "${1:-0}"
}

GATEWAY_HOST="headlamp.k8s.junjie.pro"
VERSION="${HEADLAMP_VERSION}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --host)    GATEWAY_HOST="$2"; shift 2 ;;
        --version) VERSION="$2";        shift 2 ;;
        --dry-run) DRY_RUN=true;        shift   ;;
        --help)    usage 0 ;;
        *)         echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster." >&2
    exit 1
fi

if ! command -v helm >/dev/null 2>&1; then
    echo "Error: helm not found. Install it first: https://helm.sh/docs/intro/install/" >&2
    exit 1
fi

echo "Deploying Headlamp dashboard (chart: ${VERSION})..."

echo "-> Creating namespace..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

if $DRY_RUN; then
    echo "DRY-RUN: helm upgrade --install headlamp ${CHART_NAME} \\"
    echo "  --namespace \"${NAMESPACE}\" \\"
    echo "  --version \"${VERSION}\" \\"
    echo "  -f \"${SCRIPT_DIR}/values.yaml\" \\"
    echo "  --wait \\"
    echo "  --timeout 5m"
    exit 0
fi

echo "-> Adding headlamp Helm repo..."
if ! helm repo list -o yaml 2>/dev/null | grep -q "${CHART_REPO}"; then
    helm repo add headlamp "${CHART_REPO}"
fi
helm repo update headlamp

echo "-> Installing headlamp (${VERSION})..."
helm upgrade --install headlamp "${CHART_NAME}" \
    --namespace "${NAMESPACE}" \
    --version "${VERSION}" \
    -f "${SCRIPT_DIR}/values.yaml" \
    --wait \
    --timeout 5m

GATEWAY_CLASS=$(kubectl get gatewayclass cilium -o name 2>/dev/null || true)

if [[ -n "${GATEWAY_CLASS}" ]]; then
    echo "-> Creating HTTPRoute..."
    export GATEWAY_HOST
    HTTPROUTE_YAML="$(mktemp)"
    cleanup() { rm -f "$HTTPROUTE_YAML"; }
    trap cleanup EXIT
    envsubst '$GATEWAY_HOST' < "${SCRIPT_DIR}/httproute.yaml" > "$HTTPROUTE_YAML"
    kubectl apply -f "$HTTPROUTE_YAML"
    rm -f "$HTTPROUTE_YAML"
fi

echo ""
echo "Headlamp deployed."
echo "  Chart:     ${CHART_NAME} ${VERSION}"
echo "  Namespace: ${NAMESPACE}"
echo "  Dashboard: http://${GATEWAY_HOST}"
if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    echo "  Dashboard: https://${GATEWAY_HOST}"
fi
echo "  Note:      Login requires a bearer token or OIDC. Create one with:"
echo "             kubectl create token headlamp -n ${NAMESPACE}"
