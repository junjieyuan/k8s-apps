# Qwen3-TTS TTS 微服务架构计划（vLLM-Omni）

> **For agentic workers:** 任务按顺序执行，逐步勾选 checkbox。本计划是架构探索的产出：
> 已确认"直接用官方容器加 app"路线，任务清单是可执行实施步骤。

**Goal:** 在现有集群上用 Qwen3-TTS + vLLM 系栈搭一个 TTS 微服务，对外提供
OpenAI 兼容 `/v1/audio/speech` API。认证不在本计划范围（Cloudflare tunnel
层已有 CF Access / token 方案）。

**Architecture:** GPU 节点上单 Deployment 跑 `vllm/vllm-omni` 官方镜像，
vllm-omni 两阶段管线（talker → code2wav）共享同一张 RTX 4080；模型只读
来自 GPU 节点共享 HF cache（`/opt/models/huggingface`，与 llama-server /
comfyui 同一 host 路径）；入口走现有 CF tunnel → Gateway → HTTPRoute
（`tts.junjie.pro`）；默认 `replicas: 0`，与 llama-server / comfyui 构成
GPU 互斥（manifest 改 replicas 切换）。

**Tech Stack:** vLLM 0.28 + vLLM-Omni 0.28（镜像 `vllm/vllm-omni:v0.28.0`），
模型 `Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice`，Kustomize（KYAML），
Gateway API（Cilium），Cloudflare Tunnel。

## 决策：直接用容器，在本项目加 app；不定制开发容器/服务

**推荐路线 A（本计划实施）**：直接用官方现成镜像
[`vllm/vllm-omni`](https://hub.docker.com/r/vllm/vllm-omni)（基于官方
`vllm/vllm-openai:v0.28.0`，上层加装 vllm-omni 包，
[Dockerfile.cuda](https://github.com/vllm-project/vllm-omni/blob/main/docker/Dockerfile.cuda)
），在本 repo 新增 plain-Kustomize app `qwen3-tts/`，完全复用 llama-server /
comfyui 已验证的 GPU app 模式（静态 local PV/PVC、nodeSelector、Recreate、
readiness-only probe、HTTPRoute + CF tunnel ingress）。零自定义代码。

**为什么不是"上游 vLLM + Qwen3-TTS"**：上游 vLLM 不支持 Qwen3-TTS。
Qwen3-TTS 是两阶段（talker AR + code2wav 解码）管线，由 vLLM 官方姊妹项目
[vllm-project/vllm-omni](https://github.com/vllm-project/vllm-omni) 支持
（[#1161](https://github.com/vllm-project/vllm-omni/pull/1161) 加入
Qwen3-TTS 管线；[Qwen3-TTS recipe](https://github.com/vllm-project/vllm-omni/blob/main/recipes/Qwen/Qwen3-TTS.md)；
[supported models](https://vllm-omni.readthedocs.io/en/latest/models/supported_models/)
列出 `Qwen3TTSForConditionalGeneration` 全部 checkpoint）。用户问题里的
"vLLM" 落点是 vllm-omni 镜像 —— 它本身就是 `vllm serve` 命令，
与 vLLM 同版本线（v0.28.0 ↔ vLLM 0.28.0）。

**为什么不需要路线 B（定制容器/服务）**：vllm-omni 已内置
OpenAI 兼容 API（`POST /v1/audio/speech`、`GET /v1/audio/voices`、
raw-PCM 流式），镜像开箱即用。只有出现以下需求才值得定制：
- 需要同时服务多个 variant（一个进程只能跑一个 checkpoint；4080 16GB 也
  装不下两个）—— 解法是"改 deployment args + rollout"，不是定制；
- 需要非 OpenAI 兼容的 API 面（统一入口、voice 缓存、转码、批量）——
  那是一个薄的旁路包装服务，不动推理镜像。

**不推荐**：自己维护 torch+vllm-omni 的 slim 镜像（镜像 ~10GB 只是拉取成本，
定制镜像的维护成本不值当）。

## 调研事实（2026-09-02 核实）

| 项 | 值 |
|---|---|
| 模型族 | Qwen3-TTS-12Hz，Apache-2.0，[HF: Qwen](https://huggingface.co/Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice) |
| Task 类型 | `CustomVoice`（预置音色，可加 `instructions` 情绪/风格）、`VoiceDesign`（自然语言描述设计音色）、`Base`（参考音频 + 文本克隆）—— 每种对应独立 checkpoint，**一个进程只能跑一个** |
| Checkpoint | 1.7B：CustomVoice / VoiceDesign / Base；0.6B：仅 CustomVoice / Base |
| 权重磁盘 | 1.7B 各 ~3.83GB、0.6B 各 ~1.81GB（`model.safetensors`）+ 每个 checkpoint 自带 `speech_tokenizer/` ~0.68GB → 单 variant 落盘 2.5–4.5GB |
| API | `POST /v1/audio/speech`（OpenAI audio.speech 兼容：`input`/`voice`/`language`/`instructions`/`response_format`/`stream`/`sample_rate`；Base 另有 `ref_audio`/`ref_text`/`speaker_embedding`/`task_type`）、`GET /v1/audio/voices` |
| 流式 | `stream: true, stream_format: "audio", response_format: "pcm"` → 24kHz mono raw PCM 低延迟流（deploy config 默认开 async chunking，首块 1 frame） |
| 服务命令 | `vllm serve <checkpoint> --omni --port <port> --deploy-config <qwen3_tts.yaml>`（recipe 原样） |
| VRAM | 默认 deploy config：stage0(talker) 与 stage1(code2wav) 各 `gpu_memory_utilization: 0.3`（共享同一 GPU）。0.6B 在 4090 24GB 上 idle ~13.5GiB（= 配置的 0.3+0.3 预分配），权重仅 ~2.4GB |
| 镜像 | `vllm/vllm-omni:v0.28.0`（Docker Hub，~10GB 展开；`v0.28.0` 对齐 vLLM 0.28.0，2026-08-31 发布；另有 `nightly`） |
| 吞吐参考 | MI300X 上 1.7B CustomVoice RTF ~0.23–0.30（5.68s 音频 1.3–1.7s 生成）；4080 会慢，量级可用 |
| 认证 | 服务本身无内置 API key（示例客户端用 `Bearer EMPTY`）；访问控制靠 tunnel 层（本计划外） |

## 资源与适配估算（本集群）

- **GPU**：单张 RTX 4080 16GB（`k8s-gpu-worker-001`）。
  - **0.6B 起步（推荐）**：默认 config 预分配 0.3+0.3 → ~9.6GB VRAM，
    余量 ~6GB，无自定义配置即可跑。
  - **1.7B（后续可选）**：默认 config 下 stage0 分配 4.8GB 但权重 ~3.8GB，
    KV 余量 ~1GB，大概率 OOM —— 需要自定义 deploy config
    （如 stage0 `0.55` / stage1 `0.3` → idle ~13.6GB）后实测。
  - 与 llama-server / comfyui **互斥**：默认 `replicas: 0`；切换 =
    同时改两个 deployment 的 `replicas:`（owner=1，其余=0）并 apply。
- **Host RAM**：request 8Gi / limit 32Gi（与现有 GPU app 同款）。
- **磁盘**：host HF cache 每 variant +2.5–4.5GB（500Gi 容量，充足）。
- **网络**：模型在 GPU node host 上预下载（read-only cache 约定，与
  llama-server/comfyui 一致），pod 内 `HF_HUB_OFFLINE=1`。

## 部署架构

```
External → Cloudflare Edge（CF Access，已有，范围外）
  └─ cloudflared (3 replicas, tunnel e6e456ae-…)
      └─ https://cilium-gateway-gateway.gateway:443 (originServerName = SNI)
          └─ Cilium Gateway (shared, ns gateway, *.junjie.pro 通配 TLS)
              └─ HTTPRoute[host: tts.junjie.pro]  (ns qwen3-tts)
                  └─ Service qwen3-tts:8000
                      └─ Deployment qwen3-tts (replicas 0/1, Recreate)
                          ├─ vllm/vllm-omni:v0.28.0 (digest pin)
                          ├─ vllm serve Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice --omni --port 8000 --deploy-config /app/vllm-omni/vllm_omni/deploy/qwen3_tts.yaml
                          ├─ GPU node (nvidia.com/gpu: 1, pci-10de.present)
                          └─ PVC qwen3-tts-models (ROX, static local PV
                              → /opt/models/huggingface，共享 host HF cache)
```

## 任务清单

### Task 1: GPU node host 准备模型（k8s-cluster 范围，非 repo 资源）

> 2026-09-02 核查：节点的 `/opt/models/huggingface` 是 virtiofs 挂载的
> host HF cache（对应 toolbx `~/.cache/huggingface`）。全部 6 个
> checkpoint + 独立 Tokenizer 已缓存完整（refs/main 齐全，~19GB；
> 0.6B 各 1811.6/1829.3MB、1.7B 各 3833.4/3857.4MB、tokenizer 682.3MB，
> 与 HF API 逐字节一致）。`blobs/` + 快照符号链接布局 vllm/hf 直接可读。
> **无需下载或同步。**

- [x] ****

```bash
ls -L /opt/models/huggingface/models--Qwen--Qwen3-TTS-12Hz-0.6B-CustomVoice/snapshots/*/model.safetensors
```

- [ ] **Step 1b:（仅当某 repo 缺失时）补下载**

```bash
huggingface-cli download Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice \
    --cache-dir /opt/models/huggingface
```

- [ ] **Step 2:（可选，后续切 variant 才需要）下载其余 checkpoint**

```bash
for repo in Qwen/Qwen3-TTS-12Hz-0.6B-Base \
            Qwen/Qwen3-TTS-12Hz-1.7B-CustomVoice \
            Qwen/Qwen3-TTS-12Hz-1.7B-VoiceDesign \
            Qwen/Qwen3-TTS-12Hz-1.7B-Base; do
  huggingface-cli download "$repo" --cache-dir /opt/models/huggingface
done
```

- [x] ****

```bash
du -sh /opt/models/huggingface/models--Qwen--Qwen3-TTS-12Hz-0.6B-CustomVoice
ls /opt/models/huggingface/models--Qwen--Qwen3-TTS-12Hz-0.6B-CustomVoice/snapshots/*/
```

### Task 2: 新建 `qwen3-tts/` app（全部 KYAML，`yamlfmt` 格式化）

**Files:**
- Create: `qwen3-tts/namespace.yaml`
- Create: `qwen3-tts/persistentvolume.yaml`
- Create: `qwen3-tts/persistentvolumeclaim.yaml`
- Create: `qwen3-tts/deployment.yaml`
- Create: `qwen3-tts/service.yaml`
- Create: `qwen3-tts/httproute.yaml`
- Create: `qwen3-tts/dnsendpoint.yaml`
- Create: `qwen3-tts/kustomization.yaml`

- [x] ****

```
---
{
  apiVersion: "kustomize.config.k8s.io/v1beta1",
  kind: "Kustomization",
  namespace: "qwen3-tts",
  resources: [
    "namespace.yaml",
    "persistentvolume.yaml",
    "persistentvolumeclaim.yaml",
    "deployment.yaml",
    "service.yaml",
    "httproute.yaml",
    "dnsendpoint.yaml",
  ],
  images: [{
    # Docker Hub 官方 vllm-omni 镜像；v0.28.0 对齐 vLLM 0.28.0
    # （digest 为 registry 对 tag 返回的 Docker-Content-Digest，2026-09-02 取值）
    name: "docker.io/vllm/vllm-omni",
    newTag: "v0.28.0@sha256:6f8be103eaf0055448cf7578cfd621405fd669079d4361bd58896326b2bf722a",
  }],
}
```

- [x] ****

`persistentvolume.yaml`：

```
---
{
  apiVersion: "v1",
  kind: "PersistentVolume",
  metadata: {
    name: "qwen3-tts-models",
  },
  spec: {
    # 同 llama-models / comfyui-hf-cache：PV 是 cluster-scoped 且只绑一个 PVC，
    # 每个 app 需要自己的一对；路径是 GPU node 上只读 virtiofs HF cache。
    capacity: {
      storage: "500Gi",
    },
    accessModes: [
      "ReadOnlyMany",
    ],
    persistentVolumeReclaimPolicy: "Retain",
    storageClassName: "local-models",
    local: {
      path: "/opt/models/huggingface",
    },
    nodeAffinity: {
      required: {
        nodeSelectorTerms: [{
          matchExpressions: [{
            key: "feature.node.kubernetes.io/pci-10de.present",
            operator: "In",
            values: [
              "true",
            ],
          }],
        }],
      },
    },
  },
}
```

`persistentvolumeclaim.yaml`：

```
---
{
  apiVersion: "v1",
  kind: "PersistentVolumeClaim",
  metadata: {
    name: "qwen3-tts-models",
  },
  spec: {
    storageClassName: "local-models",
    accessModes: [
      "ReadOnlyMany",
    ],
    resources: {
      requests: {
        storage: "500Gi",
      },
    },
  },
}
```

- [x] ****

```
---
{
  apiVersion: "apps/v1",
  kind: "Deployment",
  metadata: {
    name: "qwen3-tts",
    labels: {
      app: "qwen3-tts",
    },
  },
  spec: {
    # 0 by default: the single RTX 4080 is shared with llama-server and
    # comfyui. To use TTS set this to 1, set the other GPU owner to 0,
    # apply both, switch back afterwards.
    replicas: 0,
    strategy: {
      type: "Recreate",
    },
    selector: {
      matchLabels: {
        app: "qwen3-tts",
      },
    },
    template: {
      metadata: {
        labels: {
          app: "qwen3-tts",
        },
      },
      spec: {
        nodeSelector: {
          feature.node.kubernetes.io/pci-10de.present: "true",
        },
        securityContext: {
          seLinuxOptions: {
            type: "spc_t",
          },
        },
        containers: [{
          name: "qwen3-tts",
          image: "docker.io/vllm/vllm-omni",
          # vllm-omni 镜像 ENTRYPOINT 为空，command/args 原样成为容器命令；
          # 显式写全避免依赖上游镜像默认 CMD 的 MODEL_NAME 约定。
          command: ["vllm"],
          args: [
            "serve",
            "Qwen/Qwen3-TTS-12Hz-0.6B-CustomVoice",
            "--omni",
            "--port",
            "8000",
            # 镜像内自带 deploy config（/app/vllm-omni 是 COPY 进镜像的
            # repo 根）：0.6B 在 16GB 上按 0.3+0.3 默认值即可；
            # 若日后换 1.7B 需要 stage0/stage1 分档调 gpu_memory_utilization，
            # 届时改为 ConfigMap 挂载自定义文件。
            "--deploy-config",
            "/app/vllm-omni/vllm_omni/deploy/qwen3_tts.yaml",
          ],
          ports: [{
            containerPort: 8000,
            name: "http",
          }],
          resources: {
            limits: {
              nvidia.com/gpu: 1,
              memory: "32Gi",
            },
            requests: {
              nvidia.com/gpu: 1,
              memory: "8Gi",
              cpu: 2,
            },
          },
          env: [{
            # 复用 GPU node 共享 HF cache（与 comfyui 同款挂法）；
            # OFFLINE=1 保证缺仓库时快速失败而不是走网络。
            name: "HF_HUB_CACHE",
            value: "/hf-cache",
          }, {
            name: "HF_HUB_OFFLINE",
            value: "1",
          }],
          volumeMounts: [{
            name: "hf-cache",
            mountPath: "/hf-cache",
            readOnly: true,
          }],
          # Readiness only — no liveness, same as comfyui: 两阶段管线 +
          # 模型加载耗时数分钟，liveness 可能杀掉健康加载中。
          readinessProbe: {
            httpGet: {
              path: "/health",
              port: 8000,
            },
            initialDelaySeconds: 30,
            periodSeconds: 10,
          },
        }],
        volumes: [{
          name: "hf-cache",
          persistentVolumeClaim: {
            claimName: "qwen3-tts-models",
          },
        }],
      },
    },
  },
}
```

- [x] ****
（照 comfyui 对应文件改名字/端口/域名：Service 8000/8000；
HTTPRoute hostname `tts.junjie.pro`，backend `qwen3-tts:8000`，
parentRef `gateway/gateway`；DNSEndpoint `tts.junjie.pro` CNAME →
`e6e456ae-2397-4f56-a601-e6498091e030.cfargotunnel.com`；
Namespace `qwen3-tts`。）

- [x] ****

```bash
yamlfmt qwen3-tts/
kubectl kustomize qwen3-tts/ | grep image:
# 期望：image: docker.io/vllm/vllm-omni:v0.28.0@sha256:6f8be103…
```

### Task 3: cloudflared tunnel ingress 加 hostname

- [x] ****

```
    {
      hostname: "tts.junjie.pro",
      service: "https://cilium-gateway-gateway.gateway:443",
      originRequest: {
        noTLSVerify: true,
      },
      originServerName: "tts.junjie.pro",
    },
```

- [x] ****

```bash
kubectl apply -k cloudflared/
kubectl rollout status -n cloudflared deployment/cloudflared
```

### Task 4: 部署（replicas 0，不占 GPU）+ 验证

- [x] ****

```bash
kubectl apply -k qwen3-tts/
```

- [x] ****

```bash
kubectl diff -k qwen3-tts/   # 期望无输出
```

- [x] ****

```bash
kubectl get ns,pod,httproute,dnsendpoint -n qwen3-tts
kubectl get httproute -n qwen3-tts -o jsonpath='{.items[0].status.parents[].conditions}'
# 期望：Accepted=True, ResolvedRefs=True
```

### Task 5: GPU 切换试运行（需要 llama-server 让出 GPU，允许短暂中断）

- [ ] **Step 1: 切换**

编辑 `llama-server/deployment.yaml` `replicas: 1 → 0`、
`qwen3-tts/deployment.yaml` `replicas: 0 → 1`，各自
`kubectl apply -k <app>/`，等待：

```bash
kubectl rollout status -n qwen3-tts deployment/qwen3-tts
kubectl logs -n qwen3-tts deployment/qwen3-tts
# 期望：两阶段初始化完成、无 E/OOM；出现 "Application startup complete"
```

- [ ] **Step 2: API 冒烟（port-forward，允许的操作）**

```bash
kubectl port-forward -n qwen3-tts service/qwen3-tts 8000:8000 &
curl http://localhost:8000/v1/audio/voices
curl -X POST http://localhost:8000/v1/audio/speech \
    -H "Content-Type: application/json" \
    -d '{"input":"你好，这是语音合成测试。","voice":"vivian","language":"Chinese"}' \
    -o /tmp/tts-test.wav
file /tmp/tts-test.wav   # 期望 WAV 24kHz mono
```

- [ ] **Step 3: 外部链路验证**

```bash
curl -sS https://tts.junjie.pro/v1/audio/voices   # 需 CF Access 会话
```

- [ ] **Step 4: 切回**（replicas 改回 qwen3-tts=0 / llama-server=1，apply）

### Task 6: 文档与提交

- [x] `README.md`：Structure / Applications 表 / Usage / Architecture 图加
  `qwen3-tts`；Prerequisites 说明镜像 ~10GB。
- [x] `AGENTS.md`："GPU apps are mutually exclusive" 一节从两方改为三方
  （llama-server / comfyui / qwen3-tts）。
- [x] Conventional Commits：manifests、cloudflared ingress、docs 分原子提交。

## 风险与缓解

| 风险 | 缓解 |
|---|---|
| 1.7B 在 16GB 上 OOM（默认 config 下 stage0 余量 ~1GB） | 起步 0.6B；1.7B 用自定义 deploy config（stage0 0.55 / stage1 0.3，idle ~13.6GB）+ 实测，必要时降 `max_model_len` |
| vllm-omni 迭代快（v0.28.0 = 2026-08-31），镜像行为可能随版本漂移 | digest pin（tag@digest）；升级时整体验证 recipe |
| 镜像内 deploy config 路径 `/app/vllm-omni/vllm_omni/deploy/qwen3_tts.yaml` 若上游重构变动 | 失败模式是启动报错（Fast Fail）；回退方案 = ConfigMap 挂载本文档引用的同内容文件 |
| 单进程单 variant：切 variant 需要重启 | 可接受：改 args + rollout；未来要多 variant 并发 = 多 Deployment，但 16GB 装不下两个 |
| Base（voice clone）task 的 `ref_audio` 传大音频走 JSON/base64 | 参考音频控制在 MB 级；更大文件走 URL（`ref_audio` 支持 http(s) URL） |
| GPU 切换期间 llama-server 中断 | 计划内操作；切换窗口内先公告/避开使用 |

## 部署 checklist（AGENTS.md 通用项）

- [x] `kubectl kustomize qwen3-tts/ | grep image:` 渲染镜像 = pin 值
- [x] `yamlfmt -lint qwen3-tts/ cloudflared/` 通过
- [x] 无 `${VAR}` 占位；无 secret（本 app 不需要机密）
- [x] `kubectl diff -k qwen3-tts/` 幂等（无输出）
- [ ] `kubectl logs` 无 E/OOM；Pod Running+Ready RESTARTS=0（运行期间）
- [x] HTTPRoute `Accepted=True, ResolvedRefs=True`
- [x] 集群同步：所有运行资源有 manifest
- [x] 已提交（Conventional Commits）
