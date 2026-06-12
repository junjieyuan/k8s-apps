# AGENTS.md

## Project nature

This repo manages Kubernetes application workloads running on an existing
k8s cluster. It is NOT responsible for cluster provisioning — that lives
in the **`k8s-cluster`** repo (`~/Projects/k8s-cluster`). See that repo
for VM provisioning, kubeadm init/join, CNI/CSI/GPU operator installation.

**The repo must be in full sync with the cluster** — every resource running
in the cluster must have a corresponding manifest or values file in this repo.
No manual `kubectl` edits on the cluster that aren't reflected back into code.
When in doubt, re-run `install.sh` to verify idempotency.

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
- **Helm charts** — use `--version` to pin chart version matching the app version.
  Store chart-specific values in `values.yaml` for each operator.
- **CRDs** — install from upstream release artifacts with explicit version URLs
  (e.g. Gateway API `standard-install.yaml`). Never copy CRD manifests into this repo.
- **Gateway API** — CRD version must match the version supported by the CNI
  (Cilium) and the `gateway.networking.k8s.io` API version used in manifests.

## Best practices

- **Operators via Helm** — cert-manager, GPU operator, CSI drivers. Declarative
  configuration in `values.yaml` + `install.sh` as the entry point.
- **Application workloads via kubectl** — plain YAML manifests, `envsubst` for
  templating, no Helm or Kustomize.
- **Gateway API over Ingress** — use `Gateway` + `HTTPRoute` from
  `gateway.networking.k8s.io/v1`, not `networking.k8s.io/v1` Ingress.
- **TLS via cert-manager** — `ClusterIssuer` + `Certificate` resources for
  automatic Let's Encrypt provisioning and renewal.
- **Secrets never committed** — use `.example` files with placeholders, pass real
  values via CLI flags or gitignored files.

## Commit conventions

- Atomic commits with conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`
- Each commit changes one logical concern.
