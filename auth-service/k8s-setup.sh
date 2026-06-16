#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV=""
DB_PASS=""
PG_SUPERUSER_PASSWORD=""
DRY_RUN=false

usage() {
    cat <<'EOF'
Usage: k8s-setup.sh [OPTIONS]

Set up auth-service: namespace, DB credentials secret, PostgreSQL role
and database.

Options:
  --env ENV            Environment (required): dev, staging, prod
  --db-pass PASSWORD   Database role password (optional; if secret already
                       exists, its value is used and this flag is ignored;
                       required when creating a new secret; generate with: uuidgen)
  --pg-pass PASSWORD   PostgreSQL superuser password (optional; auto-detects
                       from postgres-credentials secret in postgres namespace)
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
        --env)      ENV="$2";                  shift 2 ;;
        --db-pass)  DB_PASS="$2";              shift 2 ;;
        --pg-pass)  PG_SUPERUSER_PASSWORD="$2"; shift 2 ;;
        --dry-run)  DRY_RUN=true;              shift   ;;
        --help)     usage 0 ;;
        *)          echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if [[ -z "$ENV" ]]; then
    echo "Error: --env is required (dev, staging, or prod)." >&2
    exit 1
fi
case "$ENV" in
    dev|staging|prod) ;;
    *) echo "Error: --env must be dev, staging, or prod" >&2; exit 1 ;;
esac

NAMESPACE="auth-${ENV}"
DB_NAME="auth_${ENV}"

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster." >&2
    exit 1
fi

apply() {
    if [[ "$DRY_RUN" == true ]]; then
        kubectl apply -f "$1" --dry-run=client -o yaml
    else
        kubectl apply -f "$1"
    fi
}

TMPDIR="$(mktemp -d)"
cleanup() { rm -rf "$TMPDIR"; }
trap cleanup EXIT

echo "Setting up auth-service (env=${ENV}, namespace=${NAMESPACE})..."

echo "-> Creating namespace..."
export NAMESPACE
NS_TMP="${TMPDIR}/namespace.yaml"
envsubst '$NAMESPACE' < "${SCRIPT_DIR}/namespace.yaml" > "$NS_TMP"
apply "$NS_TMP"

if [[ -z "$DB_PASS" ]]; then
    if DB_PASS=$(kubectl get secret auth-db-credentials -n "${NAMESPACE}" \
        -o go-template='{{.data.SPRING_DATASOURCE_PASSWORD|base64decode}}' 2>/dev/null); then
        echo "  Using password from existing auth-db-credentials secret"
    else
        echo "Error: --db-pass is required when secret does not already exist (generate with: uuidgen)." >&2
        exit 1
    fi
fi

echo "-> Creating Secret..."
kubectl create secret generic auth-db-credentials \
    --from-literal="SPRING_DATASOURCE_PASSWORD=${DB_PASS}" \
    -n "${NAMESPACE}" --dry-run=client -o yaml | apply -

if [[ "$DRY_RUN" == true ]]; then
    echo ""
    echo "Dry-run: skipping PostgreSQL role and database creation."
    exit 0
fi

echo "-> Creating PostgreSQL role and database ${DB_NAME}..."

if [[ -z "$PG_SUPERUSER_PASSWORD" ]]; then
    if ! PG_SUPERUSER_PASSWORD=$(kubectl get secret postgres-credentials -n postgres \
        -o go-template='{{.data.POSTGRES_PASSWORD|base64decode}}' 2>/dev/null); then
        echo "Error: --pg-pass not provided and postgres-credentials secret not found in postgres namespace." >&2
        exit 1
    fi
    echo "  Using superuser password from postgres-credentials" >&2
fi

kubectl exec -n postgres postgres-0 -i -- \
    env PGPASSWORD="${PG_SUPERUSER_PASSWORD}" \
    bash -s -- "${DB_NAME}" "${DB_PASS}" <<'SCRIPT'
set -euo pipefail

DB_NAME="${1:-}"
DB_PASS="${2:-}"

if [[ -z "${DB_NAME}" ]]; then
    echo "Error: database name argument is required" >&2
    exit 1
fi
if [[ -z "${DB_PASS}" ]]; then
    echo "Error: password argument is required" >&2
    exit 1
fi

if psql -U postgres -tc "SELECT 1 FROM pg_roles WHERE rolname='${DB_NAME}'" | grep -q 1; then
    echo "  Role ${DB_NAME} already exists"
else
    psql -U postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
    EXECUTE format('CREATE ROLE %I WITH LOGIN PASSWORD %L', '${DB_NAME}', '${DB_PASS}');
END
\$\$;
SQL
    echo "  Role ${DB_NAME} created"
fi

if psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='${DB_NAME}'" | grep -q 1; then
    echo "  Database ${DB_NAME} already exists"
else
    psql -U postgres -v ON_ERROR_STOP=1 <<SQL
CREATE DATABASE "${DB_NAME}" OWNER "${DB_NAME}";
GRANT ALL PRIVILEGES ON DATABASE "${DB_NAME}" TO "${DB_NAME}";
SQL
    echo "  Database ${DB_NAME} created"
fi
SCRIPT

echo ""
echo "Done."
echo "  Namespace: ${NAMESPACE}"
echo "  Database:  ${DB_NAME}"
