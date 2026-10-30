# k8s-apps

Kubernetes application workloads deployed on the [k8s-cluster](https://github.com/junjieyuan/k8s-cluster).

## Applications

| App | Description | Stack |
|-----|-------------|-------|
| **gateway** | Shared Cilium Gateway + wildcard TLS certificate | Cilium Gateway API, cert-manager |
| **cloudflared** | Cloudflare Tunnel client for external access | Deployment, Kustomize |
| **llama** | llama.cpp inference server (multi-model router) | GPU (RTX 4080), Kustomize |
| **strata** | Strata inference server | GPU (RTX 4080), Kustomize |
| **comfyui** | ComfyUI image generation (stable diffusion / flux workflows) | GPU (RTX 4080), Kustomize |
| **vox** | Text-to-speech microservice (vLLM-Omni, OpenAI-compatible API; currently serves Qwen3-TTS) | GPU (RTX 4080), Kustomize |
| **monitoring** | Prometheus + Grafana (kube-prometheus-stack) | Kustomize (helmCharts) |
| **headlamp** | Kubernetes dashboard | Kustomize (helmCharts) |
| **postgres** | PostgreSQL with persistent storage | StatefulSet, Kustomize |

## Prerequisites

- Running Kubernetes cluster (provisioned by [`k8s-cluster`](https://github.com/junjieyuan/k8s-cluster))
- Gateway API CRDs + Cilium CNI (from `k8s-cluster`)
- cert-manager (from `k8s-cluster`) — required for TLS; optional for HTTP-only
- `kubectl` configured
- `helm` — required for apps using the Kustomize `helmCharts` generator (see the Applications table for which)
- `yamlfmt` (google/yamlfmt) — formats YAML as KYAML (see AGENTS.md)
- GPU worker node(s) with label `feature.node.kubernetes.io/pci-10de.present=true` (for llama, comfyui, vox, strata)

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
kubectl apply -k llama/
# strata: ships with replicas 0 (the 4080 is shared with llama/comfyui/vox).
# Needs strata/.env with STRATA_API_KEY (16+ chars, e.g. openssl rand -hex 24);
# copy strata/.env.example only when the file is missing, so an existing key
# survives. Weights are read read-only from the same host HF cache as llama;
# /data is node-local SSD.
kubectl apply -k strata/
# comfyui: models are read-only from the shared host HF cache by design; there
# is no persistent model storage (see comfyui/extra_model_paths.yaml).
kubectl apply -k comfyui/
kubectl apply -k vox/
kubectl kustomize --enable-helm headlamp/ | kubectl apply -f -

```

## Architecture

```
# Unified ingress (junjie.pro)
External → Cloudflare Edge ← cloudflared (3 replicas, tunnel)
  └─ TLS (port 443, wildcard: *.junjie.pro) → cloudflared pod
      └─ https://cilium-gateway-gateway.gateway:443 (originServerName = SNI)
          └─ Cilium Gateway (shared, namespace: gateway, pinned IP: 192.168.200.200)
              └─ HTTPRoute[host: *.junjie.pro]
                  ├─ llama.junjie.pro              → llama:9931
                  ├─ strata.junjie.pro             → strata:8080
                  ├─ comfyui.junjie.pro            → comfyui:8188
                  ├─ vox.junjie.pro                → vox:8000
                  ├─ grafana.junjie.pro            → kube-prometheus-stack-grafana:80
                  └─ headlamp.junjie.pro           → headlamp:80

  postgres (ClusterIP, no external route)
```
