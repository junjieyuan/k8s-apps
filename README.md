# k8s-apps

Kubernetes application workloads deployed on the [k8s-cluster](https://github.com/junjieyuan/k8s-cluster).
Managed via `kubectl` apply scripts, not Helm charts.

## Applications

| App | Description | Stack |
|-----|-------------|-------|
| **llama-server** | llama.cpp inference server (Gemma 4, Qwen 3.6) | GPU (RTX 4080), Cilium Gateway API |

## Prerequisites

- Running Kubernetes cluster (provisioned by [`k8s-cluster`](https://github.com/junjieyuan/k8s-cluster))
- GPU worker node(s) with NVIDIA GPU labels (`pci-10de.present=true`)
- Cilium CNI with Gateway API + kube-proxy replacement + LB-IPAM
- `kubectl` configured

## Usage

```bash
bash llama-server/install.sh --api-key $(uuidgen)
bash llama-server/install.sh --api-key $(uuidgen) --host llama.example.com
```

## Architecture

```
External → LB IP → Cilium Gateway (Envoy)
  → HTTPRoute (per-app hostname)
  → Service (ClusterIP)
  → Pod (GPU/CPU)
```
