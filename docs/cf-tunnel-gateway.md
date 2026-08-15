# 架构设计

## 设计原则

- **双入口、单路由层** —— Cloudflare Tunnel 和局域网直连共享同一套 Cilium Gateway + HTTPRoute 配置。
- **可插拔入口** —— Tunnel 是可选的附加模块，Gateway 是稳定的路由核心。
- **一切在仓库里** —— Tunnel 入口规则（`ConfigMap`）、DNS 记录（`DNSEndpoint`）、HTTP 路由（`HTTPRoute`）全部声明式管理、版本控制。
- **统一域名** —— 所有服务使用 `*.junjie.pro`，解决跨服务 cookie 域名不一致问题。

## 流量路径

```
Cloudflare Edge (TLS *.junjie.pro)
      │
      ▼
Cloudflare Tunnel (encrypted)
      │
      ▼
cloudflared pod (3 replicas)
      │  https://cilium-gateway-gateway.gateway:443
      │  TLS SNI = <service>.junjie.pro (originServerName)
      ▼
┌───────────────────────────────────────────────────────────┐
│  Cilium Gateway  (namespace: gateway)                     │
│                                                           │
│  Listener: https (port 443, TLS *.junjie.pro)              │
│    ← cloudflared / 局域网直连流量                           │
│                                                           │
│  TLS 证书: cert-manager / letsencrypt-prod (DNS-01)       │
│  固定 IP: 192.168.200.200                                 │
└──────────┬────────────────────────────────────────────────┘
           │ HTTPRoute[host: *.junjie.pro]
    ┌──────┴──────────────────────────────────────────────┐
    │  Backend Services                                   │
    │    • llama.junjie.pro              → llama-server:9931             │
    │    • grafana.junjie.pro → kube-prometheus-stack-grafana:80 │
    │    • headlamp.junjie.pro → headlamp:80               │
    │    • keycloak.junjie.pro → keycloak:8080               │
    └─────────────────────────────────────────────────────┘
```

## 流量来源

| 来源 | → | 入口 | → | Gateway 监听器 | → | 目标 |
|------|---|------|---|---------------|-----|------|
| 公网 | → | CF Edge → Tunnel → cloudflared | → | `https` port 443 | → | Service |
| 局域网（将来） | → | 直连 | → | `https` port 443 | → | Service |

## Cookie 域名

所有服务共享 `*.junjie.pro`。HTTPRoute 的 hostname 为 `llama.junjie.pro`、`grafana.junjie.pro` 等。后端服务将 cookie scope 设置为 `.junjie.pro`，避免跨服务 cookie 问题。

**为什么需要 `originServerName`**：cloudflared 连接 Gateway 时指定 `originServerName: <service>.junjie.pro`，Gateway 根据 TLS SNI 匹配正确的 HTTPRoute。后端服务收到的 Host 头是 `<service>.junjie.pro`，与浏览器地址栏一致，cookie 写入和读取不再出现域名不匹配的问题。

## 可插拔 Cloudflare Tunnel

Tunnel 是可替换的前端模块。Gateway + HTTPRoute 层始终是路由的唯一权威来源。

### Tunnel 模式（当前）

```
用户 → CF Edge → Tunnel → cloudflared → Gateway → HTTPRoute → Service
```

所有流量通过 Tunnel 进入集群。DNS 由 `DNSEndpoint` CR 管理（external-dns `--source=crd`），生成 CNAME 记录指向 `<tunnel-id>.cfargotunnel.com`。Gateway IP `192.168.200.200` 已写在 spec 中但目前没有路由。

### 直连模式（将来）

```
用户 → Gateway LB IP (192.168.200.200) → HTTPRoute → Service
```

**切换步骤**：

1. 在宿主机上添加 `192.168.200.0/24` 的路由
2. 停止 cloudflared：编辑 `cloudflared/deployment.yaml` 将 `replicas:` 改为 `0`，提交后
   `kubectl apply -k cloudflared/`（副本数只能改在 manifest 里，禁止 `kubectl scale`）。
   若要彻底移除，先 `kubectl delete -k cloudflared/`（manifest 仍在仓库时），再删除
   `cloudflared/` 下的 manifest 并提交
3. external-dns source 从 `crd` 改为 `gateway-httproute`（HTTPRoute hostname 自动生成 A 记录指向 Gateway status 中的 IP）
4. 删除 `DNSEndpoint` CR（或保留不启用）

### 不变的部分

| 组件 | Tunnel 模式 | 直连模式 |
|------|------------|----------|
| `gateway/gateway.yaml` | 相同 | 相同 |
| 所有 `httproute.yaml` | 相同 | 相同 |
| `gateway/certificate.yaml`（wildcard） | 相同 | 相同 |
| HTTPRoute 流量分割（金丝雀/蓝绿） | 可用 | 可用 |

### 变化的部分

| 组件 | Tunnel 模式 | 直连模式 |
|------|------------|----------|
| `cloudflared/` | 运行中 | 停止/移除 |
| DNS 记录 | CNAME → tunnel-id.cfargotunnel.com | A → Gateway status IP |
| external-dns `--source` | `crd` | `gateway-httproute` |
| 宿主机路由到 192.168.200.0/24 | 不需要 | 需要 |

## DNS 管理

external-dns 运行在 `k8s-cluster` 仓库中配置，provider 为 Cloudflare。

### Tunnel 模式

external-dns 使用 `--source=crd`，监听 `DNSEndpoint` 资源，忽略 `gateway-httproute`。

每个服务创建一个 `DNSEndpoint`：

```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: <service>
spec:
  endpoints:
    - dnsName: <service>.junjie.pro
      recordType: CNAME
      targets:
        - e6e456ae-2397-4f56-a601-e6498091e030.cfargotunnel.com
```

CNAME 目标是 Tunnel ID（公开信息）。不暴露真实 IP，启用 CF proxied 模式（橙色云朵）。

### 直连模式

external-dns source 改为 `gateway-httproute`。HTTPRoute 的 hostname 自动生成 A 记录，指向 Gateway `status.addresses` 中的 IP（即 `192.168.200.200`）。不需要手动写死 IP。

## Cloudflare Tunnel 配置

### 认证方式：credentials.json + config.yaml

采用 credentials 文件方式，ingress 规则在仓库内声明式管理，不再依赖 Cloudflare Dashboard。

Tunnel ID：`e6e456ae-2397-4f56-a601-e6498091e030`

### config.yaml（ConfigMap 挂载）

```yaml
tunnel: e6e456ae-2397-4f56-a601-e6498091e030
credentials-file: /etc/cloudflared/creds/credentials.json
ingress:
  - hostname: llama.junjie.pro
    service: https://cilium-gateway-gateway.gateway:443
    originRequest:
      noTLSVerify: true
    originServerName: llama.junjie.pro
  - hostname: headlamp.junjie.pro
    service: https://cilium-gateway-gateway.gateway:443
    originRequest:
      noTLSVerify: true
    originServerName: headlamp.junjie.pro
  - hostname: grafana.junjie.pro
    service: https://cilium-gateway-gateway.gateway:443
    originRequest:
      noTLSVerify: true
    originServerName: grafana.junjie.pro
  - service: http_status:404
```

所有服务路由到同一个 Gateway Service（`cilium-gateway-gateway.gateway`），通过 TLS SNI（`originServerName`）区分不同服务。

### 凭证管理

- `TUNNEL_ID`：硬编码在 `config.yaml` 中（公开信息，无敏感性）
- `credentials.json`：通过 `cloudflared tunnel login` + `cloudflared tunnel create` 获取，包含 account 级别的 API 凭证。通过 Kustomize `secretGenerator` 从分发的 `credentials.json` 直接生成 Secret（`files` 模式），无需 `.env`。

## Gateway 配置

单 listener 设计（不再保留 HTTP listener）：

| Listener | Port | Protocol | TLS | 流量来源 |
|----------|------|----------|-----|---------|
| `https` | 443 | HTTPS | `*.junjie.pro`（cert-manager） | cloudflared / 局域网 |

`spec.addresses` 固定为 `192.168.200.200`，保证 Gateway 删除重建后 IP 不变。

## 旧架构 vs 新架构

| 方面 | 旧架构 | 新架构 |
|------|--------|--------|
| 域名 | `*.k8s.junjie.pro` | `*.junjie.pro` |
| Tunnel 认证 | Token（`TUNNEL_TOKEN` 环境变量） | Credentials 文件（`credentials.json`） |
| Tunnel 路由 | Cloudflare Dashboard 手动配置 | 仓库内 `config.yaml` ConfigMap |
| DNS 管理 | external-dns `gateway-httproute` source | external-dns `crd` source + `DNSEndpoint` CR |
| Gateway listeners | `http` (80) + `https` (443) | 仅 `https` (443) |
| Tunnel 流量 | 直连各 Service（绕过 Gateway） | 经过 Gateway → HTTPRoute → Service |
| Cookie 域名 | 不一致（`*.junjie.pro` vs `*.k8s.junjie.pro`） | 一致（统一 `*.junjie.pro`） |

## 迁移步骤

迁移策略：**先建后拆**。Gateway/证书先部署好，验证通过后再切 cloudflared 和 DNS。

> **历史记录**：以下步骤记录了 2026-07 从 Token 认证迁移到 credentials 认证的实际操作，仅作存档。
> 当前所有集群资源变更必须以 manifest 为准（见 AGENTS.md 漂移规则）：副本数改在
> `deployment.yaml` 里再 apply，移除应用先 `kubectl delete -k <app>/` 再删 manifest；禁止用
> `kubectl scale/edit/patch/delete` 直接操作 manifest 管理的资源。

### 步骤 1：更新证书

```bash
# 修改 gateway/certificate.yaml：*.k8s.junjie.pro → *.junjie.pro
kubectl apply -k gateway/
# 验证证书签发成功
kubectl get certificate gateway-tls -n gateway -w
```

### 步骤 2：更新 Gateway

```bash
# 修改 gateway/gateway.yaml：去掉 port 80 listener
kubectl apply -k gateway/
```

### 步骤 3：更新所有 HTTPRoute hostname

将所有 `httproute.yaml` 中的 hostname 从 `*.k8s.junjie.pro` 改为 `*.junjie.pro`，然后逐服务 apply：

```bash
kubectl apply -k llama-server/
kubectl kustomize --enable-helm monitoring/ | kubectl apply -f -
kubectl kustomize --enable-helm headlamp/ | kubectl apply -f -
```

步骤 1-3 不影响现有流量（旧 Tunnel 直连 Service，不经过 Gateway）。

### 步骤 4：更新 external-dns（CRD + source）

确保 `k8s-cluster` 仓库中 external-dns values.yaml 的 sources 已改为 `crd`。

CRD 随 chart 版本走，不保存本地副本：

```bash
cd k8s-cluster
infrastructure/external-dns/deploy.sh
```

此时旧的 `*.k8s.junjie.pro` DNS 记录会被 external-dns 清理。

### 步骤 5：创建 DNSEndpoint CR

在每个服务目录下新建 `dnsendpoint.yaml`，CNAME 指向 `e6e456ae-2397-4f56-a601-e6498091e030.cfargotunnel.com`，然后 apply：

```bash
kubectl apply -k llama-server/
kubectl kustomize --enable-helm monitoring/ | kubectl apply -f -
kubectl kustomize --enable-helm headlamp/ | kubectl apply -f -
```

external-dns 会自动在 Cloudflare 创建 CNAME 记录。等待 DNS 生效（通常 1-5 分钟）。

### 步骤 6：重建 cloudflared

**前提：** 将 Tunnel 的 `credentials.json` 放到 `cloudflared/` 目录下。该文件由 `cloudflared tunnel login` + `cloudflared tunnel create` 生成，如果 Tunnel 已存在但文件丢失，可通过 Cloudflare Dashboard → Zero Trust → Networks → Tunnels 重新下载。

```bash
# 当时的遗留清理：旧 Token 部署（deployment + cf-tunnel-token secret）迁移前不在仓库
# manifest 里，直接删除是一次性历史操作；今天的资源都由 manifest 管理，移除应先
# kubectl delete -k <app>/ 再删 manifest，不要直接 kubectl delete deploy/secret。
kubectl delete deploy cloudflared -n cloudflared
kubectl delete secret cf-tunnel-token -n cloudflared

# 部署新的 cloudflared（credentials + config.yaml 方式）
kubectl apply -k cloudflared/
```

### 步骤 7：验证

```bash
# 检查 cloudflared 日志，确认连接成功
kubectl logs -n cloudflared deployment/cloudflared

# 从外部访问各服务
curl -I https://grafana.junjie.pro
curl -I https://llama.junjie.pro
curl -I https://headlamp.junjie.pro
```

### 步骤 8：清理

- 在 Cloudflare Dashboard 中删除旧的 Tunnel 路由规则（`*.k8s.junjie.pro` 相关）
- 确认 Cloudflare DNS 中没有残留的 `*.k8s.junjie.pro` 记录

## 文件布局

```
k8s-apps/
  docs/
    architecture.md          本文件
  gateway/                   共享 Gateway（最先部署）
    kustomization.yaml
    namespace.yaml
    gateway.yaml             单 listener (https:443)，固定 IP，无路由
    certificate.yaml         *.junjie.pro wildcard
  cloudflared/               Cloudflare Tunnel 客户端
    kustomization.yaml
    namespace.yaml
    deployment.yaml          ConfigMap 挂载 + credentials 文件
    config.yaml              隧道入口规则
    credentials.json.example credentials 模板
  llama-server/
    httproute.yaml           hostname: llama.junjie.pro
    dnsendpoint.yaml         CNAME → tunnel
  headlamp/
    httproute.yaml           hostname: headlamp.junjie.pro
    dnsendpoint.yaml         CNAME → tunnel
  monitoring/
    httproute.yaml           hostname: grafana.junjie.pro
    dnsendpoint.yaml         CNAME → tunnel
```

## 参考

- 集群基础设施配置：`k8s-cluster` 仓库 `infrastructure/external-dns/`
- Tunnel ID：`e6e456ae-2397-4f56-a601-e6498091e030`
- Gateway 固定 IP：`192.168.200.200`
