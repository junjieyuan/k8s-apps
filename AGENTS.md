# CLAUDE.md

## Project nature

This repo manages Kubernetes application workloads running on an existing
k8s cluster. It is NOT responsible for cluster provisioning — that lives
in the **`k8s-cluster`** repo (VM provisioning, kubeadm init/join, CNI/CSI,
GPU operator, cert-manager, external-dns). Only user-facing services and
their resources (deployments, services, gateways, HTTPRoutes, certificates)
live here.

**The repo must be in full sync with the cluster** — every application
resource running in the cluster must have a corresponding manifest or
values file in this repo. No manual `kubectl` edits on the cluster that
aren't reflected back into code. When in doubt, re-run `install.sh` to
verify idempotency.

## Directory structure

Each app lives in its own directory with an `install.sh` entry point.
Shared infrastructure (Gateway, Certificate) lives in `gateway/`.
Look at existing apps for the canonical file layout — what files an app
has depends on its stack (plain YAML, Helm, StatefulSet, etc.).

## Conventions

### Shell & tools

- **Bash only** — `#!/usr/bin/env bash` + `set -euo pipefail`. Never
  introduce Python, Node, or other languages.
- **Check runtime deps** with `command -v` early in the script, before any
  work begins. Never assume `helm`, `kubectl`, or other tools are present.
- **`kubectl` is the primary tool** for resource management. Application
  workloads (deployment, service, route, PVC) default to plain YAML +
  `envsubst`. Never `kubectl apply -f` directly on YAML files containing
  `${VAR}` placeholders — always pipe through `envsubst` into a temp file
  (with `trap` cleanup). Call `envsubst` with only the specific variables
  the template needs (e.g. `envsubst '$GATEWAY_HOST'`), not all exported
  vars.
- **Helm** is used **only** when managing a complex stack that ships as a
  single upstream chart with many interdependent sub-resources (CRDs,
  dashboards, alert rules, service monitors, etc.). Example:
  kube-prometheus-stack. For a simple deployment + service + route, Helm
  adds unnecessary abstraction — use kubectl + envsubst.
- **Secret idempotency** — use `kubectl create ... --dry-run=client -o
  yaml | kubectl apply -f -` for Secrets and other generated resources.
- **`SCRIPT_DIR` pattern** — `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
  for locating sibling files.

### Secrets

- **Separate secrets from code.** Real values live in gitignored files
  (`secret.yaml`, credentials, etc.). Committed files use `.example`
  variants with placeholder values only. Never commit keys, passwords,
  tokens, certificates, credentials, or kubeconfig files.
- `models.ini` may contain public HuggingFace repo references — that is fine.
- Pass real values via CLI flags at deploy time, never hardcoded in scripts.

### Versioning

- **Component-specific env var names** (e.g. `KUBE_PROMETHEUS_STACK_VERSION`,
  `POSTGRES_VERSION`), never bare `VERSION`. This avoids collisions when
  scripts are sourced together.
- **Pin explicit versions** (e.g. `v1.20.2`, not `latest`), but keep them
  current. Check upstream releases before deployment.
- **Container images** — prefer explicit build tags (e.g.
  `server-cuda-b9603`), but floating tags (e.g. `server-cuda`) are
  acceptable when paired with `imagePullPolicy: Always` and regular
  restart cycles.
- **Gateway API** — CRD version must match the version supported by the CNI
  (Cilium) and the `gateway.networking.k8s.io` API version used in manifests.

### YAML style

- 2-space indentation.
- **No redundant defaults** — omit YAML fields that match Kubernetes defaults
  (e.g. `protocol: TCP`, `replicas: 1`, `terminationGracePeriodSeconds:
  30`). Only include explicit overrides so intentional deviations stand out.

### Gateway design

- **Dedicated namespace** — the shared Gateway lives in `gateway/`, never
  inside an application namespace.
- **Gateway API over Ingress** — use `Gateway` + `HTTPRoute` from
  `gateway.networking.k8s.io/v1`.
- **TLS via cert-manager** — `ClusterIssuer` + `Certificate` for automatic
  Let's Encrypt provisioning and renewal.
- **Wildcard TLS** — a single `*.domain` certificate covers all app hostnames
  and requires no changes when adding new apps. Needs a DNS-01 solver
  (configured in `k8s-cluster`).
- **IP pinning** — in bare-metal environments without BGP, pin the LB IP via
  `spec.addresses` so it survives Gateway deletion and recreation.
- **Cross-namespace routes** — HTTPRoutes reference the Gateway via
  `parentRefs.namespace`. The Gateway's `allowedRoutes.namespaces.from:
  All` enables this without per-app ReferenceGrants.

## Debugging

- **After deploying any new component, immediately check logs** for E/F-level
  errors: `kubectl logs -n <namespace> deployment/<name>`. CrashLoop/BackOff
  must be investigated before moving on.
- **Cluster sync spot-check** — after any deploy, confirm the cluster
  matches the manifest:
  `kubectl get deploy <name> -n <ns> -o jsonpath='{.spec.template.spec.containers[0].image}'`

## Deployment checklist

See [DEPLOYMENT_CHECKLIST.md](DEPLOYMENT_CHECKLIST.md) for the full
pre-deployment verification checklist.

## Commit conventions

- Atomic commits following [Conventional Commits](https://www.conventionalcommits.org/en/v1.0.0/).
- Each commit changes one logical concern.
