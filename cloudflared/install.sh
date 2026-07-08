#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

NAMESPACE="cloudflared"
CLOUDFLARED_VERSION="${CLOUDFLARED_VERSION:-2026.6.1}"
DRY_RUN=false

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy cloudflared tunnel client to Kubernetes.

The TUNNEL_TOKEN secret must be created before running this script:
  cp secret.yaml.example secret.yaml
  # Edit secret.yaml with your real tunnel token
  kubectl apply -f secret.yaml

Options:
  --version VERSION    Container image tag (default: 2026.6.1)
  --dry-run            Print resources without applying
  --help               Show this help
EOF
    exit "${1:-0}"
}

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not found. Install it first: https://kubernetes.io/docs/tasks/tools/" >&2
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version)  CLOUDFLARED_VERSION="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true;              shift   ;;
        --help)     usage 0 ;;
        *)          echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

export NAMESPACE CLOUDFLARED_VERSION

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster." >&2
    exit 1
fi

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

apply() {
    if [[ "$DRY_RUN" == true ]]; then
        kubectl apply -f "$1" --dry-run=client -o yaml
    else
        kubectl apply -f "$1"
    fi
}

subst_apply() {
    local tmp="${TMPDIR}/$(basename "$1")"
    envsubst '$NAMESPACE $CLOUDFLARED_VERSION' < "$1" > "$tmp"
    apply "$tmp"
}

echo "Deploying cloudflared (version=${CLOUDFLARED_VERSION})..."

echo "-> Applying Namespace..."
subst_apply "${SCRIPT_DIR}/namespace.yaml"

echo "-> Checking prerequisites..."
if ! kubectl get secret cf-tunnel-token -n "${NAMESPACE}" -o jsonpath='{.data.TUNNEL_TOKEN}' >/dev/null 2>&1; then
    echo "  Error: secret 'cf-tunnel-token' not found or missing TUNNEL_TOKEN key in namespace '${NAMESPACE}'." >&2
    echo "  Create it first:" >&2
    echo "    cp ${SCRIPT_DIR}/secret.yaml.example ${SCRIPT_DIR}/secret.yaml" >&2
    echo "    # Edit secret.yaml with your real tunnel token" >&2
    echo "    kubectl apply -f ${SCRIPT_DIR}/secret.yaml" >&2
    exit 1
fi
echo "  Secret cf-tunnel-token: found"

echo "-> Applying Deployment..."
subst_apply "${SCRIPT_DIR}/deployment.yaml"

if [[ "$DRY_RUN" == false ]]; then
    echo "-> Waiting for deployment to be ready..."
    kubectl rollout status deployment/cloudflared -n "${NAMESPACE}" --timeout=120s

    echo "-> Checking logs..."
    kubectl logs -n "${NAMESPACE}" deployment/cloudflared --tail=20
fi

echo ""
echo "cloudflared deployed."
echo "  Namespace:  ${NAMESPACE}"
echo "  Check logs: kubectl logs -n ${NAMESPACE} deployment/cloudflared -f"
