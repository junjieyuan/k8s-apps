# k8s-apps

Kubernetes application workloads deployed on the [k8s-cluster](https://github.com/junjieyuan/k8s-cluster).
Managed via `kubectl` apply scripts, not Helm charts.

## Applications

- **llama-server** — llama.cpp inference server with NVIDIA GPU (RTX 4080).
  Serves Gemma 4 and Qwen 3.6 models via OpenAI-compatible API.
  Exposed through Cilium Gateway API with HTTPRoute.

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
External → LB 192.168.122.200:8081 → Cilium Gateway (Envoy)
  → HTTPRoute (host: llama.k8s.junjie.pro)
  → llama-server ClusterIP :8080
  → Pod (GPU, RTX 4080)
```
