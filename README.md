# k8s-apps

Kubernetes application workloads deployed on the [k8s-cluster](https://github.com/junjieyuan/k8s-cluster).

## Structure

```
gateway/            Shared Gateway + wildcard TLS (deploy first)
postgres/           PostgreSQL with persistent storage
monitoring/         Prometheus + Grafana (Helm)
llama-server/       llama.cpp inference server
auth-service/       Authentication service (multi-environment)
```

## Applications

| App | Description | Stack |
|-----|-------------|-------|
| **gateway** | Shared Cilium Gateway + wildcard TLS certificate | Cilium Gateway API, cert-manager |
| **llama-server** | llama.cpp inference server (Gemma 4, Qwen 3.6) | GPU (RTX 4080), Cilium Gateway API |
| **monitoring** | Prometheus + Grafana (kube-prometheus-stack) | Helm, Cilium Gateway API |
| **postgres** | PostgreSQL with persistent storage | StatefulSet |
| **auth-service** | Authentication service (multi-environment: dev/staging/prod) | Deployment, Cilium Gateway API |

## Prerequisites

- Running Kubernetes cluster (provisioned by [`k8s-cluster`](https://github.com/junjieyuan/k8s-cluster))
- Gateway API CRDs + Cilium CNI (from `k8s-cluster`)
- cert-manager (from `k8s-cluster`) — required for TLS; optional for HTTP-only
- GPU worker node(s) with label `feature.node.kubernetes.io/pci-10de.present=true`
- `kubectl` configured

## Usage

```bash
# 1. Shared Gateway (deploy first)
bash gateway/install.sh
bash gateway/install.sh --wildcard '*.example.com'   # custom wildcard

# 2. Infrastructure
bash postgres/install.sh --password $(uuidgen)
bash monitoring/install.sh --grafana-password $(uuidgen)

# 3. Applications
bash llama-server/install.sh --api-key $(uuidgen)
bash auth-service/k8s-setup.sh --env dev --db-pass $(uuidgen)
bash auth-service/install.sh --env dev

# Override defaults
bash monitoring/install.sh --grafana-password $(uuidgen) --host grafana.example.com --version 86.2.2
bash llama-server/install.sh --api-key $(uuidgen) --host llama.example.com
```

## Architecture

```
External → LB IP (192.168.122.200) → Cilium Gateway (shared, namespace: gateway, pinned IP)
  ├─ HTTP (port 80)  → HTTPRoute[host: llama.k8s.junjie.pro]    → llama-server
  │                  → HTTPRoute[host: grafana.k8s.junjie.pro]   → monitoring (Grafana)
  │                  → HTTPRoute[host: auth.k8s.junjie.pro]      → auth-service
  └─ HTTPS (port 443, TLS via cert-manager, wildcard: *.k8s.junjie.pro) → same

  postgres (ClusterIP, no external route) → accessed internally by auth-service
```
