# k8s-apps

Kubernetes application workloads deployed on the [k8s-cluster](https://github.com/junjieyuan/k8s-cluster).

## Structure

```
gateway/            Shared Gateway + wildcard TLS (deploy first)
cloudflared/        Cloudflare Tunnel client
postgres/           PostgreSQL with persistent storage
monitoring/         Prometheus + Grafana (Kustomize + Helm chart)
headlamp/           Kubernetes dashboard (Kustomize + Helm chart)
harbor/             Container registry (Kustomize + Helm chart)
llama-server/       llama.cpp inference server
comfyui/            ComfyUI image generation (GPU)
auth-service/       Authentication service (multi-environment)
```

## Applications

| App | Description | Stack |
|-----|-------------|-------|
| **gateway** | Shared Cilium Gateway + wildcard TLS certificate | Cilium Gateway API, cert-manager |
| **cloudflared** | Cloudflare Tunnel client for external access | Deployment, Kustomize |
| **llama-server** | llama.cpp inference server (Gemma 4, Qwen 3.6) | GPU (RTX 4080), Kustomize |
| **comfyui** | ComfyUI image generation (stable diffusion / flux workflows) | GPU (RTX 4080), Kustomize |
| **monitoring** | Prometheus + Grafana (kube-prometheus-stack) | Kustomize (helmCharts) |
| **headlamp** | Kubernetes dashboard | Kustomize (helmCharts) |
| **harbor** | Container registry (Harbor OSS v2.15.2) | Kustomize (helmCharts) |
| **postgres** | PostgreSQL with persistent storage | StatefulSet, Kustomize |
| **auth-service** | Authentication service (multi-environment: dev/staging/prod) | Deployment, Kustomize |

## Prerequisites

- Running Kubernetes cluster (provisioned by [`k8s-cluster`](https://github.com/junjieyuan/k8s-cluster))
- Gateway API CRDs + Cilium CNI (from `k8s-cluster`)
- cert-manager (from `k8s-cluster`) — required for TLS; optional for HTTP-only
- `kubectl` configured
- `helm` — required for apps using the Kustomize `helmCharts` generator (see the Applications table for which)
- GPU worker node(s) with label `feature.node.kubernetes.io/pci-10de.present=true` (for llama-server, comfyui)

## Usage

```bash
# 1. Shared Gateway (deploy first)
kubectl apply -k gateway/

# 2. Infrastructure
kubectl apply -k postgres/

# monitoring: create values-secret.yaml first, then deploy
cp monitoring/values-secret.yaml.example monitoring/values-secret.yaml
# edit monitoring/values-secret.yaml with real password
kubectl kustomize --enable-helm monitoring/ | kubectl apply -f -

# 3. Applications
kubectl apply -k cloudflared/
kubectl apply -k llama-server/
# comfyui: models are read-only from the shared host HF cache by design; there
# is no persistent model storage (see comfyui/extra_model_paths.yaml).
kubectl apply -k comfyui/
kubectl kustomize --enable-helm headlamp/ | kubectl apply -f -
kubectl kustomize --enable-helm harbor/ | kubectl apply -f -

# 4. Auth (multi-environment)
kubectl apply -k auth-service/overlays/dev/
bash auth-service/db-setup.sh --env dev
```

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
                  ├─ llama.junjie.pro              → llama-server:8080
                  ├─ comfyui.junjie.pro            → comfyui:8188
                  ├─ grafana.junjie.pro            → kube-prometheus-stack-grafana:80
                  ├─ headlamp.junjie.pro           → headlamp:80
                  ├─ harbor.junjie.pro             → harbor:80 (nginx frontend)
                  └─ auth.junjie.pro               → auth-service:8080

  postgres (ClusterIP, no external route) → accessed internally by auth-service
```
