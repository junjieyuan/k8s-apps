# AGENTS.md

## Project nature

This repo manages Kubernetes application workloads running on an existing
k8s cluster. It is NOT responsible for cluster provisioning — that lives
in the `k8s-cluster` repo.

## Tool constraints

- **Bash only** — `#!/usr/bin/env bash` + `set -euo pipefail`. Never introduce
  Python, Node, or other languages for deployment scripts.
- **No package managers** — `kubectl` is the only runtime dependency.
  Helm is used selectively where it provides clear value (e.g. operators).

## Code style

- Follow the same conventions as the `k8s-cluster` repo.
- YAML manifests use 2-space indentation.
- `install.sh` is the entry point for each application.

## Privilege handling

All scripts run as the current user. `kubectl` uses the current kubeconfig.
No root escalation needed (cluster access is role-based).

## Secrets

- `secret.yaml` is gitignored. Template files use `secret.yaml.example` with
  placeholder values.
- Real credentials or API keys are never committed.
- `models.ini` may contain public HuggingFace repo references — that is fine.

## Commit conventions

- Atomic commits with conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`
- Each commit changes one logical concern.
