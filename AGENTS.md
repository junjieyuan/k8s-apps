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

## Naming conventions

- **Version variables** — use component-specific env var names (e.g.
  `KUBE_PROMETHEUS_STACK_VERSION`, `LLAMA_SERVER_VERSION`), never bare `VERSION`.
  This avoids collisions when scripts are sourced together.

## Directory structure

Each application lives in its own directory with an `install.sh` entry point.
Shared infrastructure (Gateway, Certificate) lives in `gateway/`.

```
gateway/
├── install.sh              # deploys shared Gateway + TLS Certificate
├── gateway.yaml             # Gateway (Cilium Gateway API, allows routes from all ns)
└── certificate.yaml         # Certificate (cert-manager, uses ${GATEWAY_HOSTS} template)

<app-name>/
├── install.sh              # entry point, deploys all resources
├── namespace.yaml           # Namespace
├── deployment.yaml          # Deployment
├── service.yaml             # Service (ClusterIP)
├── httproute.yaml           # HTTPRoute (uses ${GATEWAY_HOST} template, refs shared Gateway)
├── persistentvolume.yaml    # PersistentVolume (optional)
├── persistentvolumeclaim.yaml  # PersistentVolumeClaim (optional)
├── secret.yaml.example      # Secret template (never commit real values)
└── models.ini               # Config file (optional)
```

## Tool constraints

- **Bash only** — `#!/usr/bin/env bash` + `set -euo pipefail`. Never introduce
  Python, Node, or other languages for deployment scripts.
- **`kubectl` is the primary tool** for resource management. Application
  workloads (deployment, service, ingress/route, PVC) default to plain YAML
  + `envsubst`.
- **Helm** is used **only** when managing a complex stack that ships as a
  single upstream chart with many interdependent sub-resources (CRDs,
  dashboards, alert rules, service monitors, etc.). Example:
  kube-prometheus-stack. For a simple deployment + service + route, Helm
  adds unnecessary abstraction — use kubectl + envsubst.

## Code style

- Follow the same conventions as the `k8s-cluster` repo.
- YAML manifests use 2-space indentation.
- `install.sh` is the entry point for each application.
- **Runtime deps** — check with `command -v` early in the script, before any work begins. Never assume `helm`, `kubectl`, or other tools are present.

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
- **Container images** — prefer explicit build tags (e.g. `server-cuda-b9603`), but
  floating tags (e.g. `server-cuda`) are acceptable when paired with
  `imagePullPolicy: Always` and regular restart cycles.
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

## Deployment checklist

Before declaring any application "done", verify every item.
This applies to new apps and upgrades alike.

### Version consistency

- [ ] `usage()` help text, script default variable, and container image tag
  all reference the same version.
- [ ] Version is overridable via both `--version` CLI flag and an environment
  variable (e.g. `LLAMA_SERVER_VERSION="${LLAMA_SERVER_VERSION:-server-cuda-b9603}"`).
- [ ] Image tag is substituted via `envsubst` into the deployment YAML, not
  hardcoded independently of the version variable.

### YAML manifests

- [ ] Every YAML file containing `${VAR}` placeholders is processed through
  `envsubst` + temp file (with `trap` cleanup) in `install.sh`, never
  `kubectl apply -f` directly.
- [ ] `kubectl create ... --dry-run=client -o yaml | kubectl apply -f -`
  pattern used for Secrets and other generated resources for idempotency.

### Idempotency

- [ ] Re-running `install.sh` produces a no-op: all `kubectl apply` calls
  report "unchanged" or "configured" with no resource recreation.

### Post-deploy verification

- [ ] `kubectl logs -n <ns> deployment/<name>` shows no E/F-level errors.
- [ ] Pod status is `Running` with all containers `Ready`.
- [ ] The script's final summary echoes the version that was actually deployed.
- [ ] `kubectl get httproute -n <ns>` shows the route accepted and bound to
  a Gateway (check the Route status conditions).

### Cluster sync

- [ ] Every resource running in the cluster has a corresponding manifest file
  in this repo. No resource exists only on the cluster.
- [ ] `kubectl get deploy <name> -n <ns> -o jsonpath='{.spec.template.spec.containers[0].image}'`
  matches the image tag in the version variable.

### Script conventions

- [ ] `SCRIPT_DIR` pattern used for locating sibling files.
- [ ] Secrets use `.example` files with placeholders; real values passed via
  CLI flags or gitignored files.
- [ ] `envsubst` is called with only the specific variables that the template
  needs (e.g. `envsubst '$GATEWAY_HOST'`), not all exported vars.

## Commit conventions

- Atomic commits with conventional prefixes: `feat:`, `fix:`, `refactor:`, `docs:`
- Each commit changes one logical concern.
