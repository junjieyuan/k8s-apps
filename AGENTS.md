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
- **Helm + Kustomize apps** (headlamp, monitoring) use the
  `kustomization.yaml` built-in `helmCharts` generator. See Conventions
  for the `--enable-helm` flag requirement.

Shared infrastructure (Gateway, Certificate) lives in `gateway/`.

## Conventions

### Documentation

- **Keep docs in sync with code.** When changing deployment commands,
  secret management, directory structure, or conventions, update these
  files in the same commit or a follow-up:
  - `AGENTS.md` — if conventions change
  - `README.md` — if deploy commands, app list, or architecture change
  - `DEPLOYMENT_CHECKLIST.md` — if verification steps change
  - `.gitignore` — if new ignored file patterns are introduced

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
  - **`helmCharts` generator** — when a Kustomization uses the built-in
    `helmCharts` field, it requires `--enable-helm`. **`kubectl apply -k`
    does NOT support `--enable-helm`**, so you must pipe:
    `kubectl kustomize --enable-helm <dir>/ | kubectl apply -f -`.
    `kustomize build --enable-helm <dir>/ | kubectl apply -f -` also works
    if standalone kustomize is installed. Version pinning goes in the
    `helmCharts[].version` field; overrides in `valuesFile`.
- **Helm** is used **only** via the Kustomize `helmCharts` generator
  — never `helm install` directly. This applies to complex charts
  (kube-prometheus-stack) and simple ones alike. The single exception is
  a Helm chart that ships interdependent CRDs/sub-resources which
  `helm template` handles but plain YAML cannot express concisely. For
  a simple deployment + service + route, use plain Kustomize without
  `helmCharts`.
- **`SCRIPT_DIR` pattern** — `SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"`
  for locating sibling files.

### Secrets

- **Separate secrets from code.** Real values live in gitignored files
  (`.env`, `secret.yaml`, credentials, etc.). Committed files use `.example`
  variants with placeholder values only. Never commit keys, passwords,
  tokens, certificates, credentials, or kubeconfig files.
- **Kustomize `secretGenerator`** is the preferred approach for plain YAML
  apps. It reads from `.env` and generates a hashed Secret at build time,
  automatically patching all `secretRef.name` references in downstream
  resources.
- **`values-secret.yaml`** for `helmCharts` apps — sensitive Helm values
  (passwords, tokens) go in a gitignored `values-secret.yaml` loaded via
  `additionalValuesFiles`. Commit `values-secret.yaml.example` with
  placeholder values as a template.
- `models.ini` may contain public HuggingFace repo references — that is fine.

### Versioning

- **Pin explicit versions** (e.g. `2026.6.1`, `server-cuda12-b9894`, not
  `latest`), but keep them current. Check upstream releases before deployment.
  - Plain Kustomize apps: pin via `images.newTag:` in `kustomization.yaml`.
  - `helmCharts` apps: pin via `helmCharts[].version` in `kustomization.yaml`.
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
