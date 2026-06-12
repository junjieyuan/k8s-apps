# AGENTS.md

## Project nature

This repo manages Kubernetes application workloads running on an existing
k8s cluster. It is NOT responsible for cluster provisioning — that lives
in the **`k8s-cluster`** repo. See that repo for VM provisioning, kubeadm
init/join, CNI/CSI/GPU operator, cert-manager, and external-dns installation.

**This repo is for application workloads only.** Cluster-level infrastructure
(CNI, CSI, GPU operator, cert-manager, external-dns) belongs in `k8s-cluster`.
Only user-facing services and their resources (deployments, services, gateways,
HTTPRoutes, certificates) live here.

**The repo must be in full sync with the cluster** — every application resource
running in the cluster must have a corresponding manifest or values file in this
repo. No manual `kubectl` edits on the cluster that aren't reflected back into
code. When in doubt, re-run `install.sh` to verify idempotency.

## Directory structure

Each application lives in its own directory with an `install.sh` entry point:

```
<app-name>/
├── install.sh              # entry point, deploys all resources
├── namespace.yaml           # Namespace
├── deployment.yaml          # Deployment
├── service.yaml             # Service (ClusterIP)
├── gateway.yaml             # Gateway (Cilium Gateway API)
├── httproute.yaml           # HTTPRoute (uses ${GATEWAY_HOST} template)
├── certificate.yaml         # Certificate (cert-manager, uses ${GATEWAY_HOST} template)
├── persistentvolume.yaml    # PersistentVolume (optional)
├── persistentvolumeclaim.yaml  # PersistentVolumeClaim (optional)
├── secret.yaml.example      # Secret template (never commit real values)
└── models.ini               # Config file (optional)
```

## Tool constraints

- **Bash only** — `#!/usr/bin/env bash` + `set -euo pipefail`. Never introduce
  Python, Node, or other languages for deployment scripts.
- **`kubectl` is the primary tool** for resource management.
- **Helm** is allowed for operators and complex charts where `values.yaml`
  provides clear advantage over raw manifests (e.g. cert-manager, GPU operator).
  Application workloads default to plain YAML + `kubectl`.

## Code style

- Follow the same conventions as the `k8s-cluster` repo.
- YAML manifests use 2-space indentation.
- `install.sh` is the entry point for each application.

## Privilege handling

All scripts run as the current user. `kubectl` uses the current kubeconfig.
No root escalation needed (cluster access is role-based).

## Secrets

**Separate secrets from code.** Real values live in gitignored files
(`secret.yaml`, credentials, etc.). Committed files use `.example` variants
with placeholder values only. This keeps secrets out of git history and
allows each environment to supply its own values.

- `models.ini` may contain public HuggingFace repo references — that is fine.

**Absolute prohibition:** never commit any secret, key, password, token,
certificate, or credential to this repository. This includes but is not
limited to API keys, SSH private keys, TLS certificates, kubeconfig files,
and database credentials.

## Component versions

- **Always target latest stable** — pin explicit versions (e.g. `v1.20.2`, not
  `latest`), but keep them current. Check upstream releases before deployment.
- **Container images** — pin by SHA256 digest or explicit build tag (e.g.
  `server-cuda-b9603`, not `server-cuda`). Never use floating tags.
- **Gateway API** — CRD version must match the version supported by the CNI
  (Cilium) and the `gateway.networking.k8s.io` API version used in manifests.

## Best practices

- **Application workloads via kubectl** — plain YAML manifests, `envsubst` for
  templating, no Helm or Kustomize.
- **Gateway API over Ingress** — use `Gateway` + `HTTPRoute` from
  `gateway.networking.k8s.io/v1`, not `networking.k8s.io/v1` Ingress.
- **TLS via cert-manager** — `ClusterIssuer` + `Certificate` resources for
  automatic Let's Encrypt provisioning and renewal.
- **Secrets never committed** — use `.example` files with placeholders, pass real
  values via CLI flags or gitignored files.

## Debugging deployments

- **After deploying any new component, immediately check logs** for E/F-level
  errors: `kubectl logs -n <namespace> deployment/<name>`. CrashLoop/BackOff
  must be investigated before moving on.
- **Always use `install.sh` to deploy** — never `kubectl apply -f` directly on
  YAML files that contain `${VAR}` placeholders. The install script handles
  `envsubst` substitution via temporary files. Direct apply will pass literals
  like `${GATEWAY_HOST}` to the controller, causing silent misconfiguration.

## Commit conventions

- Atomic commits with conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`
- Each commit changes one logical concern.
