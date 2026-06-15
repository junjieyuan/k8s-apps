#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NAMESPACE="postgres"
POSTGRES_VERSION="${POSTGRES_VERSION:-18.4}"

usage() {
    cat <<'EOF'
Usage: install.sh [OPTIONS]

Deploy a PostgreSQL server with persistent storage.

Only the postgres superuser is initialized. Applications should create their
own databases and non-superuser roles via init containers or migration tools.

Options:
  --password PASS     postgres superuser password (generate with: uuidgen)
  --version VERSION   PostgreSQL image tag (default: 18.4)
  --dry-run           Print resources without applying
  --help              Show this help
EOF
    exit "${1:-0}"
}

DB_PASSWORD=""
DRY_RUN=false

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl not found. Install it first: https://kubernetes.io/docs/tasks/tools/" >&2
    exit 1
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --password) DB_PASSWORD="$2";     shift 2 ;;
        --version)  POSTGRES_VERSION="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true;         shift ;;
        --help)     usage 0 ;;
        *)          echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster. Check that kubectl is configured." >&2
    exit 1
fi

if [[ -z "$DB_PASSWORD" ]]; then
    if kubectl get secret postgres-credentials -n "${NAMESPACE}" >/dev/null 2>&1; then
        echo "Using existing secret postgres-credentials" >&2
    else
        echo "Error: --password is required (generate with: uuidgen)." >&2
        echo "  Or create secret manually from ${SCRIPT_DIR}/secret.yaml.example" >&2
        exit 1
    fi
fi

echo "Deploying PostgreSQL ${POSTGRES_VERSION}..."

apply() {
    if [[ "$DRY_RUN" == true ]]; then
        kubectl apply -f "$1" --dry-run=client -o yaml
    else
        kubectl apply -f "$1"
    fi
}

echo "-> Creating namespace..."
apply "${SCRIPT_DIR}/namespace.yaml"

if [[ -n "$DB_PASSWORD" ]]; then
    echo "-> Creating/updating Secret..."
    kubectl create secret generic postgres-credentials \
        --from-literal="POSTGRES_PASSWORD=${DB_PASSWORD}" \
        -n "${NAMESPACE}" --dry-run=client -o yaml | apply -
fi

echo "-> Applying StatefulSet..."
export POSTGRES_VERSION
STATEFULSET_YAML="$(mktemp)"
cleanup() { rm -f "$STATEFULSET_YAML"; }
trap cleanup EXIT
envsubst '$POSTGRES_VERSION' < "${SCRIPT_DIR}/statefulset.yaml" > "$STATEFULSET_YAML"
apply "$STATEFULSET_YAML"

echo "-> Applying Service..."
apply "${SCRIPT_DIR}/service.yaml"

if [[ "$DRY_RUN" == false ]]; then
    echo "-> Waiting for postgres to be ready..."
    kubectl rollout status statefulset/postgres -n "${NAMESPACE}" --timeout=600s
fi

echo ""
echo "PostgreSQL ${POSTGRES_VERSION} deployed."
echo "  Namespace: ${NAMESPACE}"
echo "  Service:   postgres.${NAMESPACE}:5432"
echo "  User:      postgres"
echo ""
echo "  Connect:   kubectl exec -n ${NAMESPACE} -it postgres-0 -- psql -U postgres"
echo ""
echo "  Application databases/roles should be created by the application layer."
