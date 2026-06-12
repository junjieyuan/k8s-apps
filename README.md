# k8s-apps

Kubernetes application workloads deployed on the [k8s-cluster](https://github.com/junjieyuan/k8s-cluster).
Managed via `kubectl` apply scripts, not Helm charts.

## Applications

| App | Description | Stack |
|-----|-------------|-------|
| **llama-server** | llama.cpp inference server (Gemma 4, Qwen 3.6) | GPU (RTX 4080), Cilium Gateway API |

## Prerequisites

- Running Kubernetes cluster (provisioned by [`k8s-cluster`](https://github.com/junjieyuan/k8s-cluster))
- Gateway API CRDs + Cilium CNI (from `k8s-cluster`)
- cert-manager (from `k8s-cluster`) — required for TLS; optional for HTTP-only
- GPU worker node(s) with NVIDIA GPU labels (`pci-10de.present=true`)
- `kubectl` configured

## Usage

```bash
# Deploy with HTTP + auto-issued TLS certificate
bash llama-server/install.sh --api-key $(uuidgen)

# Custom hostname
bash llama-server/install.sh --api-key $(uuidgen) --host llama.example.com
```

## Architecture

```
External → LB IP → Cilium Gateway
  ├─ HTTP (port 80) → HTTPRoute → Service → Pod
  └─ HTTPS (port 443, TLS termination via cert-manager) → HTTPRoute → Service → Pod
```
