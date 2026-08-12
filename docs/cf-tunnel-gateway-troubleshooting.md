# CF Tunnel → Gateway 架构迁移问题记录

## 问题 1：Tunnel 连接被 Cloudflare 拒绝

**现象**：cloudflared 日志持续报 `control stream encountered a failure while serving`，隧道无法注册。

**原因**：Tunnel ID 不正确。架构规划时写的是旧 ID `432267fd-9c8a-4ac9-bd27-23491d919b79`，实际本地管理的 Tunnel ID 是 `e6e456ae-2397-4f56-a601-e6498091e030`。

**解决方案**：更新以下文件中的 Tunnel ID：

- `cloudflared/config.yaml`
- `llama-server/dnsendpoint.yaml`
- `monitoring/dnsendpoint.yaml`
- `headlamp/dnsendpoint.yaml`
- `auth-service/base/dnsendpoint.yaml`
- `docs/cf-tunnel-gateway.md`

**教训**：本地管理的 Tunnel（`cloudflared tunnel create`）和 Dashboard 管理的 Tunnel ID 不同，迁移时需确认实际 ID。

---

## 问题 2：DNS 未开启 proxied（橙色云朵）

**现象**：DNS 记录创建成功，但 Cloudflare Dashboard 显示未 proxied。Tunnel 连接预检全部 PASS 但控制流仍然失败。

**原因**：DNSEndpoint 里写的是裸 `proxied` 键名，而 external-dns 的 Cloudflare provider 只认完整注解键名 `external-dns.alpha.kubernetes.io/cloudflare-proxied`；键名不匹配时该字段被忽略。

**解决方案**（当前做法）：代理是全局默认——k8s-cluster 的 external-dns 带 `--cloudflare-proxied` 参数（`infrastructure/external-dns/values.yaml` 的 `extraArgs.cloudflare-proxied: true`），所有 DNSEndpoint 记录默认 proxied，清单里无需声明。仅当某条记录需要 DNS-only 时，才用完整注解键名写 `"false"` 覆盖：

```yaml
---
{
  apiVersion: "externaldns.k8s.io/v1alpha1",
  kind: "DNSEndpoint",
  metadata: {
    name: "example",
  },
  spec: {
    endpoints: [{
      dnsName: "example.junjie.pro",
      recordType: "CNAME",
      providerSpecific: [{
        name: "external-dns.alpha.kubernetes.io/cloudflare-proxied",
        value: "false",
      }],
      targets: [
        "...cfargotunnel.com",
      ],
    }],
  },
}
```

**教训**：代理默认走全局参数；按记录覆盖时键名必须用完整注解键名。`value` 是字符串 `"true"`/`"false"`，需带引号（CRD schema 为 string，写成 YAML 布尔值会被 API server 拒绝）。TXT/MX/NS/SPF/SRV/LOC 类型不支持代理（CNAME 支持）。

---

## 问题 3：cilium-secrets namespace 缺失，证书无法同步到 Envoy

**现象**：Gateway 内部 TLS 握手返回 `no peer certificate available`。公网访问返回 502。操作日志报错 `cilium-operator cannot create resource "secrets" in namespace "cilium-secrets"`。

**原因**：`cilium-secrets` namespace 在某次操作中被删除。Cilium 的 Gateway API 控制器通过 SDS（Secret Discovery Service）将 TLS 证书从来源 namespace（`gateway`）同步到 `cilium-secrets`，然后 Envoy 从这里加载。namespace 不存在时整个链路中断。

**解决方案**：重新运行仓库中的 Cilium 安装/升级脚本：

```bash
kubectl kustomize --enable-helm infrastructure/cilium/ | kubectl apply -f -
```

kustomize 渲染 Cilium chart 时会自动重新创建 `cilium-secrets` namespace、相关的 Roles 和 RoleBindings。

**教训**：

- `cilium-secrets` 是 Cilium Gateway API 的核心依赖，不应手动删除
- 重新执行 kustomize apply 是恢复 Cilium 内部资源的标准方法，比手动 patch 更可靠
- 部署后还需重启 `cilium-operator` 才能触发证书同步：`kubectl rollout restart deployment/cilium-operator -n kube-system`

---

## 问题 4：证书同步后仍然 502 — TLS SNI 验证失败

**现象**：证书已同步到 `cilium-secrets`，集群内部 TLS 握手正常（`openssl s_client` 返回 `CN = *.junjie.pro`），但公网访问仍 502。cloudflared 日志：

```
x509: certificate is valid for *.junjie.pro, not cilium-gateway-gateway.gateway
```

**原因**：cloudflared 连接内部地址 `cilium-gateway-gateway.gateway:443`，但 TLS 证书的 SAN 是 `*.junjie.pro`，不包含内部 Service DNS 名。cloudflared 默认会验证 origin 服务器的证书。

**解决方案**：在 cloudflared config.yaml 的每个 ingress 规则中添加 `noTLSVerify: true`：

```yaml
---
{
  ingress: [{
    hostname: "grafana.junjie.pro",
    service: "https://cilium-gateway-gateway.gateway:443",
    originRequest: {
      noTLSVerify: true,
    },
    originServerName: "grafana.junjie.pro",
  }],
}
```

`noTLSVerify` 只在 cloudflared → Gateway 这条内网链路上跳过证书验证，公网 CF Edge → 用户浏览器的 TLS 不受影响。`originServerName` 仍然指定正确的 SNI，Gateway 据此匹配 HTTPRoute。

**教训**：cloudflared 的 `originServerName` 只影响 SNI 转发，不直接绕过证书验证。内网连接需要通过 `originRequest.noTLSVerify` 或 `originRequest.caPool` 来处理证书验证。

---

## 问题 5：CRD 管理的误判

**现象**：实施过程中发现 `DNSEndpoint` CRD 不在集群中，临时手动安装。最初将 CRD YAML 复制到仓库。

**原因**：没有意识到 Helm chart 的 `crds/` 目录已经包含了 CRD 定义，随 Kustomize `helmCharts` 一同缓存到了本地 `charts/external-dns-1.21.1/external-dns/crds/`。

**解决方案**：

- 删除本地 CRD 副本
- 部署步骤改为：先 `kubectl apply -f charts/external-dns-*/crds/`，再 `kubectl kustomize --enable-helm ... | kubectl apply -f -`
- CRD 版本始终与 Helm chart 版本匹配

**教训**：Helm chart 的 `crds/` 是 CRD 的权威来源。手动复制一份会导致版本不同步的风险。Kustomize `helmCharts` 不会自动 apply CRD，需要单独的部署步骤。

---

## 问题 6：cloudflared 认证方式选择

**背景**：cloudflared 有两种运行模式：
- Token 方式：`tunnel run --token <token>`，ingress 规则从 CF Dashboard 拉取
- Credentials 方式：`credentials.json` + `config.yaml`，ingress 规则本地管理

**决策**：选用 credentials 方式，因为目标是将 ingress 规则移入仓库声明式管理。Token 方式不能使用本地 config.yaml。

**注意事项**：

- `credentials.json` 通过 `cloudflared tunnel login` + `cloudflared tunnel create` 获取
- 该文件由 Kustomize `secretGenerator` 的 `files` 模式直接读取（不是 env 方式）
- 已加入 `.gitignore`（`credentials.json`），`credentials.json.example` 提交作为模板
- Tunnel ID 在 `config.yaml` 中硬编码（公开信息，无敏感性）

---

## 部署后的验证结果

| 服务 | URL | 状态 | 响应码 |
|------|-----|------|--------|
| Grafana | `grafana.junjie.pro` | ✅ | 302 → /login |
| Headlamp | `headlamp.junjie.pro` | ✅ | 200 |
| Auth | `auth.junjie.pro` | ✅ | 404 (API) |
| Llama | `llama.junjie.pro` | ✅ | 200 |

所有服务公网可访问，cookie 域名统一为 `*.junjie.pro`。
