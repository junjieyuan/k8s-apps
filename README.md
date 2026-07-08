# k8s-apps

Kubernetes application workloads deployed on the [k8s-cluster](https://github.com/junjieyuan/k8s-cluster).

## Structure

```
gateway/            Shared Gateway + wildcard TLS (deploy first)
cloudflared/        Cloudflare Tunnel client
postgres/           PostgreSQL with persistent storage
monitoring/         Prometheus + Grafana (Kustomize + Helm chart)
headlamp/           Kubernetes dashboard (Kustomize + Helm chart)
llama-server/       llama.cpp inference server
auth-service/       Authentication service (multi-environment)
```

## Applications

| App | Description | Stack |
|-----|-------------|-------|
| **gateway** | Shared Cilium Gateway + wildcard TLS certificate | Cilium Gateway API, cert-manager |
| **cloudflared** | Cloudflare Tunnel client for external access | Deployment, Kustomize |
| **llama-server** | llama.cpp inference server (Gemma 4, Qwen 3.6) | GPU (RTX 4080), Kustomize |
| **monitoring** | Prometheus + Grafana (kube-prometheus-stack) | Kustomize (helmCharts) |
| **headlamp** | Kubernetes dashboard | Kustomize (helmCharts) |
| **postgres** | PostgreSQL with persistent storage | StatefulSet, Kustomize |
| **auth-service** | Authentication service (multi-environment: dev/staging/prod) | Deployment, Kustomize |

## Prerequisites

- Running Kubernetes cluster (provisioned by [`k8s-cluster`](https://github.com/junjieyuan/k8s-cluster))
- Gateway API CRDs + Cilium CNI (from `k8s-cluster`)
- cert-manager (from `k8s-cluster`) — required for TLS; optional for HTTP-only
- `kubectl` configured
- `helm` — required for `helmCharts`-based apps (monitoring, headlamp)
- GPU worker node(s) with label `feature.node.kubernetes.io/pci-10de.present=true` (for llama-server)

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
kubectl kustomize --enable-helm headlamp/ | kubectl apply -f -

# 4. Auth (multi-environment)
kubectl apply -k auth-service/overlays/dev/
bash auth-service/db-setup.sh --env dev
```

## Architecture

```
# Gateway path (k8s.junjie.pro)
External → LB IP (192.168.122.200) → Cilium Gateway (shared, namespace: gateway, pinned IP)
  ├─ HTTP (port 80)  → HTTPRoute[host: llama.k8s.junjie.pro]    → llama-server
  │                  → HTTPRoute[host: grafana.k8s.junjie.pro]   → monitoring (Grafana)
  │                  → HTTPRoute[host: headlamp.k8s.junjie.pro]  → headlamp
  │                  → HTTPRoute[host: auth.k8s.junjie.pro]      → auth-service
  └─ HTTPS (port 443, TLS via cert-manager, wildcard: *.k8s.junjie.pro) → same

# Cloudflare Tunnel path (junjie.pro)
External → Cloudflare Edge ← cloudflared (3 replicas, tunnel)
  ├─ grafana.junjie.pro    → kube-prometheus-stack-grafana.monitoring:80
  └─ (more to add)

  postgres (ClusterIP, no external route) → accessed internally by auth-service
```
