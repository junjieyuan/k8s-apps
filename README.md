# k8s-apps

Kubernetes application workloads running on the k8s-cluster.

## Applications

- **llama-server** — llama.cpp inference server with NVIDIA GPU, serving
  Gemma and Qwen models via OpenAI-compatible API.

## Prerequisites

- Running k8s cluster (see `k8s-cluster` repo)
- GPU worker node(s) with NVIDIA GPU Operator installed
- `kubectl` configured with cluster access

## Usage

```bash
# Deploy llama-server
bash llama-server/install.sh --api-key $(uuidgen)

# With custom hostname
bash llama-server/install.sh --api-key $(uuidgen) --host llama.example.com
```
