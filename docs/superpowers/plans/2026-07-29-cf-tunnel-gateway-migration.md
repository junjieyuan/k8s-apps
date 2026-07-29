# CF Tunnel → Gateway 架构迁移实施计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 将入口架构从"CF Tunnel 直连 Service"迁移到"CF Tunnel → Gateway → Service"，域名从 `*.k8s.junjie.pro` 统一为 `*.junjie.pro`，Tunnel 配置从 CF Dashboard 迁移到仓库声明式管理。

**Architecture:** 单 Gateway (TLS *.junjie.pro, IP 192.168.200.200) 作为所有流量的统一入口。cloudflared 通过 `originServerName` 将流量转发到 Gateway，Gateway 根据 SNI 匹配 HTTPRoute。DNS 通过 `DNSEndpoint` CR + external-dns `crd` source 管理。

**Tech Stack:** Kubernetes, Cilium Gateway API, cert-manager, Cloudflare Tunnel, external-dns, Kustomize

## Global Constraints

- 域名统一为 `*.junjie.pro`（不再使用 `*.k8s.junjie.pro`）
- Gateway IP 固定为 `192.168.200.200`
- Tunnel ID: `e6e456ae-2397-4f56-a601-e6498091e030`
- external-dns 配置在 `k8s-cluster` 仓库
- 允许中断（homelab 环境）
- 遵循项目 conventions：Kustomize 部署、secretGenerator 管理机密、bash 脚本、Conventional Commits
- cloudflared 使用 `credentials.json` + `config.yaml` 方式，不再使用 Token 方式

---

### Task 1: 更新 Gateway 证书域名

**Files:**
- Modify: `gateway/certificate.yaml`

- [ ] **Step 1: 修改证书 dnsNames**

将 `gateway/certificate.yaml` 中的 `*.k8s.junjie.pro` 改为 `*.junjie.pro`：

```yaml
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: gateway-tls
spec:
  secretName: gateway-tls
  issuerRef:
    name: letsencrypt-prod
    kind: ClusterIssuer
  dnsNames:
    - "*.junjie.pro"
```

- [ ] **Step 2: 部署并等待证书签发**

```bash
kubectl apply -k gateway/
kubectl get certificate gateway-tls -n gateway -w
```

等待状态变成 `READY: True`，确认新证书已签发。

此步骤不影响现有流量（旧 Tunnel 不经过 Gateway）。

- [ ] **Step 3: Commit**

```bash
git add gateway/certificate.yaml
git commit -m "feat(gateway): switch wildcard certificate to *.junjie.pro"
```

---

### Task 2: 更新 Gateway 监听器

**Files:**
- Modify: `gateway/gateway.yaml`

- [ ] **Step 1: 移除 HTTP listener，保留 HTTPS only**

将 `gateway/gateway.yaml` 改为单 listener：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: gateway
spec:
  gatewayClassName: cilium
  addresses:
    - type: IPAddress
      value: 192.168.200.200
  listeners:
    - name: https
      protocol: HTTPS
      port: 443
      tls:
        mode: Terminate
        certificateRefs:
          - name: gateway-tls
      allowedRoutes:
        namespaces:
          from: All
```

- [ ] **Step 2: 部署**

```bash
kubectl apply -k gateway/
```

- [ ] **Step 3: Commit**

```bash
git add gateway/gateway.yaml
git commit -m "feat(gateway): simplify to single HTTPS listener on 443"
```

---

### Task 3: 更新所有 HTTPRoute hostname

**Files:**
- Rename: `llama-server/httproute.yaml` → `llama-server/openai-api-private-httproute.yaml`
- Modify: `llama-server/kustomization.yaml`
- Modify: `monitoring/httproute.yaml`
- Modify: `headlamp/httproute.yaml`
- Modify: `auth-service/base/httproute.yaml`

- [ ] **Step 1: llama-server — 重命名并更新 hostname**

将 `llama-server/httproute.yaml` 重命名为 `llama-server/openai-api-private-httproute.yaml`，内容改为：

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llama-server
spec:
  parentRefs:
    - name: gateway
      namespace: gateway
  hostnames:
    - openai-api-private.junjie.pro
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: llama-server
          port: 8080
```

- [ ] **Step 2: llama-server — 更新 kustomization.yaml**

修改 `llama-server/kustomization.yaml`，将 `resources` 中的 `httproute.yaml` 改为 `openai-api-private-httproute.yaml`

- [ ] **Step 3: monitoring — 更新 hostname**

修改 `monitoring/httproute.yaml`，将 `grafana.k8s.junjie.pro` 改为 `grafana.junjie.pro`

- [ ] **Step 4: headlamp — 更新 hostname**

修改 `headlamp/httproute.yaml`，将 `headlamp.k8s.junjie.pro` 改为 `headlamp.junjie.pro`

- [ ] **Step 5: auth-service — 更新 hostname**

修改 `auth-service/base/httproute.yaml`，将 `auth.k8s.junjie.pro` 改为 `auth.junjie.pro`

- [ ] **Step 6: 部署所有 HTTPRoute**

```bash
kubectl apply -k llama-server/
kubectl apply -k auth-service/overlays/dev/
kubectl kustomize --enable-helm monitoring/ | kubectl apply -f -
kubectl kustomize --enable-helm headlamp/ | kubectl apply -f -
```

此步骤不影响现有流量（旧 Tunnel 直连 Service，不经过 Gateway）。

- [ ] **Step 7: Commit**

```bash
git rm llama-server/httproute.yaml
git add llama-server/openai-api-private-httproute.yaml llama-server/kustomization.yaml
git add monitoring/httproute.yaml headlamp/httproute.yaml auth-service/base/httproute.yaml
git commit -m "feat: migrate all HTTPRoutes from *.k8s.junjie.pro to *.junjie.pro"
```

---

### Task 4: 更新外部 DNS source（k8s-cluster 仓库）

**Files:**
- Modify: `k8s-cluster/infrastructure/external-dns/values.yaml`

- [ ] **Step 1: 切换 source 为 crd**

修改 `k8s-cluster/infrastructure/external-dns/values.yaml`，将 sources 从 `gateway-httproute, gateway-grpcroute` 改为 `crd`：

```yaml
provider:
  name: cloudflare

sources:
  - crd

domainFilters:
  - junjie.pro

policy: sync
txtOwnerId: k8s-gw-junjie
interval: 5m
logLevel: info

# CF_API_TOKEN injected via env — secret managed by kustomize secretGenerator.
env:
  - name: CF_API_TOKEN
    valueFrom:
      secretKeyRef:
        name: cloudflare-api-token
        key: api-token
```

- [ ] **Step 2: 部署**

```bash
cd k8s-cluster
kubectl kustomize --enable-helm infrastructure/external-dns/ | kubectl apply -f -
```

此时旧的 `*.k8s.junjie.pro` DNS 记录会被 external-dns 清理。

- [ ] **Step 3: Commit**

```bash
cd k8s-cluster
git add infrastructure/external-dns/values.yaml
git commit -m "feat(external-dns): switch source from gateway-httproute to crd for tunnel DNS"
```

---

### Task 5: 创建 DNSEndpoint CR

**Files:**
- Create: `llama-server/openai-api-private-dnsendpoint.yaml`
- Create: `monitoring/dnsendpoint.yaml`
- Create: `headlamp/dnsendpoint.yaml`
- Create: `auth-service/base/dnsendpoint.yaml`
- Modify: `llama-server/kustomization.yaml`
- Modify: `monitoring/kustomization.yaml`
- Modify: `headlamp/kustomization.yaml`
- Modify: `auth-service/base/kustomization.yaml`

- [ ] **Step 1: llama-server — 创建 DNSEndpoint**

新建 `llama-server/openai-api-private-dnsendpoint.yaml`：

```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: openai-api-private
spec:
  endpoints:
    - dnsName: openai-api-private.junjie.pro
      recordType: CNAME
      targets:
        - e6e456ae-2397-4f56-a601-e6498091e030.cfargotunnel.com
      providerSpecific:
        - name: proxied
          value: "true"
```

- [ ] **Step 2: llama-server — 更新 kustomization.yaml**

在 `llama-server/kustomization.yaml` 的 `resources` 中添加 `openai-api-private-dnsendpoint.yaml`

- [ ] **Step 3: monitoring — 创建 DNSEndpoint**

新建 `monitoring/dnsendpoint.yaml`：

```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: grafana
spec:
  endpoints:
    - dnsName: grafana.junjie.pro
      recordType: CNAME
      targets:
        - e6e456ae-2397-4f56-a601-e6498091e030.cfargotunnel.com
      providerSpecific:
        - name: proxied
          value: "true"
```

- [ ] **Step 4: monitoring — 更新 kustomization.yaml**

在 `monitoring/kustomization.yaml` 的 `resources` 中添加 `dnsendpoint.yaml`

- [ ] **Step 5: headlamp — 创建 DNSEndpoint**

新建 `headlamp/dnsendpoint.yaml`：

```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: headlamp
spec:
  endpoints:
    - dnsName: headlamp.junjie.pro
      recordType: CNAME
      targets:
        - e6e456ae-2397-4f56-a601-e6498091e030.cfargotunnel.com
      providerSpecific:
        - name: proxied
          value: "true"
```

- [ ] **Step 6: headlamp — 更新 kustomization.yaml**

在 `headlamp/kustomization.yaml` 的 `resources` 中添加 `dnsendpoint.yaml`

- [ ] **Step 7: auth-service — 创建 DNSEndpoint**

新建 `auth-service/base/dnsendpoint.yaml`：

```yaml
apiVersion: externaldns.k8s.io/v1alpha1
kind: DNSEndpoint
metadata:
  name: auth
spec:
  endpoints:
    - dnsName: auth.junjie.pro
      recordType: CNAME
      targets:
        - e6e456ae-2397-4f56-a601-e6498091e030.cfargotunnel.com
      providerSpecific:
        - name: proxied
          value: "true"
```

- [ ] **Step 8: auth-service — 更新 kustomization.yaml**

在 `auth-service/base/kustomization.yaml` 的 `resources` 中添加 `dnsendpoint.yaml`

- [ ] **Step 9: 部署所有 DNSEndpoint**

```bash
kubectl apply -k llama-server/
kubectl apply -k auth-service/overlays/dev/
kubectl kustomize --enable-helm monitoring/ | kubectl apply -f -
kubectl kustomize --enable-helm headlamp/ | kubectl apply -f -
```

等待 1-5 分钟让 external-dns 在 Cloudflare 创建 DNS 记录。验证：

```bash
kubectl get dnsendpoint -A
```

- [ ] **Step 10: Commit**

```bash
git add llama-server/openai-api-private-dnsendpoint.yaml llama-server/kustomization.yaml
git add monitoring/dnsendpoint.yaml monitoring/kustomization.yaml
git add headlamp/dnsendpoint.yaml headlamp/kustomization.yaml
git add auth-service/base/dnsendpoint.yaml auth-service/base/kustomization.yaml
git commit -m "feat: add DNSEndpoint CRs for all services with CNAME to tunnel"
```

---

### Task 6: 重建 Cloudflared（credentials + config.yaml）

**Files:**
- Create: `cloudflared/config.yaml`
- Modify: `cloudflared/deployment.yaml`
- Modify: `cloudflared/kustomization.yaml`
- Modify: `cloudflared/.env.example`

- [ ] **Step 1: 创建 Tunnel 入口配置**

新建 `cloudflared/config.yaml`（非敏感信息，直接提交）：

```yaml
tunnel: e6e456ae-2397-4f56-a601-e6498091e030
credentials-file: /etc/cloudflared/creds/credentials.json
ingress:
  - hostname: openai-api-private.junjie.pro
    service: https://cilium-gateway-gateway.gateway:443
    originServerName: openai-api-private.junjie.pro
  - hostname: headlamp.junjie.pro
    service: https://cilium-gateway-gateway.gateway:443
    originServerName: headlamp.junjie.pro
  - hostname: auth.junjie.pro
    service: https://cilium-gateway-gateway.gateway:443
    originServerName: auth.junjie.pro
  - hostname: grafana.junjie.pro
    service: https://cilium-gateway-gateway.gateway:443
    originServerName: grafana.junjie.pro
  - service: http_status:404
```

- [ ] **Step 2: 更新 Deployment**

修改 `cloudflared/deployment.yaml`，改为挂载 config 和 credentials：

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: cloudflared
  labels:
    app: cloudflared
spec:
  replicas: 3
  selector:
    matchLabels:
      app: cloudflared
  template:
    metadata:
      labels:
        app: cloudflared
    spec:
      affinity:
        podAntiAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 100
              podAffinityTerm:
                labelSelector:
                  matchLabels:
                    app: cloudflared
                topologyKey: kubernetes.io/hostname
      containers:
        - name: cloudflared
          image: docker.io/cloudflare/cloudflared
          args:
            - tunnel
            - --config
            - /etc/cloudflared/config/config.yaml
            - --metrics
            - 0.0.0.0:2000
            - run
          ports:
            - containerPort: 2000
              name: metrics
          resources:
            requests:
              cpu: 50m
              memory: 64Mi
            limits:
              memory: 256Mi
          livenessProbe:
            httpGet:
              path: /ready
              port: metrics
          volumeMounts:
            - name: config
              mountPath: /etc/cloudflared/config
              readOnly: true
            - name: creds
              mountPath: /etc/cloudflared/creds
              readOnly: true
      volumes:
        - name: config
          configMap:
            name: cloudflared-config
        - name: creds
          secret:
            secretName: cloudflared-credentials
```

关键变化：
- args 从 `tunnel --metrics ... run` 改为 `tunnel --config /etc/cloudflared/config/config.yaml --metrics ... run`
- 移除 `envFrom`（不再需要 TUNNEL_TOKEN 环境变量）
- 添加 `volumeMounts` 和 `volumes`

- [ ] **Step 3: 更新 kustomization.yaml**

修改 `cloudflared/kustomization.yaml`：

```yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: cloudflared
resources:
  - namespace.yaml
  - deployment.yaml
images:
  - name: docker.io/cloudflare/cloudflared
    newTag: "2026.7.3"
configMapGenerator:
  - name: cloudflared-config
    files:
      - config.yaml
secretGenerator:
  - name: cloudflared-credentials
    files:
      - credentials.json
```

- [ ] **Step 4: 更新 .env.example**

将 `cloudflared/.env.example` 替换为 `cloudflared/credentials.json.example`：

```json
{
  "AccountTag": "<your-cloudflare-account-tag>",
  "TunnelSecret": "<your-tunnel-secret>",
  "TunnelID": "e6e456ae-2397-4f56-a601-e6498091e030"
}
```

删除 `cloudflared/.env.example`。

- [ ] **Step 5: 删除旧 cloudflared 并部署新的**

```bash
# 删除旧资源
kubectl delete deploy cloudflared -n cloudflared
kubectl delete secret cf-tunnel-token -n cloudflared

# 部署新的（注意：需要先准备好 credentials.json 文件）
kubectl apply -k cloudflared/
```

**重要**：部署前必须确保 `cloudflared/credentials.json` 文件已创建（gitignored），内容为 Cloudflare Tunnel 的实际凭证。

- [ ] **Step 6: 检查日志确认连接成功**

```bash
kubectl logs -n cloudflared deployment/cloudflared
```

预期看到 `Registered tunnel connection` 等成功信息。

- [ ] **Step 7: Commit**

```bash
git rm cloudflared/.env.example
git add cloudflared/config.yaml cloudflared/deployment.yaml cloudflared/kustomization.yaml cloudflared/credentials.json.example
git commit -m "feat(cloudflared): switch from token to credentials+config for declarative tunnel ingress"
```

---

### Task 7: 验证

- [ ] **Step 1: 从外部访问各服务**

```bash
curl -I https://grafana.junjie.pro
curl -I https://openai-api-private.junjie.pro
curl -I https://headlamp.junjie.pro
curl -I https://auth.junjie.pro
```

确认返回 HTTP 2xx/3xx，cookie 域名匹配 `*.junjie.pro`。

- [ ] **Step 2: 检查 HTTPRoute 状态**

```bash
kubectl get httproute -A
```

确认所有 Route 的 `Accepted` 和 `ResolvedRefs` 条件为 `True`。

- [ ] **Step 3: 检查 Gateway 状态**

```bash
kubectl get gateway -n gateway
```

确认 Gateway 状态为 `Accepted` 和 `Programmed`。

---

### Task 8: 清理

- [ ] **Step 1: 删除旧架构文档**

```bash
git rm ARCHITECTURE.md
```

`docs/cf-tunnel-gateway.md` 已包含完整架构文档。

- [ ] **Step 2: 清理 Cloudflare Dashboard**

在 CF Dashboard → Zero Trust → Networks → Tunnels 中，删除旧的 Tunnel 路由规则（指向 `*.k8s.junjie.pro` 或直连 Service 的规则）。

- [ ] **Step 3: 验证 Cloudflare DNS**

在 CF Dashboard DNS 页面确认：
- 所有 `*.junjie.pro` 有 CNAME 记录指向 `<tunnel-id>.cfargotunnel.com`
- 没有残留的 `*.k8s.junjie.pro` 记录

- [ ] **Step 4: Commit 清理**

```bash
git add ARCHITECTURE.md docs/cf-tunnel-gateway.md
git commit -m "chore: remove old ARCHITECTURE.md, superseded by docs/cf-tunnel-gateway.md"
```

---

### 回滚预案

如需回滚，按相反顺序执行：

1. 恢复旧 cloudflared（Token 方式）— 从 git history 恢复 `cloudflared/` 目录
2. 删除 DNSEndpoint CR
3. external-dns source 切回 `gateway-httproute, gateway-grpcroute`
4. HTTPRoute hostname 改回 `*.k8s.junjie.pro`
5. Gateway 恢复双 listener（http + https）
6. 证书改回 `*.k8s.junjie.pro`
7. 恢复 CF Dashboard 上的 Tunnel 路由规则
