# 故障排查 SOP · 学习路径版

按**学习顺序**组织的 9 课。每一课都是从本仓库真实发生过的问题里提炼的，
顺序刻意设计成「先打通通道 → 再理解供应链 → 往上到应用 → 最后到可观测性」，
因为后面的课依赖前面的能力。

每课统一结构：

```text
学习目标 → 前置 → 核心概念 → 现象 → 诊断 → 根因 → 处置 → 验证 → 自检
```

**用法**：按 1→9 顺序读。每课的「自检」是用来确认你真的懂了，不是背命令。

| 课 | 主题 | 对应真实问题 |
| --- | --- | --- |
| [1](#第-1-课--打通作业通道) | 打通作业通道 | 传文件失败、命令拼接失败、目录权限 |
| [2](#第-2-课--镜像供应链) | 镜像供应链 | 拉取四类根因，manifest 通 ≠ blob 通 |
| [3](#第-3-课--容器启动与安全上下文) | 容器启动与安全上下文 | `CreateContainerConfigError` |
| [4](#第-4-课--调度与容量规划) | 调度与容量规划 | 监控栈该放哪个节点 |
| [5](#第-5-课--探针与就绪语义) | 探针与就绪语义 | Running 但永远 NotReady |
| [6](#第-6-课--指标正确性) | 指标正确性 | 多 worker 计数器抖动，告警永不触发 |
| [7](#第-7-课--告警表达式设计) | 告警表达式设计 | 错误率被探针稀释 |
| [8](#第-8-课--告警生命周期) | 告警生命周期 | 告警长时间不消解 |
| [9](#第-9-课--变更校验流程) | 变更校验流程 | `set image` 丢配置、dry-run 级别 |

---

## 贯穿全局的排查模型

9 课都按这个模型走。**记住这一节，比记住任何命令都重要。**

```text
1. 分清层次      网络 / 镜像 / 调度 / 容器启动 / 应用 / 指标正确性？
2. 找权威证据    Events > describe > logs > 猜测
3. 可证伪的测量  例：逐端口探测；不是"大概是端口问题"
4. 最小改动      一次只改一个变量，否则不知道哪步生效
5. 同组测量验证  和第 3 步用完全相同的命令
6. 写成记录      现象 / 证据 / 假设 / 动作 / 验证 / 回滚点
```

**最常见的错误在第 3 步**：看到 `404` 就断定"路径写错"、看到 `NotReady` 就断定"应用没起来"。
本仓库第 5 课和第 6 课都是靠实测推翻了直觉。

一个判断句式，值得背下来：

> 「我看到的现象是 X，我认为原因是 Y，**能证明 Y 的测量是 Z**，Z 的结果是 ___。」

如果 Z 说不出来，就还在猜。

---

## 第 1 课 · 打通作业通道

**学习目标**：能在「本地 Windows → 跳板机 → master」这条链路上可靠地传文件、跑命令，
且知道每种失败对应哪一层。

**前置**：无。这是所有后续操作的地基。

### 1.1 核心概念：链路有三层，失败要定位到层

```text
本地 PowerShell  ──ssh──▶  跳板机 1.95.123.118  ──ssh──▶  master 172.31.6.211
      ↑ 第 1 层引号     ↑ 第 2 层认证            ↑ 第 3 层命令解析
```

master 不通未必是网络问题，可能是公钥没分发。**先分别验证每一跳**：

```bash
# 本地 → master 直连（本项目失败，master 不信任本地公钥）
ssh -o BatchMode=yes -o ConnectTimeout=8 root@172.31.6.211 hostname

# 本地 → 跳板机（本项目成功）
ssh -o BatchMode=yes -o ConnectTimeout=8 root@1.95.123.118 hostname
```

判定表：

| 结果 | 结论 |
| --- | --- |
| 跳板机通、master 不通 | 公钥只装到了跳板机 → 必须两层 ssh |
| 跳板机也超时 | 网络/安全组问题，与 SSH 配置无关 |
| 都通但 `Permission denied` | 认证问题，看 `authorized_keys` |

### 1.2 传输文件：base64 单行最稳

**不要用 `scp` 跨跳板机**，也不要在 PowerShell 里拼长命令行（见 1.4）。
用 base64 把文件变成单行字符串，走 ssh 的 stdin 之外的路径：

```powershell
# 单文件
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes('C:\path\file.yaml'))
ssh root@1.95.123.118 "ssh root@172.31.6.211 'echo $b64 | base64 -d > /tmp/file.yaml'"
```

```powershell
# 批量 + 自动建目录
$root = 'C:\Users\qitin\Documents\sre-devops-lab'
foreach ($rel in @('k8s\app.yaml','docs\runbook.md')) {
  $src  = Join-Path $root $rel
  $b64  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($src))
  $dest = "/opt/sre-devops-lab/" + ($rel -replace '\\','/')
  $dir  = ($dest -replace '/[^/]+$','')
  ssh root@1.95.123.118 "ssh root@172.31.6.211 'mkdir -p $dir && echo $b64 | base64 -d > $dest'"
}
```

### 1.3 远程执行脚本：同样用 base64

把整段脚本编码后让远端 `bash` 解码执行，可以彻底避开引号嵌套：

```powershell
$script = @'
kubectl get nodes
kubectl -n sre-lab get pods
'@
$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($script))
ssh root@1.95.123.118 "ssh root@172.31.6.211 'echo $b64 | base64 -d | bash'"
```

### 1.4 命令太长：分段传

**真实踩坑**：27 KB 的文档编码成 base64 是 36 KB，直接拼进 ssh 参数会炸：

```text
程序"ssh.exe"无法运行: The filename or extension is too long
```

Windows 单条命令行有长度上限（约 32 KB）。**超过约 6000 字符的 base64 就要分段追加**：

```powershell
$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($src))
ssh root@1.95.123.118 "ssh root@172.31.6.211 'rm -f /tmp/up.b64'"
for ($pos = 0; $pos -lt $b64.Length; $pos += 6000) {
  $seg = $b64.Substring($pos, [Math]::Min(6000, $b64.Length - $pos))
  ssh root@1.95.123.118 "ssh root@172.31.6.211 'printf %s $seg >> /tmp/up.b64'"
}
ssh root@1.95.123.118 "ssh root@172.31.6.211 'base64 -d /tmp/up.b64 > $dest && md5sum $dest'"
```

### 1.5 验证：必须校验哈希

传输"看起来成功"和"内容正确"是两件事。**每次传完都对比 MD5**：

```powershell
(Get-FileHash $src -Algorithm MD5).Hash.ToLower()
```

```bash
md5sum /opt/sre-devops-lab/docs/file.md
```

本项目靠这个发现过中文文档的编码问题（UTF-8 BOM 会导致 YAML 解析失败）。

### 1.6 一个容易吓人的假故障

`ssh` 的 **stderr 会被 PowerShell 染成红色错误**，即使命令完全成功：

```text
ssh : time="2026-11-05T09:43:51+08:00" level=warning msg="Config /etc/crictl.yaml does not exist"
    + CategoryInfo : NotSpecified: (...), RemoteException
```

这是 `crictl` 的正常 warning 经 stderr 回传导致的。**看 stdout 的结果，不要被红字带偏。**

### 1.7 目录权限

早期在本地磁盘根目录创建项目被 ACL 拒绝，换到用户目录后正常。

```powershell
icacls "C:\path" 2>$null
```

**原则**：不硬碰系统目录权限，换到用户可写目录。

### ✅ 第 1 课自检

1. master 直连报 `Permission denied`，但跳板机能连——**下一步该确认什么**？
2. 传输大文件报"filename too long"，是网络问题吗？
3. 为什么传完必须比对 MD5？
4. ssh 输出一片红字，怎么判断命令到底成功没有？

<details>
<summary>参考答案</summary>

1. 确认本地公钥是否在 master 的 `authorized_keys` 里；不在就只能经跳板机转发，链路是"两层 ssh"。
2. 不是。是 Windows 命令行长度上限，与网络无关。需要按 6000 字符分段 base64 追加。
3. 因为"命令返回 0"只代表 shell 执行了，不代表字节完整或编码正确。本项目靠 MD5 发现过 UTF-8 BOM 问题。
4. 看 stdout 和 `$LASTEXITCODE`。`crictl` 等工具的 warning 走 stderr，会触发 PowerShell 的 NativeCommandError，但命令本身成功。

</details>

---

## 第 2 课 · 镜像供应链

**学习目标**：看到 `ImagePullBackOff` 时，能在 3 条命令内判定属于四类根因中的哪一类，
而不是无脑换镜像源。

**前置**：第 1 课（要能上 master 执行 `crictl`）。

### 2.1 核心概念：拉取失败有四种根因，处理方式互不通用

```text
① DNS 解析失败        → 换等价源，不要改 DNS
② 网络可达但下载超时   → 换能完整下载的代理源
③ 权限不足            → 配 imagePullSecret 或改公开
④ 标签/仓库名写错      → 改清单
```

四类的处置方向完全不同。**先分类，再动手。**

### 2.2 现象

```text
Pod 状态 ImagePullBackOff / ErrImagePull
kubectl describe pod → Failed to pull image / failed to resolve reference / no such host
```

### 2.3 诊断：三步定位

```bash
# ① 看 Events 的第一条错误，不要只看最后一条
kubectl -n <ns> describe pod <pod> | sed -n '/Events/,$p'

# ② 用 crictl 直接拉，绕过 Deployment 干扰
crictl pull <image>:<tag>

# ③ 仓库 API 是否可达（401/200 = 通，000 = 网络）
curl -s -o /dev/null -w "%{http_code}\n" --max-time 10 https://<registry>/v2/

# ④ DNS 能否解析（registry.k8s.io 会 307 到别的域名，这层经常漏）
getent hosts <registry-host>
```

判据表：

| 现象 | 类别 | 去向 |
| --- | --- | --- |
| `no such host` | ① DNS | 2.4 |
| `timeout awaiting response headers` / `000` | ② 网络 | 2.5 |
| `403 Forbidden` / `unauthorized` | ③ 权限 | 2.6 |
| `manifest unknown` / `not found` | ④ 标签 | 2.6 |
| 镜像 Pulled 但 Pod 报 `CreateContainerConfigError` | **不是拉取问题** | 第 3 课 |

### 2.4 类别①：域名解析失败

**真实案例**：

```text
registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.16.0
  ↓ 307 重定向到
https://europe-west3-docker.pkg.dev/v2/k8s-artifacts-prod/images/...
  ↓
dial tcp: lookup europe-west3-docker.pkg.dev on 127.0.0.53:53: no such host
```

**注意**：`curl https://registry.k8s.io/v2/` 返回 307，看起来"通"，
但真实下载发生在重定向后的域名，那一步才失败。

**处置**：换等价源，不改 DNS。

```text
registry.k8s.io/kube-state-metrics/kube-state-metrics:v2.16.0
  ↓
k8s.m.daocloud.io/kube-state-metrics/kube-state-metrics:v2.16.0
```

### 2.5 类别②：manifest 通 ≠ blob 通（最容易误判）

**真实案例**：quay.io 的 API 完全正常——

```bash
curl -s -o /dev/null -w "%{http_code}" https://quay.io/v2/prometheus/prometheus/manifests/v3.6.0
# 200  ← 看起来网络没问题
```

但真实拉取 60 秒超时：

```text
Get "https://quay.io/v2/prometheus/prometheus/blobs/sha256:0357...":
net/http: timeout awaiting response headers
```

**为什么容易误判**：manifest 是小 JSON，blob 是几百 MB 的层，走不同 CDN，
前者通不代表后者通。**只有实际拉一次才算验证。**

```bash
time timeout 60 crictl pull <image>:<tag>
```

本项目实测的镜像源状态（可直接参考）：

| 源 | 状态 | 用途 |
| --- | --- | --- |
| `docker.m.daocloud.io` | ✅ 可用 | Docker Hub 镜像（prom、grafana、busybox） |
| `k8s.m.daocloud.io` | ✅ 可用 | registry.k8s.io 镜像 |
| `quay.m.daocloud.io` | 可达 | quay.io 备份源 |
| `ghcr.io` | ✅ 可用 | 本项目自己的镜像 |
| `registry.cn-hangzhou.aliyuncs.com` | 可达 | 备用 |
| `registry-1.docker.io` | ❌ 超时 | 不可用 |
| `quay.io` 直连 | ❌ blob 超时 | 不可用 |

预拉取耗时（用来估算演示窗口）：

```text
alertmanager         35 MB    58s
node-exporter        13 MB    16s
prometheus          124 MB   114s
grafana             204 MB   218s
kube-state-metrics   18 MB    25s
```

**实践建议**：`imagePullPolicy: IfNotPresent` + 提前 `crictl pull` 预热，
演示时不受网络抖动影响。

### 2.6 类别③④：权限与标签

```bash
# 用匿名 token 查 manifest，能区分"不存在"和"没权限"
curl -s -o /dev/null -w "%{http_code}\n" \
  "https://<registry>/v2/<repo>/manifests/<tag>"
```

| 状态码 | 含义 |
| --- | --- |
| 200 | 存在且可匿名访问 |
| 401 | 需要认证 |
| 403 | 无权限，或镜像不存在（GHCR 对不存在的私有仓库返回 403） |
| 404 | 标签或仓库名错 |

GHCR 私有包需要 imagePullSecret。本项目把包设为公开以简化拉取——**这是实验环境的取舍，
真实环境必须用 imagePullSecret**。

### ✅ 第 2 课自检

1. `curl https://quay.io/v2/` 返回 401，能说明镜像拉得下来吗？
2. 看到 `no such host`，应该改 Docker 的 DNS 配置吗？
3. `Events 里有 Pulled` 但 Pod 起不来，属于本课哪一类？
4. 为什么要在演示前做 `crictl pull` 预热？

<details>
<summary>参考答案</summary>

1. 不能。401 只说明 registry API 端点可达（正常的 token 挑战）。manifest 和 blob 走不同 CDN，必须 `crictl pull` 实测。
2. 不应该。换等价镜像源更稳妥；改 DNS 影响面大且未必解决（重定向域名可能本就不该解析）。
3. 都不属于。有 `Pulled` 就说明镜像已成功落地，问题在容器启动配置，进入第 3 课。
4. 因为环境到 registry 的带宽有限（124 MB 要 114 秒），预热后 `IfNotPresent` 命中本地缓存，演示不会卡在拉取上。

</details>

---

## 第 3 课 · 容器启动与安全上下文

**学习目标**：掌握 `runAsNonRoot` 与镜像 `USER` 的交互规则，能一眼区分
"拉取失败"和"启动配置失败"。

**前置**：第 2 课（要能判断镜像是否真的拉下来了）。

### 3.1 核心概念：`runAsNonRoot` 只认数字

Kubernetes 在 `runAsNonRoot: true` 时的校验逻辑是：

```text
读取镜像配置的 User 字段
  ├─ 是数字（如 "10001"）  → 比对是否 != 0，通过
  └─ 是字符串（如 "app"）  → 无法证明非 root → 直接拒绝启动
```

**关键点**：用户名 `app` 对应的 UID 在宿主机上可以是任何值，Kubernetes 不会去镜像里
查 `/etc/passwd`，所以它选择拒绝。这是**保守的正确设计**，不是 bug。

### 3.2 现象

```text
Deployment 0/2，Pod CreateContainerConfigError
Events:
  Normal  Pulled  ...
  Warning ... container has runAsNonRoot and image has non-numeric user (app),
              cannot verify user is non-root
```

### 3.3 诊断：一条命令分层

```bash
kubectl -n <ns> describe pod <pod> | grep -E "Pulled|runAsNonRoot|non-numeric"
```

**判据**：Events 里出现 `Pulled` = 镜像已经下来了 = **不是第 2 课的问题**。
看到 `non-numeric` 就直接锁定了。

### 3.4 处置：两处都要改

只改一处不生效，这是新手常犯的错。

```dockerfile
# ① Dockerfile
USER 10001:10001
```

```yaml
# ② Deployment
spec:
  template:
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001      # 必须数字
        runAsGroup: 10001
        fsGroup: 10001
```

改完需要**重新构建镜像并推送**，因为 ① 在镜像层。
只改 ② 而不重建镜像，Kubernetes 会用 `runAsUser` 覆盖，但镜像里的 `USER app` 仍然是字符串，
部分运行时仍会校验失败——**两个都改才干净**。

### 3.5 验证

```bash
kubectl -n sre-lab rollout status deploy/demo-api --timeout=120s
kubectl -n sre-lab get pods                    # 期望 2/2 Running
kubectl -n sre-lab exec deploy/demo-api -- id  # 期望 uid=10001
```

### 3.6 预防

**Dockerfile 里永远用数字 UID。** 用户名只给人看，`runAsNonRoot` 只认数字。

顺带一条通用原则：**修复时想清楚"为什么会发生"**。
这里的正解是"以后都用数字 UID"，不是"这次改成 10001"。

### ✅ 第 3 课自检

1. 为什么用户名 `app` 会导致启动失败？Kubernetes 为什么不去镜像里查 UID？
2. 只改 Deployment 的 `runAsUser` 够不够？
3. `CreateContainerConfigError` 和 `ImagePullBackOff` 怎么快速区分？
4. `runAsNonRoot` 的校验为什么是"保守但正确"的设计？

<details>
<summary>参考答案</summary>

1. 镜像配置的 User 是字符串，Kubernetes 无法据此证明 UID != 0。它不去查 `/etc/passwd` 是因为那需要解析镜像文件系统，成本高且不可靠——直接拒绝更安全。
2. 不够干净。应同时把 Dockerfile 的 `USER` 改成数字并重建镜像，否则镜像元数据仍是字符串，不同运行时行为可能不一致。
3. 看 Events：有 `Pulled` 就是启动配置问题；全是 `Failed to pull` 才是拉取问题。
4. 因为"无法证明非 root"应该按"可能是 root"处理（fail-safe），拒绝启动优先于冒风险运行。

</details>

---

## 第 4 课 · 调度与容量规划

**学习目标**：会用量化数据决定工作负载放哪个节点，理解 taint/toleration 与
DaemonSet 的例外写法。

**前置**：第 3 课（Pod 能启动之后，才谈得上"放哪"）。

### 4.1 核心概念：两个约束同时决定调度

```text
① 资源约束   requests 总和 ≤ 节点 allocatable
② 污点约束   节点有 taint 时，Pod 必须带对应 toleration
```

两者都不满足时，Pod 停在 `Pending`，Events 会同时报出来：

```text
0/2 nodes are available: 1 node(s) had untolerated taint
  {node-role.kubernetes.io/control-plane: }, 1 Insufficient memory.
```

**这句话同时告诉你两件事**：一个节点被 taint 挡住，另一个内存不够。

### 4.2 诊断：先量，再决定

```bash
# 污点
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# 可分配量
kubectl get nodes -o custom-columns=NAME:.metadata.name,CPU:.status.allocatable.cpu,MEM:.status.allocatable.memory

# 已用量
kubectl describe nodes | grep -A6 "Allocated resources"
```

本项目实测：

```text
master  4 CPU / 15.1 GiB   已用 950m(23%) CPU、290Mi(1%) 内存   taint: control-plane:NoSchedule
node    2 CPU /  3.5 GiB   已用 300m(15%) CPU、306Mi(8%) 内存   无 taint
```

### 4.3 决策：算预算，不要凭感觉

监控栈需求（5 个组件）：

```text
requests  290m CPU / 608Mi 内存
limits   1500m CPU / 1280Mi 内存
```

- **放 node**：node 只有 3.5 GiB，装完监控会挤掉业务，且 node 没有 taint，调度器默认会放这里——**危险**。
- **放 master**：15 GiB 只用了 1%，余量充足，但带 `NoSchedule` taint。

**结论：全部放 master，显式声明 toleration + nodeSelector。**

```yaml
spec:
  template:
    spec:
      nodeSelector:
        kubernetes.io/hostname: master
      tolerations:
        - key: node-role.kubernetes.io/control-plane
          operator: Exists
          effect: NoSchedule
```

### 4.4 DaemonSet 的例外：容忍所有污点

`node-exporter` 要采集**每个**节点（包括 master），所以不能指定 `key`：

```yaml
tolerations:
  - operator: Exists     # 无 key，容忍一切 taint
```

这是 DaemonSet 的标准写法。**区别记牢**：有 key 是"容忍某个特定污点"，
无 key 是"容忍全部"。

### 4.5 验证

```bash
kubectl -n monitoring get pods -o wide    # NODE 列：4 个部署在 master，node-exporter 两个节点各一个
free -m                                    # master 可用内存仍在 14 GiB 级
```

### 4.6 预防

**先算预算再部署**，并且把预算写进文档。本项目在清单注释和 README 里都留了数字，
下次加组件时可以直接判断还有多少余量。

### ✅ 第 4 课自检

1. `Pending` 的 Events 里同时出现 `untolerated taint` 和 `Insufficient memory`，怎么读？
2. 为什么监控栈不能放 node？
3. DaemonSet 为什么要用无 key 的 toleration？
4. `nodeSelector` 和 `tolerations` 能互相替代吗？

<details>
<summary>参考答案</summary>

1. 两个节点各有不同原因：一个被 taint 挡住，另一个资源不足。需要分别解决：加 toleration / 降 requests。
2. node 只有 3.5 GiB，且没有 taint，调度器会默认把 Pod 放上去，装完监控会挤掉业务。
3. 因为 DaemonSet 要覆盖所有节点，包括带各种 taint 的；无 key 的 `operator: Exists` 才表示"容忍全部"。
4. 不能。`nodeSelector` 是"我要去哪"，`tolerations` 是"我允许去哪"。tainted 节点必须两者都满足才能调度上去。

</details>

---

## 第 5 课 · 探针与就绪语义

**学习目标**：理解 `探针 404 → NotReady → Endpoint 为空 → Service refused` 这条因果链，
并掌握"临时 Pod 直连 Pod IP"的实测方法。

**前置**：第 3、4 课（Pod 能启动、能调度）。

### 5.1 核心概念：三层状态，不是一件事

```text
容器进程活着      → Pod phase = Running
readinessProbe 通过 → Pod READY = 1/1 → 进入 Service Endpoints
livenessProbe 通过  → 容器不被重启
```

**关键**：`Running` 和 `Ready` 是两个独立维度。进程活着但探针失败，
Pod 会一直 `0/1`，而 Service 因为**没有 Endpoint** 而访问不通。

### 5.2 现象

```text
Pod 状态 Running，但 READY 是 0/1
Service 的 Endpoints 为空
Events 反复出现：Readiness probe failed: HTTP probe failed with statuscode: 404
```

### 5.3 诊断：不要猜，要实测

**第一个陷阱**：`kubectl port-forward svc/<svc>` 在无 Endpoint 时会失败或拒绝连接，
这会让人误以为"服务挂了"。实际上应用完全正常。

**正确方法：临时 Pod 直连 Pod IP，逐端口逐路径探测。**

```bash
# 1. 拿 Pod IP
kubectl -n monitoring get pod -l app.kubernetes.io/name=kube-state-metrics -o wide

# 2. 用 busybox 直连探测
kubectl -n monitoring run probe --rm -i --restart=Never \
  --image=docker.m.daocloud.io/library/busybox:1.36 --command -- sh -c '
for port in 8080 8081; do
  for p in /healthz /livez /readyz /metrics /; do
    r=$(wget -qS -O /dev/null "http://<POD_IP>:$port$p" 2>&1 | grep -E "HTTP/" | head -1)
    echo "$port$p -> ${r:-no-response}"
  done
done'
```

### 5.4 真实实测结果（kube-state-metrics v2.16.0）

```text
8080 (http-metrics): /healthz 200, /livez 200, /readyz 404, /metrics 200
8081 (telemetry)   : /readyz 200, /healthz 404, /livez 404, /metrics 200
```

**端点分布与直觉相反**：健康检查在 metrics 端口，就绪检查在 telemetry 端口。

清单里原本写的是 `8081/healthz`，该路径不存在 → 永远 404 → 永远 NotReady → 永无 Endpoint。

### 5.5 处置

```yaml
readinessProbe:
  httpGet:
    path: /readyz        # 在 telemetry 端口
    port: telemetry      # 8081
livenessProbe:
  httpGet:
    path: /livez         # 在 http-metrics 端口
    port: http-metrics   # 8080
```

### 5.6 验证

```bash
kubectl -n monitoring get pods                      # 1/1 Running
kubectl -n monitoring get endpoints kube-state-metrics
# 期望：10.244.0.8:8081,10.244.0.8:8080   而不是 <none>
```

### 5.7 预防

- 探针路径**不要靠印象写**，装新组件前先实测一遍。
- 把实测结论写进 YAML 注释（本项目 `30-exporters.yaml` 里就留了这段注释），
  下一个维护者不用再探一次。
- **记住因果链**：只看到最后一步（Service refused）会误判成服务挂了。

### ✅ 第 5 课自检

1. Pod 是 Running 但 READY 0/1，服务能访问吗？为什么？
2. 为什么不能用 `port-forward svc/xxx` 来验证应用是否正常？
3. 探针 404 和容器崩溃，Events 里怎么区分？
4. 为什么要区分 readiness 和 liveness？

<details>
<summary>参考答案</summary>

1. 不能。Pod 未 Ready 就不会进 Service Endpoints，ClusterIP 没有后端，访问会被拒绝。
2. 因为 Service 无 Endpoint 时 port-forward 也会失败，这时分不清是应用挂了还是路由没建好。直连 Pod IP 才能看到真实响应码。
3. 探针 404 时 Pod 是 `Running`、日志显示服务已监听；容器崩溃是 `CrashLoopBackOff`、有重启计数和退出码。
4. readiness 决定"是否接流量"，失败只是摘除 Endpoint；liveness 决定"是否重启"，失败会杀容器。混用会导致流量抖动或该重启的不重启。

</details>

---

## 第 6 课 · 指标正确性

**学习目标**：掌握"指标在撒谎"这类问题的发现方法。
这是本仓库最有价值的一课，因为**它不会报错，只会让告警静默失效**。

**前置**：第 5 课（服务能正常接流量，才有干净的流量可测）。

### 6.1 核心概念：多进程服务的计数器天然分裂

```text
gunicorn master
  ├─ worker A  独立进程 → 独立的 Counter 内存
  └─ worker B  独立进程 → 独立的 Counter 内存

/metrics 请求随机落到一个 worker → 只返回那一个的数字
```

Prometheus 每 15 秒抓一次，如果两次落在不同 worker，看到的序列是：

```text
53536 → 66702 → 53542 → 66708    ← 来回跳
```

Prometheus 把回退解释为"计数器重置"，于是 `rate()` 按 reset 逻辑处理，
结果**随机偏大或归零**。这就是"数据看着有、告警不触发"的根源。

### 6.2 现象

- 注入 720 次 HTTP 500 后，5xx 比例只有 `0.0006`
- `rate()` 算出 `1366 req/s`，而真实探针速率约 `0.1 req/s`
- `increase()` 结果随机偏大甚至为负
- **告警永不 Firing，但面板看起来一切正常**

### 6.3 诊断：必须查区间，不能只看瞬时值

瞬时值恰好落在高值那次采样上时，看起来毫无问题。

```bash
kubectl -n monitoring port-forward svc/prometheus 9090:9090

END=$(date +%s); START=$((END-180))
curl -s "http://127.0.0.1:9090/api/v1/query_range?query=demo_http_requests_total%7Bpath%3D%22%2Freadyz%22%7D&start=$START&end=$END&step=15" \
 | python3 -c "
import sys,json
for s in json.load(sys.stdin)['data']['result']:
    vals=[float(v[1]) for v in s['values']]
    print(s['metric'].get('pod'), [int(v) for v in vals])
    print('  drops:', sum(1 for a,b in zip(vals,vals[1:]) if b<a), 'of', len(vals)-1)
"
```

**判据：计数器（`_total`）出现回退。**

```text
正确：53536 → 53538 → 53540 → 53542 → 53545
故障：53536 → 66702 → 53542 → 66708 → 53545
```

### 6.4 处置：启用 multiprocess 模式（三处配合）

```python
# ① app/app.py —— 聚合所有 worker 的 mmap 文件
import os
from prometheus_client import REGISTRY, CollectorRegistry, generate_latest, multiprocess

_MULTIPROC_DIR = os.getenv('PROMETHEUS_MULTIPROC_DIR')

def _metrics_registry():
    if not _MULTIPROC_DIR:
        return REGISTRY
    registry = CollectorRegistry()
    multiprocess.MultiProcessCollector(registry)
    return registry

METRICS_REGISTRY = _metrics_registry()

@app.get('/metrics')
def metrics():
    return Response(generate_latest(METRICS_REGISTRY), mimetype=CONTENT_TYPE_LATEST)
```

```python
# ② app/gunicorn.conf.py —— worker 退出时清理自己的 mmap
def child_exit(server, worker):
    if os.getenv('PROMETHEUS_MULTIPROC_DIR'):
        from prometheus_client import multiprocess
        multiprocess.mark_process_dead(worker.pid)
```

```yaml
# ③ Deployment —— 提供可写目录
env:
  - name: PROMETHEUS_MULTIPROC_DIR
    value: /tmp/prometheus-multiproc
volumeMounts:
  - name: multiproc
    mountPath: /tmp/prometheus-multiproc
volumes:
  - name: multiproc
    emptyDir:
      sizeLimit: 32Mi
```

**启动前必须清空**，否则容器重启后 emptyDir 里的旧 mmap 会被重复统计：

```dockerfile
CMD ["sh", "-c", "rm -rf \"$PROMETHEUS_MULTIPROC_DIR\"/* 2>/dev/null; exec gunicorn -c gunicorn.conf.py app:app"]
```

### 6.5 快速止血方案

不能立即重建镜像时，降为单 worker：

```bash
kubectl -n sre-lab set env deploy/demo-api GUNICORN_WORKERS=1
```

单进程单计数器，指标立刻正确。代价是吞吐下降，**只是止损不是修复**。

### 6.6 验证

```bash
POD=$(kubectl -n sre-lab get pod -l app.kubernetes.io/name=demo-api -o jsonpath='{.items[0].metadata.name}')
kubectl -n sre-lab exec $POD -- wget -qO- http://127.0.0.1:8080/metrics | grep demo_http_requests_total
sleep 15
kubectl -n sre-lab exec $POD -- wget -qO- http://127.0.0.1:8080/metrics | grep demo_http_requests_total
```

两次值必须**单调递增且连续**。再查 `query_range`，`drops` 必须是 `0`。

> **注意**：如果镜像基于 `python:*-slim`，里面**没有 `curl` 也没有 `wget`**，
> `kubectl exec -- wget` 会静默返回空。用 python 代替：

```bash
kubectl -n sre-lab exec $POD -- python3 -c "
import urllib.request
d = urllib.request.urlopen('http://127.0.0.1:8080/metrics').read().decode()
for line in d.splitlines():
    if line.startswith('demo_http_requests_total') and 'path=\"/readyz\"' in line:
        print(line.split()[-1]); break
"
```

### 6.7 修复前后对照（本项目实测）

| 指标 | 修复前 | 修复后 |
| --- | --- | --- |
| 容器内计数器采样 | `53536 → 66702 → 53542 → 66708`（来回跳） | `3 → 6 → 9 → 12 → 15 → 18 → 21 → 24`（单调递增） |
| `query_range` 的 drops | 3 / 12 | **0 / 7** |
| `rate(/readyz[2m])` | **1366/s**（误报） | **0.400/s** |
| 真实值校验 | 探针 5s 一次 × 2 Pod = 0.4/s | ✅ 完全吻合 |
| 5xx 告警 | 注入 720 次 500 仍不触发 | 注入后 **pending → firing** |
| Alertmanager | 收不到 | 收到 `DemoApiHighErrorRate` active，停止注入后自动 resolved |

**误差 3400 倍**：`1366 / 0.4 = 3415`。这就是"指标看着有、数字全错"的危害量级。

### 6.8 预防

- 任何**多进程/多 worker** 的 Python 服务（gunicorn、uWSGI、celery）接入 Prometheus 前，
  先确认是否需要 multiprocess 模式。
- 上线监控后做一次**计数器连续性检查**：静置 5 分钟，`_total` 不能出现回退。
- 记住这类 bug 的危险性：**面板不报错、日志不报错、只有比率是错的**，
  会一直潜伏到真正需要告警的那天。

### ✅ 第 6 课自检

1. 为什么 2 个 gunicorn worker 会让 Prometheus 看到"计数器重置"？
2. 只看瞬时值为什么发现不了这个问题？
3. 三处修改里，漏掉 `child_exit` 会怎样？
4. 为什么 `emptyDir` 里的旧 mmap 文件要清掉？
5. 单 worker 为什么只是止血方案？

<details>
<summary>参考答案</summary>

1. 每个 worker 有独立的内存计数器，`/metrics` 只返回命中的那个。两次抓取落在不同 worker 时，观测值从小数跳到大数或反之，Prometheus 把下降解释为 reset。
2. 因为瞬时值可能恰好停在高值那次采样上，看起来完全正常。必须看 `query_range` 的序列连续性。
3. worker 被回收后 mmap 文件残留，`MultiProcessCollector` 会把死进程的计数继续累加，导致数值虚高，且随重启次数增长。
4. 容器重启后 emptyDir 内容仍在，旧文件会被当成活跃进程统计，造成重复计数。
5. 因为它把并发能力降到 1 个进程，吞吐和抗阻塞能力下降。正确修复是 multiprocess 模式，两者目的不同。

</details>

---

## 第 7 课 · 告警表达式设计

**学习目标**：会设计比率类告警，理解分母口径如何决定告警是否有效。

**前置**：第 6 课（指标必须正确，讨论表达式才有意义）。

### 7.1 核心概念：比率告警的成败在分母

```text
5xx 比例 = 5xx 请求数 / 总请求数
                ↑ 分子好写        ↑ 分母决定一切
```

如果分母里混进了高频的成功请求，比例会被**系统性稀释**。

### 7.2 现象

业务接口 100% 返回 500，但 5xx 比例只有 77%，达不到阈值。

### 7.3 诊断：先看分母构成

```promql
sum by (path) (rate(demo_http_requests_total[2m]))
```

本项目实测：

```text
/readyz          高频，永远 200    ← 探针
/healthz         高频，永远 200    ← 探针
/metrics         低频，永远 200    ← 抓取
/simulate/error  真实错误
```

**根因**：`readinessProbe` periodSeconds=5、`livenessProbe` periodSeconds=10，
持续产生 200。探针频率越高，稀释越严重。

### 7.4 处置：分母排除探针端点

```promql
(
  sum(rate(demo_http_requests_total{status=~"5..",path!~"/healthz|/readyz|/metrics"}[2m]))
  /
  (sum(rate(demo_http_requests_total{path!~"/healthz|/readyz|/metrics"}[2m])) > 0)
) > 0.05
```

两个细节都不能省：

| 细节 | 作用 |
| --- | --- |
| 分子分母都加 `path!~` | 口径必须一致，只改一边等于没改 |
| 分母 `> 0` | 无业务流量时避免 `0/0 = NaN` 导致规则异常 |

### 7.5 验证

```bash
# 有 promtool 时
promtool check rules k8s/monitoring/10-prometheus.yaml
```

注入错误流量后，比值应接近真实错误率，而不是被稀释后的值。

### 7.6 预防

设计 SLO 指标时就区分「业务流量」和「探针流量」。
**所有基于比率的告警都要显式声明分母口径**，并写进注释。

### ✅ 第 7 课自检

1. 探针多久跑一次？为什么它会影响错误率？
2. 只给分母加 `path!~` 行不行？
3. 为什么分母要 `> 0`？
4. 除了探针，还有哪些流量会污染分母？

<details>
<summary>参考答案</summary>

1. readiness 5s、liveness 10s。它们持续产生 200，抬高了分母，使真实错误率被稀释。
2. 不行。分子分母口径必须一致，否则算出来的是"某类错误占全部流量（含探针）的比例"，仍然是错的。
3. 无业务流量时分母为 0，`0/0` 得到 NaN，可能让规则报错或被误判为不满足条件。加 `> 0` 让条件短路为假。
4. `/metrics` 抓取、健康检查负载均衡器、监控系统的 blackbox 探测、CDN 回源健康检查等，任何自动化高频请求都算。

</details>

---

## 第 8 课 · 告警生命周期

**学习目标**：能区分"告警卡死"和"正常收敛"，不被窗口机制误导。

**前置**：第 7 课（表达式正确之后，才谈得上生命周期）。

### 8.1 核心概念：三个时间参数

```text
evaluation_interval   多久算一次（本项目 15s）
for                   连续满足多久才 Firing
窗口长度              表达式里的 [2m] / [15m]
```

告警消解时间 ≈ **故障恢复时间 + 窗口长度**（对 counter 类还要等样本滑出）。

### 8.2 现象

故障已修复、指标已恢复，但告警还挂在 Firing。

### 8.3 诊断：看指标，不看告警状态

```bash
curl -s 'http://127.0.0.1:9090/api/v1/query?query=increase(kube_pod_container_status_restarts_total%7Bnamespace%3D%22sre-lab%22%7D%5B15m%5D)'
# 值为 0 → 指标已恢复，告警迟早消解
```

### 8.4 本项目实测时间线

```text
T+0     CrashLoop 注入（command: /bin/false）
T+100s  4 次重启，PodRestartTooOften 进入 Pending
T+220s  TargetDown 与 PodRestartTooOften 均 Firing，Alertmanager 收到 active
T+230s  rollout undo，2/2 恢复
T+320s  TargetDown resolved（窗口 1m，很快）
T+15min PodRestartTooOften resolved（窗口 15m，等样本滑出）
```

**关键观察**：`TargetDown`（窗口 1m）先消解，`PodRestartTooOften`（窗口 15m）
晚了 14 分钟。这是**正常行为**。

### 8.5 三种"不消解"的判别

| 现象 | 判断 | 处理 |
| --- | --- | --- |
| 短窗口告警已消解，长窗口还在 | ✅ 正常，等窗口滑出 | 什么都不做 |
| 指标已恢复，所有告警都不动 | ❌ 规则或抓取异常 | 查 `/api/v1/rules` 的 `health`、查 target 是否 up |
| 一直 Pending 从不 Firing | ❌ `for` 大于窗口，或表达式恒假 | 缩短 `for` 或修正表达式 |

### 8.6 预防

演练记录里必须写清：**告警消解时间 ≠ 故障恢复时间**。
否则复盘时会把正常收敛误判成规则卡死，白花时间。

### ✅ 第 8 课自检

1. 为什么 `TargetDown` 比 `PodRestartTooOften` 先消解？
2. 指标已恢复但对所有告警都不动，先查什么？
3. 告警一直 Pending 从不 Firing，可能是哪两个原因？
4. 复盘时"恢复了"应该以什么为准？

<details>
<summary>参考答案</summary>

1. 因为窗口长度不同：`TargetDown` 用瞬时 `up == 0` + `for: 1m`，指标恢复即刻消解；`PodRestartTooOften` 用 `increase[15m]`，要等 15 分钟内的重启样本全部滑出。
2. 先查 `/api/v1/rules` 的 `health` 是否为 ok，再查 `/api/v1/targets` 是否 up。规则加载失败或抓取断了，告警状态就会冻结。
3. ① `for` 时长大于表达式窗口长度，永远凑不满；② 表达式恒为假（分母为 0、标签写错、指标名不存在）。
4. 以**指标**为准，不是以告警状态为准。告警状态有窗口滞后。

</details>

---

## 第 9 课 · 变更校验流程

**学习目标**：建立固定的发布前三步校验习惯，理解 client / server 两种 dry-run 的边界。

**前置**：前 8 课（知道该校验什么）。

### 9.1 核心概念：dry-run 有两个级别，用途不同

| 级别 | 校验内容 | 需要对象存在 |
| --- | --- | --- |
| `--dry-run=client` | 语法、字段类型、基本结构 | ❌ 不需要 |
| `--dry-run=server` | 准入控制、默认值填充、引用存在性 | ✅ 需要 |

### 9.2 一个真实的坑：`set image` 不会应用 env 和 volume

**本项目实际踩到**：用 `opsctl deploy` / `kubectl set image` 发布新镜像，
Pod 成功 Running、镜像也对，但新加的 `PROMETHEUS_MULTIPROC_DIR` 环境变量
和 `emptyDir` 挂载**根本没有生效**：

```bash
kubectl -n sre-lab get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'
# 输出：PORT                                    ← 只有旧的，新增的全丢了
```

**原因**：`set image` 只修改 `.spec.template.spec.containers[0].image` 这一个字段，
清单里其他改动不会同步。用 `set image` 部署"代码没问题"，但"配置没更新"。

**正确流程**：

```bash
# ① 渲染出带具体 SHA 的清单（把模板里的 latest 换成真实版本）
SHA=<commit-sha>
sed "s|image: ghcr.io/0tinna/sre-devops-lab:latest|image: ghcr.io/0tinna/sre-devops-lab:$SHA|" \
  k8s/app.yaml > /tmp/app-render.yaml

# ② 先校验
kubectl apply --dry-run=client -f /tmp/app-render.yaml

# ③ 再 apply（env / volume / probe / 资源全部同步）
kubectl apply -f /tmp/app-render.yaml
kubectl -n sre-lab rollout status deploy/demo-api --timeout=300s

# ④ 确认关键字段真的进去了
kubectl -n sre-lab get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].env[*].name}{"\n"}'
```

**判断规则**：

| 改动范围 | 用哪个 |
| --- | --- |
| 只换镜像版本（热修） | `set image` 可以 |
| 改了 env / volume / probe / resources / 安全上下文 | **必须 `apply`** |
| 不确定 | 永远用 `apply` |

**教训**：`rollout status` 成功不代表"想要的配置生效了"。
它只保证"Pod 起来了"，不保证"Pod 用的是你以为的那份配置"。
**每次发布后都要抽查关键字段**，这是第 9 课的核心习惯。

### 9.3 更隐蔽的坑：`rollout undo` 不等于回到好版本

**本项目实测踩到**：连续两次推送坏镜像后执行 `opsctl rollback`，结果**仍然是坏的**。

```text
1) opsctl deploy <bad-tag-1>   → revision 17，ErrImagePull
2) opsctl deploy <bad-tag-2>   → revision 18，ErrImagePull
3) opsctl rollback             → 退出码 1，image 仍是 <bad-tag-1>！
```

**原因**：`rollout undo` 只**回退一步**（到上一个 revision）。
如果上一个 revision 本身就是坏的，回退等于没回退。

**更糟的是**：undo 回退的是**整个 Pod template**，不只是镜像。
本项目历史 ReplicaSet 里只有当前那个带完整 5 个 env，更早的都只有 `PORT`——
一旦 undo 落到它们身上，`PROMETHEUS_MULTIPROC_DIR` 会一起丢掉，指标问题复发。

**正确做法**：回滚前先确认目标 revision 是好版本，否则直接 `apply` 已知good的清单。

```bash
# ① 先看每个 revision 的实际配置，不要只看编号
for rs in $(kubectl -n sre-lab get rs -o name); do
  echo "$rs"
  kubectl -n sre-lab get $rs -o jsonpath='  image={.spec.template.spec.containers[0].image}{"\n"}'
  kubectl -n sre-lab get $rs -o jsonpath='  env={.spec.template.spec.containers[0].env[*].name}{"\n"}'
done

# ② 目标明确才 undo，且 undo 后立刻验证
kubectl -n sre-lab rollout undo deploy/demo-api
kubectl -n sre-lab get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
kubectl -n sre-lab get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].env[*].name}{"\n"}'

# ③ 不确定时：直接 apply 一份已知good的清单，这是唯一可靠的回滚
sed "s|:latest|:<known-good-sha>|" k8s/app.yaml > /tmp/app-render.yaml
kubectl apply -f /tmp/app-render.yaml
```

**判断规则**：

| 场景 | 用什么 |
| --- | --- |
| 只回退一步，且上一版确认是好的 | `rollout undo` |
| 连续多次坏发布 | **`apply` 已知good清单** |
| 配置也变了（env/volume/probe） | **`apply`**，undo 会连带丢配置 |
| 不确定 | **`apply`** |

**教训**：`rollout undo` 是"撤销上一步操作"的指令，不是"回到健康状态"的指令。
这两件事在故障场景下经常不等价。

### 9.4 另一个静默失败：管道会吞掉退出码

**本项目实测**：

```bash
python3 scripts/opsctl.py deploy <bad-image> 2>&1 | tail -3
echo $?      # 输出 0 ！
```

`opsctl deploy` 内部正确返回了 `1`，但管道让 `$?` 变成了 `tail` 的退出码 `0`。
**发布失败被脚本判定成功了**——在 CI 里这就是"流水线绿灯但部署是坏的"。

**正确写法**：

```bash
# ① 不走管道，先存日志再判断
python3 scripts/opsctl.py deploy <image> >/tmp/deploy.log 2>&1
rc=$?
tail -3 /tmp/deploy.log
[ $rc -eq 0 ] || { echo "部署失败"; exit 1; }

# ② 既要看输出又要退出码，用 PIPESTATUS
python3 scripts/opsctl.py deploy <image> 2>&1 | tee /tmp/deploy.log
rc=${PIPESTATUS[0]}
```

**适用场景**：任何「命令 | 过滤」后判断成败的地方——CI 脚本、巡检脚本、
`kubectl ... | grep` 后判断是否有输出。

### 9.5 现象：dry-run 报 namespace 不存在

校验多文档清单时大量报错：

```text
Error from server (NotFound): error when creating "00-namespace-rbac.yaml":
namespaces "monitoring" not found
```

### 9.6 根因

`--dry-run=server` 会真的走到 API server 做校验，但**不会真的创建 namespace**，
所以后续对象引用的 namespace 不存在。**这是预期行为，不是清单写错。**

### 9.7 处置：固定三步流程

```bash
# ① 静态校验：不需要依赖对象存在
kubectl apply --dry-run=client -f k8s/monitoring/

# ② 实际创建
kubectl apply -f k8s/monitoring/

# ③ 观察收敛
kubectl -n monitoring get pods -w
```

**本项目实际做法**：先用 client 校验全部 21 个对象通过，再真正 apply。
server dry-run 只在 namespace 已存在时才有意义。

### 9.8 验证清单

发布前必查：

```bash
python -m py_compile app/app.py              # Python 语法
python -m unittest discover -s tests         # 单元测试
kubectl apply --dry-run=client -f <dir>      # 清单结构
```

发布后必查（**不只是看 Pod 起来没有**）：

```bash
kubectl -n <ns> rollout status deploy/<name> --timeout=300s
kubectl -n <ns> get pods
kubectl -n <ns> get events --sort-by=.lastTimestamp | tail

# 关键：抽查"我这次改的字段"是否真的生效
kubectl -n <ns> get deploy <name> -o jsonpath='{.spec.template.spec.containers[0].env[*].name}{"\n"}'
kubectl -n <ns> get deploy <name> -o jsonpath='{.spec.template.spec.containers[0].image}{"\n"}'
```

**用 python 验证应用行为**（slim 镜像里没有 curl/wget）：

```bash
kubectl -n <ns> exec <pod> -- python3 -c "
import urllib.request, urllib.error
for p in ['/healthz','/readyz','/simulate/error']:
    try:
        r = urllib.request.urlopen('http://127.0.0.1:8080'+p)
        print(p, r.status, r.read()[:60])
    except urllib.error.HTTPError as e:
        print(p, e.code, e.read()[:60])
"
```

### 9.9 预防

把校验写进 CI，而不是靠人记得。本项目 `ci.yml` 已经包含
compile check + unit test，`--dry-run` 因为需要集群凭证所以留给本地/部署机执行。

### ✅ 第 9 课自检

1. 只跑 `--dry-run=server` 校验新命名空间的清单，会得到什么结果？
2. 为什么 CI 里不做 `--dry-run=server`？
3. 发布后 `rollout status` 成功，能说明配置生效了吗？
4. 用 `set image` 发布一个"同时改了 env"的版本，会发生什么？
5. 连续两次坏发布后 `rollout undo`，为什么可能还是坏的？
6. `cmd 2>&1 | tail -3; echo $?` 输出 0，说明命令成功了吗？
7. 校验清单时 client 和 server 应该都跑吗？

<details>
<summary>参考答案</summary>

1. 大量 `namespaces "xxx" not found`，因为 server dry-run 不创建 namespace，后续对象引用不到。
2. 因为 server dry-run 需要连接真实集群和凭证。公网 CI runner 不应该持有集群 kubeconfig（本项目明确不采用这个方案）。
3. 不能。`rollout status` 只保证"Pod 起来且就绪"，不保证"Pod 用的是你以为的那份配置"。本项目实际踩过：镜像更新成功，但新增的 env 和 emptyDir 全部没生效，Pod 照样 Running。
4. 只有镜像字段被更新，env / volume / probe 等改动全部丢失，且不会有任何报错。表现为"新代码在跑，但新配置没生效"，极难排查。
5. 因为 `undo` 只回退一步到上一个 revision，而上一个本身就是坏的。而且它回退整个 Pod template，配置也可能一起退回旧版。此时唯一可靠的做法是 `apply` 一份已知good的清单。
6. 不能。`$?` 拿到的是管道末端 `tail` 的退出码。要用 `cmd >log 2>&1; rc=$?` 或 `${PIPESTATUS[0]}`。本项目因此差点把一次失败发布判成成功。
7. 建议都跑：client 快速抓语法错误，server 在依赖存在时做语义校验。顺序是先 client 后 server。

</details>

---

## 附录 A · 诊断命令速查

```bash
# ── 层次定位 ──────────────────────────────────────────
kubectl get nodes -o wide                                    # 节点层
kubectl -n <ns> get pods -o wide                             # 调度层
kubectl -n <ns> describe pod <pod> | sed -n '/Events/,$p'    # 事件层（最权威）
kubectl -n <ns> logs <pod> --tail=50                         # 应用层
kubectl -n <ns> logs <pod> --previous                        # 崩溃前的日志

# ── 镜像 ─────────────────────────────────────────────
crictl pull <image>                                          # 绕过 k8s 直接测
crictl images | grep <name>
curl -s -o /dev/null -w "%{http_code}\n" https://<registry>/v2/

# ── 探针 / 就绪 ───────────────────────────────────────
kubectl -n <ns> get endpoints                                # NotReady 的直接后果
kubectl -n <ns> run probe --rm -i --restart=Never \
  --image=docker.m.daocloud.io/library/busybox:1.36 \
  --command -- wget -qS -O /dev/null http://<POD_IP>:<PORT><PATH>

# ── 指标正确性 ────────────────────────────────────────
# 计数器必须单调递增，出现回退 = 第 6 课
curl -s 'http://127.0.0.1:9090/api/v1/query_range?query=<metric>&start=..&end=..&step=15'
curl -s 'http://127.0.0.1:9090/api/v1/targets'   # 抓取是否 up
curl -s 'http://127.0.0.1:9090/api/v1/rules'     # 规则 health 是否 ok
curl -s 'http://127.0.0.1:9090/api/v1/alerts'    # 当前告警状态
curl -s 'http://127.0.0.1:9093/api/v2/alerts'    # Alertmanager 是否真的收到

# ── 发布 / 回滚 ───────────────────────────────────────
kubectl -n <ns> rollout status deploy/<name> --timeout=120s
kubectl -n <ns> rollout undo deploy/<name>
kubectl -n <ns> rollout history deploy/<name>
```

## 附录 B · 问题速查索引

| 课 | 症状关键词 | 一句话根因 |
| --- | --- | --- |
| 1 | `Permission denied`、`filename too long`、传文件失败 | 公钥只在跳板机；命令行有长度上限 |
| 2 | `ImagePullBackOff`、`no such host`、`timeout` | 分 DNS / 网络 / 权限 / 标签四类 |
| 3 | `CreateContainerConfigError`、`non-numeric user` | `USER app` 非数字，`runAsNonRoot` 无法验证 |
| 4 | `Pending`、`untolerated taint`、`Insufficient memory` | 资源与污点双重约束 |
| 5 | `Running` 但 `0/1`、Endpoint 为空、探针 404 | 探针端口/路径写错（8081 只有 `/readyz`） |
| 6 | 告警永不触发、`rate()` 离谱 | 多 worker 计数器互相覆盖 |
| 7 | 错误率偏低、阈值达不到 | 探针高频 200 稀释分母 |
| 8 | 告警长时间不消解 | 长窗口样本未滑出，正常 |
| 9a | 改了 env/volume 但没生效、`set image` 后行为异常 | `set image` 只改镜像字段 |
| 9b | 回滚后还是坏的 | `undo` 只回退一步，且回退整个 template |
| 9c | 脚本判定发布成功但实际失败 | 管道吞掉了前一条命令的退出码 |
| 9d | dry-run 报 namespace 不存在 | server dry-run 不创建依赖对象 |

## 附录 C · 复盘方法论

1. **先找证据，再下结论。** `describe` 的 Events 比任何猜测都权威。
2. **一次只改一个变量。** 同时改探针路径和镜像版本，就永远不知道哪个生效了。
3. **测量要能证伪。** "大概是端口问题"不是测量；逐端口逐路径探测才是。
4. **区分「服务不可用」和「监控说服务不可用」。** 第 6、7 课都属于后者，服务其实健康。
5. **修复时想清为什么会发生。** 第 3 课的预防是"永远用数字 UID"，不是"这次改成 10001"。
6. **把结论写回代码注释。** 第 5 课的端点分布写在 YAML 里，下次不用再探一遍。

---

## 附录 D · 工具与集群版本兼容性（真实案例）

**这一节讲的是"用对方法也修不好"的一类问题**：工具本身有 bug 或与集群版本不兼容，
所有配置都正确、所有权限都正常，但它就是不工作，而且**不报错**。

### D.1 现象

部署 Promtail 采集 K8s 日志，Pod 状态：

```text
Running 但 READY 0/1
logs: Not ready: Unable to find any logs to tail. Please verify permissions, volumes, scrape_config, etc.
promtail_targets_active_total 0
/service-discovery 页面: kubernetes-pods (0/0 active targets)
```

日志里**没有任何 error**，只有这句"找不到可 tail 的日志"。

### D.2 你以为的原因（都在第 5 课的常规套路里）

按顺序排除了所有常见原因：

| 检查项 | 结果 |
| --- | --- |
| hostPath 挂载 | `/var/log/pods` 在容器内可读，能看到所有 pod 目录 |
| 文件路径 glob | 容器内手工 `ls /var/log/pods/*<uid>/*/*.log` 能匹配到文件 |
| RBAC 权限 | `kubectl auth can-i list pods --as=system:serviceaccount:monitoring:promtail -A` → **yes** |
| DNS 解析 | `getent hosts kubernetes.default.svc` → `10.96.0.1` |
| SA token | `/var/run/secrets/kubernetes.io/serviceaccount/token` 存在 |
| API 连通性 | 容器内 openssl 直连返回 `HTTP/1.1 200 OK` + 完整 PodList |

**全部正常，但 discovery 就是 0 targets。**

### D.3 决定性的二分实验

换一种 `scrape_configs`，其他全不变：

| 配置方式 | 结果 |
| --- | --- |
| `static_configs` + 固定 `__path__` glob | **target=1，ready 200，tail 正常启动** |
| `kubernetes_sd_configs` + relabel 拼 `__path__` | target=0，ready 500 |

**同一份二进制、同样的挂载、同样的权限，只有 discovery 方式不同。**
结论：Promtail（2.9.4 和 3.5.0 都测了）的 `kubernetes_sd_configs`
在 K8s **v1.34.1** 上静默失效。

### D.4 处置

换成 **Fluent Bit 3.1.9**。它的 `tail` input 直接扫 `/var/log/containers/*.log`，
**不依赖 API 做文件发现**，元数据用 `kubernetes` filter 补（这一步实测正常）：

```ini
[INPUT]
    Name tail
    Path /var/log/containers/*.log
    Tag kube.*
[FILTER]
    Name kubernetes
    Kube_Tag_Prefix kube.var.log.containers.
```

启动日志直接给出判据：

```text
[filter:kubernetes] connectivity OK
[filter:kubernetes] local POD info OK
[input:tail:tail.0] inotify_fs_add(): ... name=/var/log/containers/demo-api-xxx.log
```

### D.5 判断流程（遇到"怎么配都不工作"时）

```text
① 有没有明确的错误？       有 → 按错误查（常规路径）
② 没有错误但功能缺失       → 进入 ③
③ 做二分实验：
     把可疑组件换成最简可用配置（static / 硬编码 / 无过滤器）
     能工作 → 问题在那个特性，不在组件本身
     也不能 → 问题在环境（网络/权限/挂载）
④ 查版本兼容性：
     集群版本 vs 工具版本
     工具的 client-go / SDK 版本
⑤ 换实现：同类工具通常有 2-3 个可选，别在一棵树上吊死
```

### D.6 关键教训

| 教训 | 说明 |
| --- | --- |
| **"没报错"不等于"没问题"** | 这类 bug 只表现在功能缺失上，日志干净得很 |
| **二分是最快的定位手段** | 换一个变量做对比，比读源码快得多 |
| **不要假设官方组件一定适配** | K8s 小版本迭代快，采集类工具的兼容性常落后 |
| **保留证据再换方案** | 记下"什么配置 + 什么版本 + 什么结果"，否则换完就说不清了 |

### D.7 同类风险清单

| 场景 | 常见坑 |
| --- | --- |
| Promtail / Alloy 的 K8s SD | 新版本 K8s 上 discovery 失效 |
| 老版 client-go 的 operator | 新 K8s 的 CRD 字段解析失败 |
| Fluent Bit 的插件参数 | 版本间参数改名，写错直接 CrashLoop（本项目也踩了 `total_limit_size`） |
| Helm chart 的 apiVersion | 老 chart 用已废弃的 API 版本 |
| 监控 exporter 的指标名 | 版本升级后指标改名，告警表达式失效 |

**共同点**：都是"配置看起来对、但版本不匹配"，报错信息通常指向别处。

---
