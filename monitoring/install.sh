#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="monitoring"
CHART_REPO="https://prometheus-community.github.io/helm-charts"
CHART_NAME="prometheus-community/kube-prometheus-stack"
KUBE_PROMETHEUS_STACK_VERSION="${KUBE_PROMETHEUS_STACK_VERSION:-87.10.1}"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy Prometheus + Grafana monitoring stack via kube-prometheus-stack Helm chart.
Exposes Grafana via Cilium Gateway API.

Options:
  --grafana-password PASS  Grafana admin password (generate with: uuidgen)
  --host HOSTNAME          Gateway HTTPRoute hostname (default: grafana.k8s.junjie.pro)
  --version VERSION        kube-prometheus-stack chart version (default: 87.10.1)
  --dry-run                Print helm diff without applying
  --help                   Show this help
EOF
    exit "${1:-0}"
}

GRAFANA_PASSWORD=""
GATEWAY_HOST="grafana.k8s.junjie.pro"
VERSION="${KUBE_PROMETHEUS_STACK_VERSION}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --grafana-password) GRAFANA_PASSWORD="$2"; shift 2 ;;
        --host)             GATEWAY_HOST="$2";          shift 2 ;;
        --version)          VERSION="$2";               shift 2 ;;
        --dry-run)          DRY_RUN=true;               shift ;;
        --help)             usage 0 ;;
        *)                  echo "Unknown option: $1" >&2; usage 1 ;;
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

echo "Deploying monitoring stack (chart: ${VERSION})..."

echo "-> Creating namespace..."
kubectl apply -f "${SCRIPT_DIR}/namespace.yaml"

if [[ -n "${GRAFANA_PASSWORD}" ]]; then
    echo "-> Creating/updating grafana admin secret..."
    kubectl create secret generic grafana-admin-password \
        --from-literal="admin-password=${GRAFANA_PASSWORD}" \
        -n "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    HELM_ARGS=(--set grafana.adminPassword="${GRAFANA_PASSWORD}")
else
    if kubectl get secret grafana-admin-password -n "${NAMESPACE}" >/dev/null 2>&1; then
        echo "  Using existing secret grafana-admin-password"
        GRAFANA_PASSWORD="$(kubectl get secret grafana-admin-password -n "${NAMESPACE}" -o jsonpath='{.data.admin-password}' | base64 -d)"
        HELM_ARGS=(--set grafana.adminPassword="${GRAFANA_PASSWORD}")
    else
        echo "Error: --grafana-password is required (generate with: uuidgen)." >&2
        echo "  Or create secret manually from ${SCRIPT_DIR}/secret.yaml.example" >&2
        exit 1
    fi
fi

if $DRY_RUN; then
    echo "DRY-RUN: helm upgrade --install kube-prometheus-stack ${CHART_NAME} \\"
    echo "  --namespace \"${NAMESPACE}\" \\"
    echo "  --version \"${VERSION}\" \\"
    echo "  -f \"${SCRIPT_DIR}/values.yaml\" \\"
    echo "  --set grafana.adminPassword=<password> \\"
    echo "  --wait \\"
    echo "  --timeout 5m"
    exit 0
fi

echo "-> Adding prometheus-community Helm repo..."
if ! helm repo list -o yaml 2>/dev/null | grep -q "${CHART_REPO}"; then
    helm repo add prometheus-community "${CHART_REPO}"
fi
helm repo update prometheus-community

echo "-> Installing kube-prometheus-stack (${VERSION})..."
helm upgrade --install kube-prometheus-stack "${CHART_NAME}" \
    --namespace "${NAMESPACE}" \
    --version "${VERSION}" \
    -f "${SCRIPT_DIR}/values.yaml" \
    "${HELM_ARGS[@]}" \
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
echo "Monitoring stack deployed."
echo "  Chart:     ${CHART_NAME} ${VERSION}"
echo "  Namespace: ${NAMESPACE}"
echo "  Grafana:   http://${GATEWAY_HOST}"
if kubectl get crd certificates.cert-manager.io >/dev/null 2>&1; then
    echo "  Grafana:   https://${GATEWAY_HOST}"
fi
echo "  Username:  admin"
echo "  Password:  ${GRAFANA_PASSWORD}"
echo "  Prometheus: kubectl port-forward -n ${NAMESPACE} svc/kube-prometheus-stack-prometheus 9090:9090"
