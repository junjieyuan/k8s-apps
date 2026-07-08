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
aren't reflected back into code. When in doubt, re-run `kubectl apply -k <app>`
to verify idempotency.

## Directory structure

Each app lives in its own directory. The canonical layout varies by stack:
- **Plain YAML apps** (cloudflared, gateway, postgres, llama-server,
  auth-service) use a `kustomization.yaml` at the root or in `overlays/`
  for multi-environment apps, and deploy via `kubectl apply -k <app>/`.
- **Helm apps** (monitoring, headlamp) keep an `install.sh` wrapper around
  `helm upgrade --install` with a pinned chart version.

Shared infrastructure (Gateway, Certificate) lives in `gateway/`.

## Conventions

### Shell & tools

- **Bash only** — `#!/usr/bin/env bash` + `set -euo pipefail`. Never
  introduce Python, Node, or other languages.
- **Check runtime deps** with `command -v` early in the script, before any
  work begins. Never assume `helm`, `kubectl`, or other tools are present.
- **`kubectl` is the primary tool** for resource management.
  - **Kustomize** (`kubectl apply -k`) is the default for all plain YAML
    apps. Variable injection (namespace, image tag) lives in
    `kustomization.yaml` via `namespace:` and `images.newTag:`. Plain YAML
    files contain no `${VAR}` placeholders. Secrets use `secretGenerator`
    with `.env` files (real values gitignored, `.env.example` committed as
    template). Multi-environment apps use `base/` + `overlays/<env>/`.
- **Helm** is used **only** when managing a complex stack that ships as a
  single upstream chart with many interdependent sub-resources (CRDs,
  dashboards, alert rules, service monitors, etc.). Example:
  kube-prometheus-stack. For a simple deployment + service + route, Helm
  adds unnecessary abstraction — use Kustomize.
- **`SCRIPT_DIR` pattern** — `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
  for locating sibling files.

### Secrets

- **Separate secrets from code.** Real values live in gitignored files
  (`.env`, `secret.yaml`, credentials, etc.). Committed files use `.example`
  variants with placeholder values only. Never commit keys, passwords,
  tokens, certificates, credentials, or kubeconfig files.
- **Kustomize `secretGenerator`** is the preferred approach. It reads from
  `.env` and generates a hashed Secret at build time, automatically
  patching all `secretRef.name` references in downstream resources.
- `models.ini` may contain public HuggingFace repo references — that is fine.

### Versioning

- **Pin explicit versions** (e.g. `2026.6.1`, `server-cuda12-b9894`, not
  `latest`), but keep them current. Check upstream releases before deployment.
  For Kustomize apps, pin the version in `kustomization.yaml` via
  `images.newTag:`. For Helm apps, use a component-prefixed env var
  (e.g. `HEADLAMP_VERSION`, `KUBE_PROMETHEUS_STACK_VERSION`).
- **Container images** — prefer explicit build tags (e.g.
  `server-cuda12-b9894`), but floating tags (e.g. `latest`) are
  acceptable for dev-iteration apps (auth-service) paired with
  `imagePullPolicy: Always`.
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
