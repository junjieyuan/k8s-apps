# AGENTS.md

## Project nature

This repo manages Kubernetes application workloads running on an existing
k8s cluster. It is NOT responsible for cluster provisioning — that lives
in the **`k8s-cluster`** repo (`~/Projects/k8s-cluster`). See that repo
for VM provisioning, kubeadm init/join, CNI/CSI/GPU operator installation.

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

## Commit conventions

- Atomic commits with conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`
- Each commit changes one logical concern.
