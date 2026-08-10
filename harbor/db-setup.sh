#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

DB_PASS=""
PG_SUPERUSER_PASSWORD=""
DRY_RUN=false

usage() {
    cat <<'EOF'
Usage: db-setup.sh [OPTIONS]

Create the Harbor PostgreSQL role and database on the shared postgres instance
(postgres/). Run this BEFORE deploying Harbor (kubectl kustomize --enable-helm
harbor/ | kubectl apply -f -).

The role password is auto-detected from harbor/values-secret.yaml
(database.external.password); override with --db-pass if needed.

Options:
  --db-pass PASSWORD   Harbor DB role password (auto-detected from
                       values-secret.yaml by default)
  --pg-pass PASSWORD   PostgreSQL superuser password (auto-detects from the
                       postgres-credentials Secret in the postgres namespace)
  --dry-run            Print SQL without executing
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
        --db-pass)  DB_PASS="$2";                  shift 2 ;;
        --pg-pass)  PG_SUPERUSER_PASSWORD="$2";    shift 2 ;;
        --dry-run)  DRY_RUN=true;                  shift   ;;
        --help)     usage 0 ;;
        *)          echo "Unknown option: $1" >&2; usage 1 ;;
    esac
done

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo "Error: cannot access Kubernetes cluster." >&2
    exit 1
fi

# Resolve Harbor DB password from values-secret.yaml when not provided.
if [[ -z "$DB_PASS" ]]; then
    if [[ -f "${SCRIPT_DIR}/values-secret.yaml" ]]; then
        DB_PASS="$(awk '
            /^[[:space:]]*password:/ {
                line = $0
                sub(/^[[:space:]]*password:[[:space:]]*/, "", line)
                gsub(/["'"'"']/, "", line)
                gsub(/[[:space:]]*#.*$/, "", line)
                print line
                exit
            }' "${SCRIPT_DIR}/values-secret.yaml")"
        if [[ -n "$DB_PASS" ]]; then
            echo "Using Harbor DB password from values-secret.yaml"
        else
            echo "Error: no password found in values-secret.yaml." >&2
            echo "  Copy values-secret.yaml.example to values-secret.yaml and fill it in first." >&2
            exit 1
        fi
    else
        echo "Error: --db-pass is required when values-secret.yaml does not exist." >&2
        echo "  Copy values-secret.yaml.example to values-secret.yaml first." >&2
        exit 1
    fi
fi

if [[ "$DRY_RUN" == true ]]; then
    echo "DRY-RUN: would create role 'harbor' and database harbor in postgres"
    exit 0
fi

echo "Creating Harbor role and database in the shared postgres..."

if [[ -z "$PG_SUPERUSER_PASSWORD" ]]; then
    # The postgres Kustomize secretGenerator produces a hashed name like
    # postgres-credentials-<hash>; resolve it dynamically and take the newest
    # one in case older hashes linger after re-generation.
    PG_SECRET="$(kubectl get secret -n postgres -o name \
        --sort-by=.metadata.creationTimestamp 2>/dev/null \
        | awk -F/ '/^secret\/postgres-credentials(-|$)/ { last = $2 }
                   END { print last }')"
    if [[ -z "$PG_SECRET" ]]; then
        echo "Error: --pg-pass not provided and no postgres-credentials secret found in postgres namespace." >&2
        exit 1
    fi
    if ! PG_SUPERUSER_PASSWORD=$(kubectl get secret "$PG_SECRET" -n postgres \
        -o go-template='{{.data.POSTGRES_PASSWORD|base64decode}}' 2>/dev/null); then
        echo "Error: could not read POSTGRES_PASSWORD from secret $PG_SECRET." >&2
        exit 1
    fi
fi

kubectl exec -n postgres postgres-0 -i -- \
    env PGPASSWORD="${PG_SUPERUSER_PASSWORD}" \
    bash -s -- "${DB_PASS}" <<'SCRIPT'
set -euo pipefail

DB_PASS="${1:-}"
if [[ -z "${DB_PASS}" ]]; then
    echo "Error: password argument is required" >&2
    exit 1
fi

psql -U postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'harbor') THEN
        CREATE ROLE harbor WITH LOGIN PASSWORD '${DB_PASS}';
        RAISE NOTICE 'Role harbor created';
    ELSE
        RAISE NOTICE 'Role harbor already exists';
    END IF;
END
\$\$;
SQL

if psql -U postgres -tc "SELECT 1 FROM pg_database WHERE datname='harbor'" | grep -q 1; then
    echo "  Database harbor already exists"
else
    psql -U postgres -v ON_ERROR_STOP=1 <<SQL
CREATE DATABASE "harbor" OWNER "harbor";
GRANT ALL PRIVILEGES ON DATABASE "harbor" TO "harbor";
SQL
    echo "  Database harbor created"
fi
SCRIPT

echo ""
echo "Done."
echo "  Role:     harbor"
echo "  Database: harbor"
