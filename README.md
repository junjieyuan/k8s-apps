# k8s-apps

Kubernetes application workloads deployed on the [k8s-cluster](https://github.com/junjieyuan/k8s-cluster).

## Applications

| App | Description | Stack |
|-----|-------------|-------|
| **gateway** | Shared Cilium Gateway + wildcard TLS certificate | Cilium Gateway API, cert-manager |
| **cloudflared** | Cloudflare Tunnel client for external access | Deployment, Kustomize |
| **llama-server** | llama.cpp inference server (multi-model router) | GPU (RTX 4080), Kustomize |
| **comfyui** | ComfyUI image generation (stable diffusion / flux workflows) | GPU (RTX 4080), Kustomize |
| **vox** | Text-to-speech microservice (vLLM-Omni, OpenAI-compatible API; currently serves Qwen3-TTS) | GPU (RTX 4080), Kustomize |
| **monitoring** | Prometheus + Grafana (kube-prometheus-stack) | Kustomize (helmCharts) |
| **headlamp** | Kubernetes dashboard | Kustomize (helmCharts) |
| **harbor** | Container registry (Harbor OSS v2.15.2) | Kustomize (helmCharts) |
| **keycloak-operator** | Keycloak Operator (manages the keycloak app) | Deployment, Kustomize |
| **keycloak** | Identity and access management (Keycloak 26.7.2) | Keycloak CR (StatefulSet), Kustomize |
| **postgres** | PostgreSQL with persistent storage | StatefulSet, Kustomize |
| **hermes** | Hermes Agent (dashboard + OpenAI-compatible API server) | Deployment, Kustomize |

## Prerequisites

- Running Kubernetes cluster (provisioned by [`k8s-cluster`](https://github.com/junjieyuan/k8s-cluster))
- Gateway API CRDs + Cilium CNI (from `k8s-cluster`)
- cert-manager (from `k8s-cluster`) — required for TLS; optional for HTTP-only
- `kubectl` configured
- `helm` — required for apps using the Kustomize `helmCharts` generator (see the Applications table for which)
- `yamlfmt` (google/yamlfmt) — formats YAML as KYAML (see AGENTS.md)
- GPU worker node(s) with label `feature.node.kubernetes.io/pci-10de.present=true` (for llama-server, comfyui, vox)

## Usage

```bash
# 1. Shared Gateway (deploy first)
kubectl apply -k gateway/

# 2. Infrastructure
kubectl apply -k postgres/

# monitoring: create values-secret.yaml first, then deploy
cp monitoring/values-secret.yaml.example monitoring/values-secret.yaml
# edit monitoring/values-secret.yaml with real password
kubectl kustomize --enable-helm monitoring/ | kubectl diff -f -
# CRDs are not in the deploy stream (the helmCharts generator never
# renders the chart's crds/); deploy per the chart's upgrade docs
kubectl kustomize --enable-helm monitoring/ | kubectl apply -f -

# 3. Applications
kubectl apply -k cloudflared/
kubectl apply -k llama-server/
# comfyui: models are read-only from the shared host HF cache by design; there
# is no persistent model storage (see comfyui/extra_model_paths.yaml).
kubectl apply -k comfyui/
kubectl apply -k vox/
kubectl kustomize --enable-helm headlamp/ | kubectl apply -f -
kubectl kustomize --enable-helm harbor/ | kubectl apply -f -
kubectl apply -k hermes/

```

### Keycloak

Keycloak is **operator-managed**: `keycloak-operator/` (Keycloak Operator
26.7.2) owns the StatefulSet and services created from the `Keycloak` CR in
`keycloak/`. Keycloak serves plain HTTP internally — TLS terminates at the
shared Gateway. The admin console is at `https://keycloak.junjie.pro/admin`.
State lives in the shared PostgreSQL from `postgres/` (no PVC).

```bash
# 1. Secret values (gitignored): DB role + master-realm bootstrap admin
cp keycloak/.env.example keycloak/.env
cp keycloak/.env-operator-admin.example keycloak/.env-operator-admin
# edit both with real passwords

# 2. Provision role + database on the shared postgres
bash keycloak/db-setup.sh

# 3. Operator first, then the app
kubectl apply -k keycloak-operator/
kubectl apply -k keycloak/

# 4. One-shot realm import (not part of -k): apply, then delete the
#    KeycloakRealmImport CR once status.conditions shows Done=True —
#    the realm persists in the database
kubectl apply -f keycloak/realms/prod-platform.yaml
kubectl delete keycloakrealmimport -n keycloak prod-platform

# 5. Add the hostname to the Cloudflare tunnel ingress
kubectl apply -k cloudflared/
```

**Fresh-database rebuild:** on first start the pod bootstraps the
`keycloak-operator` master-realm user (from `.env-operator-admin`), which
also lets the operator authenticate; afterwards recreate `platform-admin`
(the permanent human admin) via kcadm — it is not bootstrapped.

### Harbor

Harbor reuses the shared PostgreSQL from `postgres/` (no bundled database) and
serves plain HTTP internally — TLS terminates at the shared Gateway. The
registry endpoint is `harbor.junjie.pro` (docker login/pull/push), the UI is at
`https://harbor.junjie.pro`.

```bash
# 1. Secret values (gitignored): admin password + DB role password
cp harbor/values-secret.yaml.example harbor/values-secret.yaml
# edit harbor/values-secret.yaml with real passwords (xsrfKey must be 32 chars)

# 2. Provision role + database on the shared postgres, then deploy
bash harbor/db-setup.sh
kubectl kustomize --enable-helm harbor/ | kubectl apply -f -
```

Trivy scanning is disabled to keep the footprint small; to enable it later, set
`trivy.enabled: true` in `harbor/values.yaml`.

## Architecture

```
# Unified ingress (junjie.pro)
External → Cloudflare Edge ← cloudflared (3 replicas, tunnel)
  └─ TLS (port 443, wildcard: *.junjie.pro) → cloudflared pod
      └─ https://cilium-gateway-gateway.gateway:443 (originServerName = SNI)
          └─ Cilium Gateway (shared, namespace: gateway, pinned IP: 192.168.200.200)
              └─ HTTPRoute[host: *.junjie.pro]
                  ├─ llama.junjie.pro              → llama-server:9931
                  ├─ comfyui.junjie.pro            → comfyui:8188
                  ├─ vox.junjie.pro                → vox:8000
                  ├─ grafana.junjie.pro            → kube-prometheus-stack-grafana:80
                  ├─ headlamp.junjie.pro           → headlamp:80
                  ├─ harbor.junjie.pro             → harbor:80 (nginx frontend)
                  ├─ keycloak.junjie.pro           → keycloak-service:8080
                  ├─ hermes.junjie.pro             → hermes:9119 (dashboard)
                  └─ hermes-api.junjie.pro         → hermes:8642 (OpenAI API)

  postgres (ClusterIP, no external route) → accessed internally by keycloak
```
