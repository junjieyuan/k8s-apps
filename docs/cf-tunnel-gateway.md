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
cloudflared pod
      │  https://cilium-gateway-gateway.gateway:443
      │  TLS SNI = <service>.junjie.pro (originServerName)
      ▼
┌───────────────────────────────────────────────────────────┐
│  Cilium Gateway  (namespace: gateway)                     │
│                                                           │
│  Listener: https (port 443, TLS *.junjie.pro)             │
│    ← cloudflared / 局域网直连流量                         │
│                                                           │
│  TLS 证书: cert-manager / letsencrypt-prod (DNS-01)       │
│  固定 IP: 192.168.200.200                                 │
└──────────┬────────────────────────────────────────────────┘
           │ HTTPRoute[host: *.junjie.pro]
    ┌──────┴─────────────────────────────────────────────────────┐
    │  各服务 hostname → 对应 Service                            │
    └────────────────────────────────────────────────────────────┘
```

## Cookie 域名

后端服务将 cookie scope 设置为 `.junjie.pro`。

**为什么需要 `originServerName`**：cloudflared 连接 Gateway 时指定 `originServerName: <service>.junjie.pro`，Gateway 根据 TLS SNI 匹配正确的 HTTPRoute。后端服务收到的 Host 头是 `<service>.junjie.pro`，与浏览器地址栏一致，cookie 写入和读取不再出现域名不匹配的问题。

## 可插拔 Cloudflare Tunnel

Tunnel 是可替换的前端模块，当前启用：所有流量经 Tunnel 进入集群。
Gateway + HTTPRoute 层始终是路由的唯一权威来源。

Gateway IP `192.168.200.200` 已写在 spec 中但目前没有路由。

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

`gateway/gateway.yaml`、所有 `httproute.yaml`、`gateway/certificate.yaml`
（wildcard）在两种模式下完全相同；HTTPRoute 流量分割（金丝雀/蓝绿）
两种模式均可用。

## DNS 管理

external-dns 运行在 `k8s-cluster` 仓库中配置，provider 为 Cloudflare，
当前使用 `--source=crd`：监听 `DNSEndpoint` 资源，忽略 `gateway-httproute`。
每个服务目录的 `dnsendpoint.yaml` 声明 CNAME 指向 Tunnel ID：不暴露真实 IP，
启用 CF proxied 模式（橙色云朵）。

## Cloudflare Tunnel 配置

### 认证方式：credentials.json + config.yaml

采用 credentials 文件方式，ingress 规则在仓库内声明式管理。

Tunnel ID：`e6e456ae-2397-4f56-a601-e6498091e030`

### config.yaml（ConfigMap 挂载）

以仓库内 `cloudflared/config.yaml` 为准：所有 hostname 规则路由到同一个
Gateway Service（`cilium-gateway-gateway.gateway`），通过 TLS SNI
（`originServerName`）区分不同服务、匹配正确的 HTTPRoute。

### 凭证管理

- `TUNNEL_ID`：硬编码在 `config.yaml` 中（公开信息，无敏感性）
- `credentials.json`：通过 `cloudflared tunnel login` + `cloudflared tunnel create` 获取，包含 account 级别的 API 凭证。通过 Kustomize `secretGenerator` 从分发的 `credentials.json` 直接生成 Secret（`files` 模式），无需 `.env`。

## Gateway 配置

单 `https` listener（443，cert-manager 签发 `*.junjie.pro` 通配证书）。

`spec.addresses` 固定为 `192.168.200.200`，保证 Gateway 删除重建后 IP 不变。

## 参考

- 集群基础设施配置（external-dns）：`k8s-cluster` 仓库
  `infrastructure/external-dns/`
