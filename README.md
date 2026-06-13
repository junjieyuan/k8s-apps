# k8s-apps

Kubernetes application workloads deployed on the [k8s-cluster](https://github.com/junjieyuan/k8s-cluster).
Managed via `kubectl` apply scripts and Helm charts.

## Applications

| App | Description | Stack |
|-----|-------------|-------|
| **gateway** | Shared Cilium Gateway + TLS certificate for all apps | Cilium Gateway API, cert-manager |
| **llama-server** | llama.cpp inference server (Gemma 4, Qwen 3.6) | GPU (RTX 4080), Cilium Gateway API |
| **monitoring** | Prometheus + Grafana (kube-prometheus-stack) | Helm, Cilium Gateway API |

## Prerequisites

- Running Kubernetes cluster (provisioned by [`k8s-cluster`](https://github.com/junjieyuan/k8s-cluster))
- Gateway API CRDs + Cilium CNI (from `k8s-cluster`)
- cert-manager (from `k8s-cluster`) — required for TLS; optional for HTTP-only
- GPU worker node(s) with NVIDIA GPU labels (`pci-10de.present=true`)
- `kubectl` configured

## Usage

```bash
# 1. Deploy the shared Gateway + wildcard TLS certificate first
bash gateway/install.sh
# Or with a custom wildcard:
bash gateway/install.sh --wildcard '*.example.com'

# 2. Deploy applications
bash llama-server/install.sh --api-key $(uuidgen)
bash monitoring/install.sh --grafana-password $(uuidgen)

# Custom hostnames
bash llama-server/install.sh --api-key $(uuidgen) --host llama.example.com
bash monitoring/install.sh --grafana-password $(uuidgen) --host grafana.example.com

# Pin chart version
bash monitoring/install.sh --grafana-password $(uuidgen) --version 86.2.2
```

## Architecture

```
External → LB IP (192.168.122.200) → Cilium Gateway (shared, namespace: gateway, pinned IP)
  ├─ HTTP (port 80)  → HTTPRoute[host: llama.k8s.junjie.pro]   → llama-server
  │                  → HTTPRoute[host: grafana.k8s.junjie.pro]  → monitoring/grafana
  └─ HTTPS (port 443, TLS via cert-manager, wildcard: *.k8s.junjie.pro) → same
```
