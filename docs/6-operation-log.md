# 操作审计记录

> **这是一份按时间累积的审计日志，不是状态快照。**
>
> 每一节记录的是"**当时**发生了什么、看到的数字是什么"，所以你会在这里看到
> 6/6 Pod、7/7 target、10 条告警这类早期数字——它们在当时是准确的，现在不是。
>
> **想知道当前状态，读 [`8-handoff.md`](8-handoff.md)。**
>
> 记录范围：2026-10-29 起，按阶段追加。第 10–19 节是 P1–P7 各阶段的现场记录。

记录日期：2026-10-29（首次）

执行者：Codex / DSH（在用户授权下执行）

## 目录

按阶段查，不要通读：

| 节 | 内容 | 时间 |
| --- | --- | --- |
| [1](#1-连接与只读盘点) – [5](#5-github-与部署密钥) | 初始搭建：盘点、资源检查、本地创建、传输、部署密钥 | 2026-10-29 |
| [6](#6-尚未开始的部分) | **当时**尚未开始的部分（历史，现均已完成） | 2026-10-29 |
| [7](#7-失败与回退记录) | 早期失败与回退 | 2026-10-29 |
| [8](#8-如何复核) | 如何独立复核本文的所有结论 | — |
| [9](#9-后续操作约定) | 操作约定 | — |
| [10](#10-2026-11-05-监控阶段) | **P1 监控阶段**：部署监控栈、定位两个静默故障 | 2026-11-05 |
| [11](#11-2026-11-05-未执行的操作) | P1 期间明确没做的事 | 2026-11-05 |
| [12](#12-2026-11-05-排查-sop-归档) | SOP 归档 | 2026-11-05 |
| [13](#13-2026-11-05-项目整理与发布验证) | SOP 重构、multiprocess 修复验证 | 2026-11-05 |
| [14](#14-2026-11-05-15231550-p2-故障演练全量执行) | **P2 故障演练**：七项演练全量执行 | 2026-11-05 |
| [15](#15-2026-11-05-16201650-p4-日志集中化) | **P4 日志集中化**：Promtail 静默失效 → Fluent Bit | 2026-11-05 |
| [16](#16-2026-11-05-16551710-演练场景扩展到日志维度) | 演练场景扩到日志维度（场景 9、10） | 2026-11-05 |
| [17](#17-2026-11-06-09150945-p5-自动扩缩容与告警补全) | **P5 自动扩缩容**：metrics-server + HPA 实测 | 2026-11-06 |
| [18](#18-2026-11-06-10201120-p6-可用性加固) | **P6 可用性加固**：PDB、镜像预热、drain 死锁 | 2026-11-06 |
| [19](#19-2026-11-06-14101500-p7-死告警审计与容器级指标) | **P7 死告警审计**：3 条死告警、cAdvisor、镜像分发 | 2026-11-06 |

**只想看最有价值的部分**：§15（工具静默失效）、§18.4（PDB 的正确性依赖替身就绪）、
§19.2–§19.3（死告警为什么查不出来）、§19.10（永不消解的告警）。

## 结论先行（2026-10-29 首次记录）

> 下面这份结论是**第一次记录当天**的状态，不是当前状态。
> 当前状态见 [`8-handoff.md`](8-handoff.md)。

已经执行的操作：

- 通过跳板机只读盘点 master、node 和 Kubernetes 集群。
- 在本地创建项目文件、文档和测试。
- 将项目传输到 master 的 `/opt/sre-devops-lab`。
- 在 master 初始化 Git 仓库并完成多次本地提交。
- 在 master 生成专用 GitHub 部署密钥。
- 配置 Git remote 为 `git@github.com:0tinna/sre-devops-lab.git`。
- 将全部 Markdown 文档改为中文。
- 通过只读检查确认：push、GitHub Actions、GHCR 镜像拉取和 Deployment 创建均已发生。

用户后续执行的操作：

- 在 GitHub 添加部署密钥，并完成首次 push。
- GitHub Actions `ci` 由 push 自动触发，运行结果为 success。
- GHCR 镜像已生成，并已被 node 节点拉取。
- `sre-lab` 命名空间、Deployment 和 Service 已创建。
- 修复非数字 UID 后，Deployment 已滚动更新成功，Pod 为 2/2 Running，健康检查和指标端点返回 200。

Codex 没有执行的操作：

- Codex 没有执行 `git push`。
- Codex 没有手动触发 GitHub Actions。
- Codex 没有创建或修改 Kubernetes 业务资源。
- Codex 没有安装 Helm、Prometheus、Grafana 或 Alertmanager。
- Codex 没有修改 kube-system、CNI、CoreDNS 或节点配置。

重要说明：Codex 侧的集群操作均为只读查询；当前 `sre-lab` 资源是用户侧操作产生的。镜像拉取已经成功，当前故障不是镜像拉取失败，而是容器启动配置错误。

## 状态图例

- `[x]`：已经由 Codex 执行。
- `[ ]`：等待用户操作，或等待后续阶段执行。
- `只读`：只查询信息，不改变集群状态。
- `写操作`：创建文件、提交 Git、生成密钥或修改配置。

## 1. 连接与只读盘点

| 序号 | 位置 | 操作 | 结果 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | 本地 Windows | 检查 `ssh` 和 `~/.ssh/id_ed25519` 是否存在 | 密钥存在，SSH 由沙箱包装 | 只读 |
| 2 | 跳板机 1.95.123.118 | 执行 `hostname、whoami、uname -a` | 主机为 `ecs-guizhou-9month-2mbit` | 只读 |
| 3 | 跳板机到 master | 通过跳板机 SSH 到 172.31.6.211 | 主机名为 `master` | 只读 |
| 4 | master | `kubectl get nodes -o wide` | master、node 均为 Ready | 只读 |
| 5 | master | `kubectl get pods -A -o wide` | CoreDNS、etcd、apiserver、controller-manager、scheduler、kube-proxy、Flannel | 只读 |
| 6 | master | `kubectl get deploy,sts,ds,svc,ingress -A` | 只有系统组件，没有业务工作负载 | 只读 |
| 7 | master | `kubectl get pv,pvc -A` 和 `kubectl get sc` | 无存储资源 | 只读 |
| 8 | master | `kubectl get --raw='/readyz?verbose'` | 输出 `readyz check passed` | 只读 |
| 9 | node | 检查 kubelet、containerd、时间同步、内存和磁盘 | kubelet 与 containerd 正常，时间同步正常 | 只读 |

## 2. 资源与网络检查

| 序号 | 位置 | 操作 | 结果 | 状态 |
| --- | --- | --- | --- | --- |
| 10 | master | `nproc、free -h、df -h` | 4 vCPU、15 GiB 内存、178 GiB 磁盘 | 只读 |
| 11 | master | 检查 `kubectl、kubeadm、helm、git、docker、curl` | Helm 未安装，其余工具存在 | 只读 |
| 12 | master | 访问 Docker Hub | 连接超时 | 只读 |
| 13 | master | 访问华为云 SWR 端点 | 端点有响应 | 只读 |
| 14 | master | 使用 `crictl pull` 测试华为云公共镜像路径 | 返回 401 Unauthorized | 只读，未修改集群资源 |
| 15 | master | 检查已存在镜像 | 已有 Flannel、CoreDNS、etcd 和 Kubernetes 系统镜像 | 只读 |

网络结论：Docker Hub 不可达，GHCR 可用，因此项目镜像选择 GHCR。

## 3. 本地项目创建与校验

| 序号 | 位置 | 操作 | 结果 | 状态 |
| --- | --- | --- | --- | --- |
| 16 | 本地 | 创建 `C:\Users\qitin\Documents\sre-devops-lab` | 项目目录存在 | 写操作 |
| 17 | 本地 | 创建 Flask 应用、Dockerfile、K8s 清单、CI、测试和文档 | 文件已生成 | 写操作 |
| 18 | master | 将 Python 文件送到 `/tmp` 并执行 `py_compile` | 语法检查通过 | 写操作，临时文件已删除 |
| 19 | master | 对 K8s YAML 执行 `kubectl apply --dry-run=client` | namespace、deployment、service 均为 dry run 成功 | 只读校验，没有创建资源 |
| 20 | master | 执行 `python3 scripts/opsctl.py --help` | 命令入口正常 | 只读校验 |

## 4. 项目传输与 Git 操作

| 序号 | 位置 | 操作 | 结果 | 状态 |
| --- | --- | --- | --- | --- |
| 21 | 本地到跳板机 | 通过 `scp` 传输项目归档 | 传输成功 | 写操作 |
| 22 | 跳板机到 master | 通过 `scp` 传输项目归档 | 传输成功 | 写操作 |
| 23 | master | 解压到 `/opt/sre-devops-lab` | 项目文件就位 | 写操作 |
| 24 | master | `git init -b main` | 创建 main 分支 | 写操作 |
| 25 | master | 配置 `user.name=0tinna`、`user.email=0tinna@users.noreply.github.com` | 仅作用于当前仓库 | 写操作 |
| 26 | master | 提交 `b7f3cef Initial SRE DevOps lab` | 第一次提交 | 写操作 |
| 27 | master | 添加 remote `git@github.com:0tinna/sre-devops-lab.git` | remote 配置成功 | 写操作 |
| 28 | master | 添加 GitHub 推送 SOP 并提交 `3008335` | 第二次提交 | 写操作 |
| 29 | master | 将文档改为中文并提交 `fe6440f` | 第三次提交，当前 HEAD | 写操作 |

## 5. GitHub 与部署密钥

| 序号 | 位置 | 操作 | 结果 | 状态 |
| --- | --- | --- | --- | --- |
| 30 | master | 执行 `git ls-remote https://github.com/0tinna/sre-devops-lab.git` | 成功，仓库为空 | 只读 |
| 31 | master | 执行 `ssh -T git@github.com` | Permission denied，说明还没有可用 GitHub SSH 权限 | 只读 |
| 32 | master | 生成 `/root/.ssh/github_sre_lab_ed25519` | 私钥和公钥已生成 | 写操作 |
| 33 | GitHub 网页 | 添加 Deploy Key 并勾选 Allow write access | 已完成，用户操作 | 写操作 |
| 34 | master | `git push -u origin main` | 已完成，用户操作；origin/main 为 `03bea91` | 写操作 |

## 6. 尚未开始的部分

> **历史记录（2026-10-29 当时快照）**：这是首次记录当天的状态，表中未完成项后来已全部落地：
> 监控在 §10（P1）、告警与指标在 §17/§19、故障演练在 §14（P2）。当前状态见 [`8-handoff.md`](8-handoff.md)。

| 项目 | 当时状态 (2026-10-29) | 说明 |
| --- | --- | --- |
| GitHub Actions 运行 | 已完成 | run 40799208887，结论 success |
| GHCR 镜像 | 已生成 | `ghcr.io/0tinna/sre-devops-lab:03bea91...` 已被节点拉取 |
| Kubernetes 业务部署 | 已就绪 | Deployment 2/2 Running |
| 镜像数字 UID 修复 | 已完成 | 提交 `652760f`，GHCR 镜像已重新构建并部署 |
| 修复后验证 | 已完成 | `/healthz` 和 `/readyz` 返回 200，`/metrics` 可访问 |
| Prometheus / Grafana | 未安装 | 下一阶段 |
| 告警规则 | 未配置 | 下一阶段 |
| 故障演练 | 未执行 | 下一阶段 |
| 面试项目最终演示 | 未完成 | 需要先修复容器启动问题 |

## 6.1 2026-10-29 容器启动故障

观察到的现象：

- Deployment 为 `0/2`。
- Pod 状态为 `CreateContainerConfigError`。
- Pod Events 中已经出现 `Pulled`，说明镜像拉取成功。
- 关键错误：`container has runAsNonRoot and image has non-numeric user (app), cannot verify user is non-root`。

根因：

Dockerfile 中使用了 `USER app`，镜像配置里的 User 字段是字符串 `app`。Kubernetes 在 `runAsNonRoot: true` 时无法仅凭用户名证明 UID 不是 0，因此拒绝启动容器。

修复：

- Dockerfile 使用数字 UID/GID：`USER 10001:10001`。
- Pod securityContext 增加 `runAsUser: 10001`、`runAsGroup: 10001`、`fsGroup: 10001`。
- 需要重新提交、push、等待 GitHub Actions 构建新镜像，再滚动更新 Deployment。

结论：这不是镜像拉取失败，也不需要本地伪造镜像来绕过。修复数字 UID 后，继续使用 GHCR 的真实拉取链路。

## 6.2 2026-10-29 修复验证

修复提交：`652760f82a18226b95eefa860b8d15fa8a12635d`

GitHub Actions 结果：成功。

Kubernetes 验证结果：

- Deployment 为 `2/2`。
- 两个 Pod 均为 `Running`。
- 新镜像从 GHCR 成功拉取：`ghcr.io/0tinna/sre-devops-lab:652760f82a18226b95eefa860b8d15fa8a12635d`。
- `/healthz` 返回 HTTP 200。
- `/readyz` 返回 HTTP 200。
- `/metrics` 返回 Prometheus 指标。
- Gunicorn 启动日志正常。

这次验证证明：镜像拉取链路正常，之前的故障是容器用户配置问题，不是网络或 GHCR 拉取失败。

## 7. 失败与回退记录

| 尝试 | 结果 | 处理方式 |
| --- | --- | --- |
| Pod 启动失败 | `CreateContainerConfigError` | 判定为镜像 USER 非数字，改为 `USER 10001:10001` 并设置 runAsUser |
| 本地 SSH 直连 master | master 不信任本地公钥 | 改为通过跳板机转发 |
| 使用 ProxyJump 直连 master | Permission denied | 改为跳板机内执行 SSH |
| 华为云 SWR 公共镜像路径 | 401 Unauthorized | 放弃该路径，改用 GHCR |
| 一次 `opsctl.py` 校验 | 被用户中断 | 后续重新执行并成功 |
| 本地 PowerShell 拼接长命令 | 引号解析失败 | 改用 Base64 脚本或短命令 |
| 本地根目录创建项目 | ACL 拒绝 | 改到 `Documents\sre-devops-lab` |

## 8. 如何复核

在 master 执行：

```bash
cd /opt/sre-devops-lab
git status
git log --oneline --decorate -5
git remote -v
find . -maxdepth 2 -type f | sort
```

查看集群是否仍然只有系统组件：

```bash
kubectl get pods -A
kubectl get deploy -A
kubectl get svc -A
```

确认没有创建业务资源：

```bash
kubectl get namespace sre-lab
```

如果返回 `NotFound`，说明业务命名空间还没有创建，符合当前记录。

## 9. 后续操作约定

从现在开始，SOP 中会明确区分：

- `[x]` 我已经执行的步骤。
- `[ ]` 需要你执行的步骤。
- `只读` 不会改变集群。
- `写操作` 会改变本地文件、Git 仓库或集群状态。

任何会创建 Kubernetes 资源、安装组件、修改权限或推送代码的操作，都会在 SOP 中单独标注，并说明预期结果和回滚方式。

## 10. 2026-11-05 监控阶段

执行者：Little Code Sauce（本地 + 经跳板机 1.95.123.118 到 master 172.31.6.211）

### 10.1 只读复核

| 序号 | 位置 | 操作 | 结果 |
| --- | --- | --- | --- |
| 35 | master | `kubectl get nodes/pods/deploy` | 两节点 Ready，demo-api 2/2 Running，0 重启，已稳定 6 天 |
| 36 | master | 节点 allocatable 与已用资源 | master 4C/15.5GiB，已用 950m CPU、290Mi 内存；node 2C/3.6GiB，内存 request 占 14% |
| 37 | master | `kubectl describe nodes` 看 taint | master 带 `control-plane:NoSchedule` |
| 38 | master | 存储与插件检查 | 无 StorageClass/PV/PVC，无 metrics-server，无 helm |
| 39 | master | 各 registry 可达性 | Docker Hub 超时；quay.io API 通但 blob 下载 60s 超时；ghcr.io 正常；`docker.m.daocloud.io` 可用；`registry.k8s.io` 会 307 到 `europe-west3-docker.pkg.dev`，本环境 DNS 解析失败 |

### 10.2 镜像预拉取（写操作：仅填充本地镜像缓存）

| 镜像 | 耗时 | 结果 |
| --- | --- | --- |
| `docker.m.daocloud.io/prom/alertmanager:v0.28.1` | 58s | OK |
| `docker.m.daocloud.io/prom/node-exporter:v1.9.1` | 16s | OK |
| `docker.m.daocloud.io/prom/prometheus:v3.6.0` | 114s | OK |
| `docker.m.daocloud.io/grafana/grafana:12.2.0` | 218s | OK |
| `k8s.m.daocloud.io/kube-state-metrics/kube-state-metrics:v2.16.0` | 25s | OK（`registry.k8s.io` 直连失败后改走 daocloud 的 k8s 源） |

### 10.3 部署监控栈（写操作）

清单在 `k8s/monitoring/`，全部先通过 `kubectl apply --dry-run=client` 校验，再 apply 到 `monitoring` 命名空间。

| 组件 | 调度 | 资源上限 | 结果 |
| --- | --- | --- | --- |
| Prometheus v3.6.0 | master | 500m / 512Mi | Running |
| Alertmanager v0.28.1 | master | 200m / 128Mi | Running |
| kube-state-metrics v2.16.0 | master | 300m / 256Mi | Running |
| Grafana 12.2.0 | master | 300m / 256Mi | Running |
| node-exporter v1.9.1 | 两个节点 | 各 100m / 64Mi | 2/2 Running |

### 10.4 过程中定位并修复的两个问题

**问题 1：kube-state-metrics 永远 NotReady，Service 没有 Endpoint**

- 现象：Pod Running 但 `0/1 READY`，Events 里 `Readiness probe failed: statuscode: 404`。
- 排查：用临时 busybox Pod 直连 `10.244.0.6` 逐端口逐路径探测。
- 实测端点分布：`8080` 上 `/healthz`=200、`/livez`=200、`/readyz`=404；`8081` 上 `/readyz`=200、`/healthz`=404。
- 根因：就绪探针写成了 `8081/healthz`，该路径在 telemetry 端口不存在。
- 修复：readiness 改 `telemetry/readyz`，liveness 用 `http-metrics/livez`，并把结论写进清单注释，避免下次再猜。

**问题 2：5xx 比例告警永远不触发（真实缺陷，尚未随镜像发布）**

- 现象：注入 720 次 500 后，Prometheus 里 5xx 比例只有 0.0006，告警不 Pending。
- 证据：`demo_http_requests_total{path="/readyz"}` 的区间取值在两个值之间反复跳：`53536 → 66702 → 53542 → 66708`，12 个采样点里 3 次回退。
- 根因：gunicorn 起 2 个 worker，`prometheus_client` 没开 multiprocess 模式，每个 worker 各持一份计数器；`/metrics` 每次只会返回命中的那个 worker，Prometheus 因此看到伪 reset，`rate()`/`increase()` 结果失真（实测算出 1366 req/s，而真实探针速率约 0.1 req/s）。
- 修复（已落代码，待随镜像发布）：`app/gunicorn.conf.py` 增加 `child_exit` 清理 mmap；`app.py` 在设置 `PROMETHEUS_MULTIPROC_DIR` 时用 `MultiProcessCollector` 聚合；Dockerfile 与 Deployment 提供该目录的 emptyDir；启动命令先清空残留文件。
- 同时改进告警表达式：5xx 比例的分母排除 `/healthz|/readyz|/metrics`，避免探针的高频 200 稀释业务错误率。

### 10.5 已验证的监控能力

| 项目 | 证据 |
| --- | --- |
| 抓取 | 7 个 target 全部 `up`（prometheus、alertmanager、2×demo-api、2×node-exporter、kube-state-metrics） |
| 规则加载 | 3 组共 10 条，`health=ok`，无语法错误 |
| 规则热重载 | `POST /-/reload` 返回 200，改 ConfigMap 后无需重启 Pod |
| Grafana | `/api/health` 返回 ok；数据源 `Prometheus`(uid=prometheus) 自动 provisioned；看板 `SRE Lab / SRE Lab Overview` 13 个面板，无需手工导入 |

## 11. 2026-11-05 未执行的操作

| 项目 | 原因 |
| --- | --- |
| `git commit` / `git push` | 按约定由你确认后执行；改动已同步到 master 的 `/opt/sre-devops-lab` 工作区（未提交） |
| 重新构建应用镜像 | 依赖上一条的 CI 触发，`/simulate/memory` 与 multiprocess 修复都在新镜像里 |
| OOMKilled 演练（D5） | 依赖新镜像的 `/simulate/memory` 端点 |
| self-hosted runner | P3 内容，尚未开始 |
| `kubectl delete` 清理 | 保留用于演示 |

## 12. 2026-11-05 排查 SOP 归档

本轮所有真实问题已整理成 `docs/2-troubleshooting-sop.md`，共 14 条（TS-01 下含 3 个子类）：

| 编号 | 问题 | 归档内容 |
| --- | --- | --- |
| TS-01 | 镜像拉不下来 | 四类根因判别表 + 各镜像源实测状态 + 预拉取耗时 |
| TS-01a | DNS 解析失败 | `registry.k8s.io` → `europe-west3-docker.pkg.dev` 解析失败，改 `k8s.m.daocloud.io` |
| TS-01b | blob 下载超时 | "manifest 通 ≠ blob 通"，必须用 `crictl pull` 实测 |
| TS-01c | 权限/标签错误 | 401/403/404 判别方法 |
| TS-02 | `CreateContainerConfigError` | 关键判据：Events 里有 `Pulled` 就不是拉取问题 |
| TS-03 | Running 但 NotReady | kube-state-metrics 端点实测分布 + 临时 Pod 逐端口探测法 |
| TS-04 | 计数器 worker 抖动 | `query_range` 找回退、multiprocess 三处修复、单 worker 止血方案 |
| TS-05 | 错误率被探针稀释 | 分母排除探针端点 + 加 `> 0` 防 0/0 |
| TS-06 | 告警不消解 | 长窗口 `increase[15m]` 收敛慢属正常，附判别表 |
| TS-07 | dry-run 报 namespace 不存在 | client / server 两种校验级别的用途区分 |
| TS-08 | 监控栈调度 | taint 与 allocatable 量化决策，DaemonSet 用无 key toleration |
| TS-09 | 跨跳板机传文件 | 两层 ssh + base64，含批量脚本 |
| TS-10 | PowerShell 拼接长命令失败 | 四层引号转义的规避策略 |
| TS-11 | ACL 拒绝写入 | 换用户目录，不硬碰系统目录权限 |

文档同时给出通用排查模型（分层 → 权威证据 → 可证伪测量 → 最小改动 → 同组测量验证 → 记录）、
诊断命令速查表和复盘方法论。

## 13. 2026-11-05 项目整理与发布验证

### 13.1 文档重构（SOP 改为学习路径版）

`docs/2-troubleshooting-sop.md` 从「按问题编号」改组为「按学习顺序」的 9 节课：

```text
1 打通作业通道        6 指标正确性
2 镜像供应链          7 告警表达式设计
3 容器启动与安全上下文  8 告警生命周期
4 调度与容量规划       9 变更校验流程
5 探针与就绪语义
```

每课统一为：学习目标 → 前置 → 核心概念 → 现象 → 诊断 → 根因 → 处置 → 验证 → **自检（含折叠答案）**。

新增 `docs/README.md` 作为文档导航，含按角色（面试 / 接手 / 排障 / 开发）的入口。

### 13.2 四个提交

| 提交 | 内容 |
| --- | --- |
| `2d606b0` | feat(app)：受控内存端点 + 多 worker 指标修复 + `.dockerignore` |
| `84a0d4f` | feat(monitoring)：监控栈 6 个清单文件 |
| `7ae0f27` | feat(cli)：`opsctl monitoring` 子命令 |
| `cce5412` | docs：9 课 SOP、导航、runbook、计划、交接、审计 |

推送：`4bc3dcf..cce5412  main -> main`，CI 触发后 60 秒产出镜像
`ghcr.io/0tinna/sre-devops-lab:cce5412d...`。

### 13.3 发布过程再次踩坑（已补进 SOP 第 9 课）

**问题：`opsctl deploy` 用 `set image` 发布，env 和 volume 没生效。**

- 现象：Pod Running、镜像 SHA 正确，但 `kubectl get deploy -o jsonpath env` 只显示 `PORT`，
  新增的 `ENABLE_FAULT_ENDPOINTS`、`PROMETHEUS_MULTIPROC_DIR` 全部缺失。
- 根因：`set image` 只改 `.spec.template.spec.containers[0].image` 一个字段。
- 修复：渲染带 SHA 的清单后 `kubectl apply`，确认 5 个 env 全部就位：
  `PORT ENABLE_FAULT_ENDPOINTS PROMETHEUS_MULTIPROC_DIR GUNICORN_WORKERS GUNICORN_THREADS`。
- 另一发现：`opsctl deploy` 默认 `--timeout 120s`，新镜像冷启动拉取（约 80 秒）
  会触发超时并返回非零——脚本判定行为正确，但默认值对冷缓存偏紧。

### 13.4 multiprocess 修复的验证结果

| 项目 | 修复前 | 修复后 |
| --- | --- | --- |
| 容器内计数器 | `53536 → 66702 → 53542 → 66708` | `3 → 6 → 9 → 12 → 15 → 18 → 21 → 24` |
| `query_range` drops | 3 / 12 | **0 / 7** |
| `rate(/readyz[2m])` | 1366/s（误报） | **0.400/s** |
| 与真实值比对 | 差 3400 倍 | 探针 5s × 2 Pod = 0.4/s，**完全吻合** |
| `DemoApiHighErrorRate` | 注入 720 次 500 仍不触发 | **pending → firing** |
| Alertmanager | 收不到 | 收到 `active`，停止注入后自动 resolved |

验证方式：容器内无 curl/wget，改用 `python3 -c "urllib.request..."`。

### 13.5 当前集群状态

```text
demo-api   2/2 Running   镜像 cce5412d...   3 个故障端点可用
monitoring 6/6 Ready     7/7 target up      10 条规则 health=ok
告警       0 条          全部已消解
```

## 14. 2026-11-05 15:23–15:50 P2 故障演练全量执行

执行者：Little Code Sauce（经跳板机到 master）

### 14.1 七项演练结果

| # | 演练 | 注入方式 | 结果 | 恢复方式 |
| --- | --- | --- | --- | --- |
| D1 | Pod 自愈 | `delete pod` | 约 15 秒重建；`up` 始终 7 | 自动 |
| D2 | ImagePullBackOff | `set image :missing-tag` | 新 Pod 拉取失败，老 Pod 2/2 继续服务，`/healthz` 200 | `rollout undo` |
| D3 | CrashLoopBackOff | `command: /bin/false` | 4 次重启，双告警 firing | `rollout undo` |
| D4 | Pending | `requests.cpu=8` + `limits.cpu=8` | Events：`1 Insufficient cpu, 1 untolerated taint` | `rollout undo` |
| D5 | OOMKilled | limit 压到 64Mi + `/simulate/memory?mib=300` | **两个 Pod 都 OOMKilled，exit=137** | 恢复 256Mi |
| D6 | P95 延迟 | 持续 `/simulate/slow` 3 并发 | P95 稳定 2.2–2.35s，`DemoApiHighLatencyP95` firing | 停止注入 |
| D7 | 回滚 | `opsctl deploy` 坏镜像 → `rollback` | deploy 返回 1；**rollback 回到仍是坏版本的 revision** | `apply` 恢复 |

### 14.2 D4 第一次尝试被 API 拒绝

```text
The Deployment "demo-api" is invalid: spec.template.spec.containers[0].resources.requests:
Invalid value: "8": must be less than or equal to cpu limit of 500m
```

`requests` 不能大于 `limits`，Kubernetes 在 API 层直接拒绝。改为两者同时调到 8 才通过。
**这个约束在构造 Pending 场景时容易忽略。**

### 14.3 D5 的超预期结果

压低到 64Mi 后，两个 Pod **都无法启动**（gunicorn + Python 本身就要超过 64Mi），
直接进入 CrashLoopBackOff。这不是"运行中内存泄漏被 OOMKill"，而是"limit 太小连启动都过不去"。

反而成了最好的告警演示：一次同时触发 7 条告警。

```text
PodRestartTooOften      firing  warning   ×2
ContainerOOMKilled      firing  critical  ×2
TargetDown              pending critical  ×2
DeploymentReplicasMismatch firing critical ×1
```

证据：`lastState.terminated.reason=OOMKilled`，`exitCode=137`，`restartCount=3`。

### 14.4 D7 暴露的严重陷阱

```text
1) opsctl deploy <bad-tag-1>  → revision 17
2) opsctl deploy <bad-tag-2>  → revision 18
3) opsctl rollback            → 退出码 1，image 仍是 <bad-tag-1>
```

`rollout undo` 只回退一步。连续坏发布时，回退目标本身就是坏的。
且它回退整个 Pod template——本项目历史 ReplicaSet 里只有当前那个带完整 5 个 env，
落到旧 RS 上会连 `PROMETHEUS_MULTIPROC_DIR` 一起丢掉。

**最终用 `apply` 渲染清单恢复**，这再次印证第 9 课的结论。

### 14.5 顺带修掉的缺陷：opsctl health 误报

演练中发现 `opsctl health` 把正在 Terminating 的旧 Pod 报成 `Pending` 故障，
导致发布/回滚期间健康检查一定返回非零。

修复：跳过 `metadata.deletionTimestamp` 非空的 Pod。

```python
# 判定依据是 deletionTimestamp，而不是 phase
if pod['metadata'].get('deletionTimestamp'):
    continue
```

验证：滚动更新进行中（同时存在 Terminating 和 ContainerCreating）执行 `health`，
返回 `OK` 且退出码 0；修复前必然 `NOT OK`。

### 14.6 管道吞退出码的实测

```bash
python3 scripts/opsctl.py deploy <bad> 2>&1 | tail -3
echo $?     # 0  ← 错！实际部署失败
```

改为 `cmd >log 2>&1; rc=$?` 后正确得到 `1`。已写入 SOP 第 9 课。

### 14.7 演练期间的告警覆盖

10 条规则中 **6 条经过真实触发**：`TargetDown`、`PodRestartTooOften`、
`ContainerOOMKilled`、`DeploymentReplicasMismatch`、`DemoApiHighErrorRate`、
`DemoApiHighLatencyP95`。

未触发的 4 条如实标注：`PodNotReady`（未单独构造）、
`NodeMemoryPressure` / `NodeDiskPressure` / `NodeHighCPU`（构造会压垮 3.6 GiB 的 worker）。

### 14.8 最终状态

```text
master/node          Ready
demo-api             2/2 Running，镜像 cce5412d，5 个 env 完整
monitoring           6/6 Ready
告警                 0 条，全部消解
opsctl health        OK
```

## 15. 2026-11-05 16:20–16:50 P4 日志集中化

执行者：Little Code Sauce（经跳板机到 master）

目标：补上可观测性最大的缺口——日志此前只能 `kubectl logs` 手工看，没有集中收集与检索。

### 15.1 方案选型与踩坑过程

| 步骤 | 尝试 | 结果 |
| --- | --- | --- |
| 1 | 拉取 `grafana/loki:2.9.4` + `grafana/promtail:2.9.4` | 成功（66s / 143s） |
| 2 | 部署 Loki 单机 + Promtail DaemonSet | Loki 起来了，**Promtail 永远 0/1 NotReady** |
| 3 | 从 Promtail 日志定位 | `Not ready: Unable to find any logs to tail` |
| 4 | 验证挂载与 glob | 容器内 `ls /var/log/pods` 正常，手工 glob 能匹配到文件 |
| 5 | 用 `static_configs` 最小配置测试 | **target=1、ready 200、tail 正常启动** |
| 6 | 换 Promtail 3.5.0 重试 `kubernetes_sd_configs` | 仍然 0 targets |
| 7 | 验证 RBAC / DNS / token / API 访问 | 全部正常：`kubectl auth can-i` = yes，容器内 openssl 直连 API 返回 `HTTP/1.1 200 OK` 和完整 PodList |
| 8 | 判定 | **Promtail 的 `kubernetes_sd_configs` 在 K8s v1.34.1 上静默失效**（无任何报错） |
| 9 | 改用 Fluent Bit 3.1.9 | kubernetes filter 日志显示 `connectivity OK` / `local POD info OK` |
| 10 | 修正不支持的配置项 | `total_limit_size` 导致 output 初始化失败，删除后正常 |

### 15.2 关键证据：Promtail 的静默失效

同一套配置下，唯一差别是 `static_configs` 还是 `kubernetes_sd_configs`：

```text
static_configs        → promtail_targets_active_total 1, ready 200, tail 正常
kubernetes_sd_configs → promtail_targets_active_total 0, ready 500, 无任何错误日志
```

而容器内直连 API 是通的：

```bash
# 在 promtail 容器里用 openssl 手工发请求
GET /api/v1/namespaces/sre-lab/pods?limit=1
→ HTTP/1.1 200 OK
→ {"kind":"PodList", ... "items":[{"metadata":{"name":"demo-api-74d4c55f69-k6xht",...}}]}
```

**网络通、认证通、API 通，但 discovery 就是不返回 target，也不报错。**

这是最难的一类故障：`/service-discovery` 页面显示 `kubernetes-pods (0/0 active targets)`，
日志里连一条 error 都没有。

### 15.3 最终方案：Fluent Bit

| 对比项 | Promtail | Fluent Bit |
| --- | --- | --- |
| 文件发现 | 依赖 `kubernetes_sd_configs`（本项目失效） | `tail` 直接读 `/var/log/containers/*.log` |
| K8s 1.34 兼容 | ❌ | ✅ |
| 日志元数据 | SD 提供 | `kubernetes` filter + tag 解析 |
| 镜像大小 | 75MB | 约 50MB |

**关键差异**：Fluent Bit 用 `tail` input 直接扫文件，**不依赖 API 做文件发现**，
元数据由 `kubernetes` filter 补充（这一步实测正常）。所以即使 SD 类方案有问题，
Fluent Bit 仍能工作——这也是它更稳的原因。

配置要点：

```ini
[INPUT]
    Name tail
    Path /var/log/containers/*.log
    Exclude_Path /var/log/containers/*_kube-system_*.log,/var/log/containers/*_kube-flannel_*.log
    multiline.parser cri
    Tag kube.*
    DB /var/lib/fluent-bit/flb.db

[FILTER]
    Name kubernetes
    Kube_Tag_Prefix kube.var.log.containers.   # 从文件名解析 ns/pod/container
    Merge_Log On

[OUTPUT]
    Name loki
    Host loki.monitoring.svc.cluster.local
    Labels job=fluent-bit, namespace=$kubernetes['namespace_name'], ...
```

### 15.4 第二个坑：ConfigMap 变更不会重启 Grafana

加完 Loki 数据源后，`kubectl apply` 显示 ConfigMap configured，
但 Grafana 里**只有 Prometheus 一个数据源**。

原因：ConfigMap 内容变化不会触发引用它的 Deployment 滚动更新
（除非在 Pod template 上挂 checksum 注解）。必须显式重启：

```bash
kubectl -n monitoring rollout restart deploy/grafana
```

**这个坑和第 9 课的 `set image` 是同一类问题**：改了配置但没让工作负载重新加载。

### 15.5 部署结果

| 组件 | 状态 | 资源 |
| --- | --- | --- |
| Loki 2.9.4 | 1/1 Running | req 100m/192Mi，lim 500m/512Mi |
| Fluent Bit 3.1.9 | 2/2 Running（双节点） | 各 req 50m/64Mi，lim 200m/160Mi |
| Grafana 数据源 | Prometheus + Loki 双源 | — |
| 看板面板 | 13 → **15**（+日志速率 +错误日志） | — |

监控栈总资源：requests `490m / 928Mi`，limits `2400m / 2112Mi`，master 仍余 14 GiB。

### 15.6 验证

```text
Loki /loki/api/v1/labels  → container, filename, job, kubernetes_*, namespace, node, pod
namespace 值              → ["monitoring", "sre-lab"]
查询 {namespace="sre-lab"} → 2 条流（两个 demo-api pod），近 5 分钟 62 行
Grafana 代理查 Loki        → {"status":"success","data":["monitoring","sre-lab"]}
```

Grafana 面板可直接检索：
- 「日志速率（Loki，按命名空间）」— `sum by (namespace) (rate({namespace=~"$namespace"}[5m]))`
- 「错误日志」— `{namespace=~"$namespace"} |~ "(?i)error|fail|exception|panic|fatal"`

### 15.7 清理

```bash
kubectl -n monitoring delete ds promtail
kubectl -n monitoring delete sa promtail cm promtail-config
kubectl delete clusterrole promtail-sre-lab clusterrolebinding promtail-sre-lab
rm k8s/monitoring/70-promtail.yaml
```

Promtail 清单已删除，失败原因记入本文档与 SOP 附录 D。

## 16. 2026-11-05 16:55–17:10 演练场景扩展到日志维度

### 16.1 新增两个场景

| 编号 | 场景 | 注入方式 | 现象 |
| --- | --- | --- | --- |
| 9 | 日志有 ERROR，指标全绿 | 持续请求 `/simulate/degraded` 15 分钟 | HTTP 全 200，日志 40 条 ERROR，告警 0 |
| 10 | 日志采集静默中断 | fluent-bit 加不匹配的 nodeSelector | 采集器消失，服务正常，Loki 无新日志 |

### 16.2 应用侧配套改动

新增 `/simulate/degraded` 端点：模拟下游依赖超时被捕获，**降级返回缓存但 HTTP 200**。

```python
try:
    raise TimeoutError(f'{upstream} did not respond within {latency:.1f}s')
except TimeoutError as exc:
    logger.error('downstream call failed, serving stale cache: %s', exc)
return jsonify(status='degraded', source='stale-cache', ...)
```

同时给应用加了 logging 配置（输出到 stdout，格式含时间/级别/logger），
否则 Fluent Bit 采不到结构化日志。

### 16.3 场景 9 的实测数据

注入 15 分钟持续请求后：

```text
日志层（logs-loki.txt）:
  各 Pod ERROR 行数: demo-api-75fb44d974-bz44g = 21, -q8ltp = 19
  ERROR 样本: "downstream call failed, serving stale cache:
               inventory-service did not respond within 2.4s"
  每个 200 响应前都有一行 ERROR

指标层（metrics.txt）:
  ALERTS{alertstate="firing"}  → (无数据)
  sum by (pod) (rate(demo_http_requests_total[5m])) → 只有 200，无 5xx
  histogram_quantile(0.95, ...) = 0.00475   ← P95 仅 4.7ms
```

**结论**：40 条 ERROR、0 条告警、P95 反而更快（走缓存）。
这正是"静默降级"的典型特征——**变快也可能是变坏的信号**。

### 16.4 场景 10 的实测数据

```text
采集时间:     2026-11-05 17:04:23
最新日志时间: 2026-11-05T17:00:17
差值:         约 4 分钟          ← 关键判据

sum(up) = 7                       ← Prometheus 抓取正常
ALERTS  = (无数据)                ← 无告警
demo-api = 2/2 Running，/healthz 200

kubectl -n monitoring get pods -l app.kubernetes.io/name=fluent-bit
  → No resources found
kubectl -n monitoring get ds fluent-bit -o jsonpath='{.spec.template.spec.nodeSelector}'
  → {"drill-disabled":"true"}
```

### 16.5 collect.sh 新增日志采集

新文件 `logs-loki.txt`：

```text
各命名空间的日志量（近 15 分钟）
sre-lab 各 Pod 的日志量
ERROR/FATAL 日志行数（按 Pod）
最近 40 行原始日志
ERROR 日志样本
```

排查顺序也更新了：日志证据插在 endpoints 之后、配置对比之前。

### 16.6 暴露的监控缺口

场景 10 证明**日志管道自身没有被监控**。当前 10 条告警规则里没有一条能发现
"Fluent Bit 挂了"。建议补充（尚未实现）：

```yaml
- alert: LogCollectorDown
  expr: |
    kube_daemonset_status_number_ready{daemonset="fluent-bit"}
      < kube_daemonset_status_desired_number_scheduled{daemonset="fluent-bit"}
  for: 5m
```

这条已记入 `docs/drills/answers.md` 的 S10 预防章节，作为后续任务。

## 17. 2026-11-06 09:15–09:45 P5 自动扩缩容与告警补全

### 17.1 metrics-server

| 项 | 值 |
| --- | --- |
| 版本 | v0.8.0（K8s 1.34 兼容） |
| 镜像源 | `k8s.m.daocloud.io/metrics-server/metrics-server` |
| 部署位置 | master（nodeSelector + toleration） |
| 关键参数 | `--kubelet-insecure-tls`（自签证书必须） |
| 资源 | req 50m/64Mi，lim 200m/128Mi |
| APIService | `v1beta1.metrics.k8s.io` → AVAILABLE=True |

验证：

```text
kubectl top nodes
  master  110m  2%   2916Mi 18%
  node     36m  1%   1869Mi 51%
kubectl top pods -n sre-lab
  demo-api-xxx  1m  69Mi
```

### 17.2 HPA 配置

```yaml
minReplicas: 2
maxReplicas: 5
target: CPU 70%（相对 request 100m，即 70m 触发）
behavior:
  scaleUp:   稳定窗口 0s，Percent 100/30s + Pods 2/30s，取 Max
  scaleDown: 稳定窗口 300s，Pods 1/60s，取 Min
```

### 17.3 扩容实测（教科书级）

压测方式：16 并发持续请求 `/simulate/cpu?ms=200`（服务端纯计算循环，不 sleep）。

| 时刻 | 副本数 | HPA 读数 |
| --- | --- | --- |
| t+0s | 2 | `cpu: 2%/70%` |
| t+30s | **4** | `cpu: 488%/70%` |
| t+60s | **5**（触顶） | `cpu: 444%/70%` |
| t+90s ~ t+240s | 5（稳定） | `cpu: 365%` 左右 |

**30 秒内 2→4，60 秒内到上限**。`stabilizationWindowSeconds: 0` + `Percent 100` + `selectPolicy: Max`
的效果非常直接。

每个 Pod 被限流在约 `370m`（limit 500m），说明 CFS 限流生效，
CPU 打不满 limit 但已经远超 request 的 70%。

### 17.4 缩容实测

停止压测时刻：`09:33:01`

| 时刻 | 相对时间 | 副本数 | 说明 |
| --- | --- | --- | --- |
| 09:33:46 ~ 09:38:16 | t+45s ~ t+315s | 5 | **稳定窗口生效，不动** |
| 09:39:01 | t+360s | 4 | 开始缩 |
| 09:39:47 | t+405s | 3 | |
| 09:40:32 | t+450s | 2 | 回到 minReplicas |

**从停止压测到开始缩容等了约 5 分钟**，与 `stabilizationWindowSeconds: 300` 完全吻合。
之后每约 50-60 秒减 1，符合 `Pods: 1, periodSeconds: 60`。

这个"扩得快、缩得慢"的不对称设计是刻意的：
扩容慢了会丢请求，缩容快了会在流量抖动时反复扩缩（flapping）。

### 17.5 告警补全：10 → 16 条

新增 6 条，覆盖前三层看不到的盲区：

| 告警 | 覆盖什么盲区 |
| --- | --- |
| `LogCollectorDown` | 日志采集器掉线（场景 10 暴露的缺口） |
| `LokiNotReceivingLogs` | 采集器在但写入链路断了 |
| `HPAMaxedOut` | 扩不动了，容量规划需要调整 |
| `HPAUnableToScale` | metrics-server / APIService 故障 |
| `PodCPUNearLimit` | 接近 CFS 限流边界，延迟会尖刺 |
| `PodMemoryNearLimit` | 接近 OOMKilled 阈值，提前介入 |

### 17.6 一个没触发但很有价值的观察

压测期间这 6 条新告警**一条都没触发**：

```text
NodeHighCPU          触发采样数 = 0    （node 只到 2%，压测 pod 被 limit 限制）
PodCPUNearLimit      触发采样数 = 0    （Pod 374m/500m = 74%，未到 85%）
HPAMaxedOut          触发采样数 = 0    （for: 10m，但压测只持续 6.5 分钟）
```

**原因分析**：

1. `HPAMaxedOut` 的 `for: 10m` 比压测时长的 6.5 分钟还长，永远等不到。
   已改为 `for: 5m`——这是"阈值必须匹配实际场景时长"的直接教训。
2. `PodCPUNearLimit` 定 85%，但 CFS 限流让 Pod 稳定在 74%，
   说明**这个阈值对"被限流"这种状态不够敏感**。真正该看的是
   `container_cpu_cfs_throttled_periods_total` 的比例，而不是 usage/limit。
3. `NodeHighCPU` 定 85%，但压测 pod 的 limit 只有 500m，对 2 核节点影响很小。

**结论**：告警阈值不能凭感觉定，要按真实压测数据校准。
这三条同时暴露了"阈值定得不合理"和"指标选得不对"两类问题。

### 17.7 规则热加载的坑

改完 ConfigMap 后 `kubectl apply` 显示 configured，`POST /-/reload` 返回 200，
但 `/api/v1/rules` 仍显示旧的 10 条。

原因：**ConfigMap 挂载到 Pod 需要 kubelet 同步（约 30-60 秒）**，
reload 读的是挂载点里的文件，不是 ConfigMap 对象本身。

验证方法：

```bash
kubectl -n monitoring exec deploy/prometheus -- \
  sh -c 'grep -c "alert:" /etc/prometheus/rules/sre-lab-alerts.yml'
# 等到数字变化后再 reload
```

这与第 9 课"ConfigMap 变更不重启 Grafana"是同一类问题的不同表现：
一个需要重启进程，一个只需要等文件同步。

## 18. 2026-11-06 10:20–11:20 P6 可用性加固

### 18.1 这一层要解决什么

P5 做完后，HPA 能扩到 5 副本，但这些副本全挤在**同一个 worker 节点**上，
而且没有任何机制保证：

- 节点维护时不会一次性驱逐所有副本
- 单个应用不会吃光整个集群的资源
- 容器收到 SIGTERM 时能把在途请求处理完
- 资源紧张时关键业务优先保留

这一层把"能跑"变成"能扛"。

### 18.2 五个组件

| 组件 | 配置 | 作用 |
| --- | --- | --- |
| `PriorityClass` | `sre-lab-critical`=100000，`sre-lab-batch`=1000 | 资源紧张时关键业务优先保留 |
| `PodDisruptionBudget` | `minAvailable: 1` | 自愿中断（drain/evict）时至少留 1 个可用 |
| `ResourceQuota` | request 4 CPU/4Gi，limit 8 CPU/8Gi，pods 20 | 防止单个命名空间吃光集群 |
| `LimitRange` | default 200m/256Mi，max 2 CPU/2Gi，maxLimitRequestRatio 10 | 给忘记写 resources 的 Pod 兜底，同时封顶 |
| 优雅终止 | `preStop: sleep 5` + `terminationGracePeriodSeconds: 30` | 等 Endpoint 摘除后再停进程 |
| `startupProbe` | 2s × 30 = 60s | 启动阶段 liveness 不介入，避免误杀 |
| 拓扑分布 | `maxSkew: 1`，`ScheduleAnyway` | 副本尽量跨节点；只有 1 个节点时允许不满足 |
| 调度兜底 | toleration + nodeAffinity 偏好 worker | worker 挂了能去 master |

### 18.3 第一次 drain：PDB 正确，但镜像没预热

第一次 drain 的真实输出：

```text
evicting pod sre-lab/demo-api-544f976986-s65ld
error when evicting pods/"demo-api-544f976986-6fcnl" (will retry after 5s):
  Cannot evict pod as it would violate the pod's disruption budget.
pod/demo-api-544f976986-s65ld evicted
...（此后 4 分钟内反复重试全部被拒）
error: unable to drain node "node": global timeout reached: 4m0s
```

**PDB 工作得完全正确**：

```text
驱逐第 1 个前: ALLOWED DISRUPTIONS = 1
驱逐第 1 个后: ALLOWED DISRUPTIONS = 0   ← 第二个立刻被拦住
```

同时 toleration + affinity 也生效了——新副本被调度到了 master：

```text
demo-api-544f976986-d75zs   0/1   ContainerCreating   4m48s   master
```

**但它卡住了**：

```text
Events:
  Normal  Scheduled  4m28s  Successfully assigned sre-lab/demo-api-544f976986-d75zs to master
  Normal  Pulling    4m28s  kubelet  Pulling image "ghcr.io/0tinna/sre-devops-lab:7f30733..."
```

**根因**：master 节点本地没有这个镜像，正在从 ghcr.io 拉，而国内网络下拉取极慢。

于是形成死锁：
- PDB 要等新副本 Ready 才放行第 2 个驱逐
- 新副本要等镜像拉完才 Ready
- 镜像拉不完 → drain 永远完不成

### 18.4 关键教训：PDB 的正确性依赖"替身能快速就绪"

这是本层最有价值的发现：

> **PDB 保证的是"可用副本数不低于 minAvailable"，但它不保证这个保证能在可接受的时间内兑现。**
> 如果新副本要 5 分钟才能起来，那 drain 就会卡 5 分钟——PDB 数值上正确，运维体感是故障。

生产环境的对应做法：

1. **镜像预热**：在所有可能调度的节点上预拉镜像（DaemonSet 或部署流程的一部分）
2. **本地镜像仓库**：内网 registry / Harbor，避免每次回源
3. **合理放宽 PDB**：2 副本配 `minAvailable: 1` 已经很紧，可以考虑 `maxUnavailable: 1`
4. **提前演练 drain**：不要等真维护时才发现拉镜像慢

### 18.5 绕过 ghcr.io 慢速：内网搬运镜像

`crictl pull` 直连 ghcr.io，600 秒超时都没拉完。改用 node → master 内网搬运：

```bash
# 1) 在已有镜像的 node 上导出
ssh root@172.31.12.103 "ctr -n k8s.io images export \
  --platform linux/amd64 /tmp/sre-img.tar ghcr.io/0tinna/sre-devops-lab:7f30733..."

# 2) 走内网传到 master
scp root@172.31.12.103:/tmp/sre-img.tar /tmp/sre-img.tar

# 3) 在 master 导入
ctr -n k8s.io images import --platform linux/amd64 /tmp/sre-img.tar
```

实测耗时：

| 步骤 | 耗时 |
| --- | --- |
| node 导出 | 约 5s（45 MB） |
| node → master scp | 0s（同机房内网） |
| master 导入 | **17s** |
| 对比：直接 pull | **>600s 未完成** |

导入后卡住的 Pod 立刻变成 `1/1 Running`。

### 18.6 第二次 drain：7 秒完成

预热后重跑，全程：

```text
=== 开始 drain node 11:09:56 ===
node/node cordoned
pod/demo-api-544f976986-6fcnl evicted
node/node drained
drain 完成 11:10:03        ← 7 秒
```

结果：

```text
demo-api-544f976986-9x6wm   1/1   Running   7s   10.244.0.25   master
demo-api-544f976986-d75zs   1/1   Running   28m  10.244.0.23   master
demo-api   1     N/A   0           ← PDB 阻止进一步驱逐（只有 1 个就绪）
Endpoints: 10.244.0.23:8080,10.244.0.25:8080
```

### 18.7 Pod 迁回 node：零失败

drain 会让所有副本跑到 master，恢复后要让它们回到 worker（affinity 偏好）。
逐个删除验证 PDB 保护下的滚动迁移：

| 操作 | 结果 | 探针计数 |
| --- | --- | --- |
| 删除 master 上的 `-9x6wm` | 新 Pod `-hwrll` 调度到 **node** | `ok=39 fail=0` |
| 删除 master 上的 `-d75zs` | 新 Pod `-ppr6s` 调度到 **node** | `ok=69 fail=0` |

**全程零请求失败**，affinity 偏好也验证了：新 Pod 都回到了 worker 而不是留在 master。

### 18.8 一个调试坑：容器里 echo 的输出看不到

探针 Pod 用 `sh -c 'while ...; do echo ...; done'` 往 stdout 写结果，
但 `kubectl logs` **一直是空的**，而服务实际被测了上百次。

原因：容器内 sh 的 stdout 是块缓冲的，而进程还在 `sleep`，缓冲区没被刷出来。

**改成写文件就正常了**：

```yaml
volumeMounts: [{name: probe, mountPath: /probe}]
# 脚本里
echo "t=$(date +%H:%M:%S) ok=$ok fail=$fail" > /probe/result.log.cur
# 查看
kubectl exec svcprobe -- cat /probe/result.log.cur
```

**教训**：长驻探针/守护脚本的进度不要依赖 stdout，落盘更可靠。

### 18.9 已知限制（如实记录）

| 限制 | 说明 |
| --- | --- |
| PDB 不覆盖非自愿中断 | 节点宕机、内核 panic 时 PDB 无效，只能靠多副本 + 跨节点 |
| 只有 1 个 worker | 正常状态下所有副本仍在同一节点，真正的跨节点容灾需要至少 2 个 worker |
| master 参与业务调度 | 是 2 节点实验环境的取舍；生产环境不应让业务上控制面 |
| 镜像分发热点 | 见 18.4，是故障转移的隐藏瓶颈 |

### 18.10 顺手修掉 recover.sh 的两个 bug

做 P6 演练时发现 `recover.sh` 会把镜像悄悄降级到旧版本：

```text
目标镜像: ghcr.io/0tinna/sre-devops-lab:cce5412d...
当前镜像: ghcr.io/0tinna/sre-devops-lab:7f30733...
→ 恢复后 /simulate/degraded 和 /simulate/cpu 变成 404
```

**Bug 1：`IMAGE_SHA` 被硬编码成某个历史 sha**

```bash
# 修改前
IMAGE_SHA="${IMAGE_SHA:-cce5412d9f4a5c5d83832cd95d5ff67919c1d7c2}"
```

后果：每次"恢复到基线"都回到那个旧版本，后加的端点反而消失。
改成从 git HEAD 推导，并打印目标/当前对比：

```bash
GIT_SHA="$(git rev-parse HEAD 2>/dev/null || true)"
IMAGE_SHA="${IMAGE_SHA:-$GIT_SHA}"
# 并显式提示：若 tag 未构建完，rollout 会卡在 ImagePullBackOff
```

**Bug 2：`recover.sh | head -8` 让脚本被 SIGPIPE 杀死**

调试时用 `./scripts/drills/recover.sh 2>&1 | head -8` 只看开头，
结果脚本在打印完头部就被 SIGPIPE 终止，**后面的 `sed` 和 `kubectl apply` 根本没执行**，
但终端显示"rollout successfully"（因为什么都没改，当前状态本来就行）。

```bash
# 错误写法：只看到前 8 行就截断管道
./scripts/drills/recover.sh | head -8

# 正确写法：先落盘再看
./scripts/drills/recover.sh > /tmp/recover.log 2>&1
tail -20 /tmp/recover.log
```

这和第 9 课"管道吞掉退出码"是同一类问题：**管道会让生产端提前死亡，
但你看到的退出码/输出都是下游的**。

### 18.11 验证数据汇总

| 项 | 数值 |
| --- | --- |
| drain 耗时（预热后） | 7 秒 |
| drain 耗时（未预热） | 超时 4 分钟，失败 |
| 服务请求失败数 | 0（迁移全程 69 次探测全成功） |
| master 镜像导入 | 45 MB / 17 秒 |
| 直接 pull 对比 | >600 秒未完成 |
| PDB 阻断驱逐次数 | 第一次 drain 中 16+ 次 |

## 19. 2026-11-06 14:10–15:00 P7 死告警审计与容器级指标

### 19.1 起因：一次顺手的审计

P6 收尾时想确认"还有没有别的告警缺口"，于是查了 kube-state-metrics 暴露的指标。
结果发现两件比预想严重的事。

**第一件**：`--resources` 是个**白名单**，当前值是

```text
pods,deployments,replicasets,statefulsets,daemonsets,nodes,namespaces,
services,endpoints,persistentvolumes,persistentvolumeclaims,jobs,cronjobs
```

里面**没有** `horizontalpodautoscalers` 和 `poddisruptionbudgets`。
这意味着 P5 写的 `HPAMaxedOut` / `HPAUnableToScale` 引用的
`kube_horizontalpodautoscaler_*` 根本不存在——两条告警从写下的那一刻就是死的。

**第二件**：整个 Prometheus 只有 **7 个 target**，没有 cAdvisor，也没有 Loki。
所以 `PodCPUNearLimit`、`PodMemoryNearLimit`、`LokiNotReceivingLogs`
同样引用了不存在的指标。

### 19.2 死告警的隐蔽性

这类问题的可怕之处在于**所有常规检查都能通过**：

| 检查 | 结果 |
| --- | --- |
| YAML 语法 | 合法 |
| `promtool check rules` | 通过 |
| `/api/v1/rules` 的 health | 全部 `ok` |
| `/api/v1/alerts` | 不报错，只是永远为空 |
| 告警界面 | 一切正常，绿油油 |

**"没触发"和"不可能触发"在监控上长得一模一样。**

### 19.3 写一个审计工具

与其人工核对，不如让机器做。`scripts/audit-alerts.py`：

1. 从 Prometheus 拉全部规则表达式
2. 从 `/api/v1/label/__name__/values` 拉全部真实存在的指标名
3. 从表达式里抽出形如 `metric{` 的标识符（最可靠的指标引用形式）
4. 比对，报出引用了不存在指标的告警

首次运行结果：

```text
[autoscaling]
  ✗ PodCPUNearLimit      health=ok  缺失指标: container_cpu_usage_seconds_total
  ✗ PodMemoryNearLimit   health=ok  缺失指标: container_memory_working_set_bytes
[reliability]
  ✗ ContainerOOMKilled   health=ok  缺失指标: kube_pod_container_status_last_terminated_reason
[capacity]
      疑似未知标识符: loki_distributor_lines_received_total
结果: 3/16 条告警引用了不存在的指标 —— 这些告警永远不会触发
```

工具还区分了**条件性指标**：`kube_pod_container_status_last_terminated_reason`
这类只在"事件发生过"时才存在的指标，缺席是正常的，标 `~` 而不是 `✗`：

```text
  ~ ContainerOOMKilled   health=ok  条件性指标当前无事件: kube_pod_container_status_last_terminated_reason
```

### 19.4 修复：三个新抓取目标

原来只有 7 个 target，容器级指标一个都没有。补上三个 job：

| job | 采集什么 | 关键点 |
| --- | --- | --- |
| `kubelet-cadvisor` | 容器 CPU/内存/OOM 事件 | 走 apiserver 代理 `/api/v1/nodes/<n>/proxy/metrics/cadvisor` |
| `kubelet` | kubelet 自身，含 `kubelet_image_pull_duration_seconds` | 同上 |
| `loki` | Loki 自身指标 | 静态目标 `loki:3100` |

**为什么走 apiserver 代理而不是直连 10250**：

```yaml
relabel_configs:
  - target_label: __address__
    replacement: 'kubernetes.default.svc:443'
  - source_labels: ['__meta_kubernetes_node_name']
    target_label: __metrics_path__
    replacement: '/api/v1/nodes/${1}/proxy/metrics/cadvisor'
```

这样不需要直连 kubelet 端口、不需要单独配 kubelet 证书，
只需要 ServiceAccount 有 `nodes/proxy` 权限（RBAC 里早就有了）。

**结果**：target 从 7 个变成 **12 个**，全部 up。

```text
kubelet              node      up
kubelet              master    up
kubelet-cadvisor     node      up
kubelet-cadvisor     master    up
loki                 ...       up
```

指标从 744 个涨到 **1348 个**。

### 19.5 新增 4 条告警（16 → 20）

| 告警 | 表达式要点 | 它补的是哪个盲区 |
| --- | --- | --- |
| `PDBBlocksMaintenance` | `pod_disruptions_allowed <= 0` | 场景 11：服务正常但无法维护 |
| `PodImagePullFailed` | `waiting_reason{ErrImagePull…}` | 场景 5：只靠肉眼发现 |
| `ImagePullSlow` | kubelet 拉取 P90 > 120s | 镜像分发热点 |
| `ContainerOOMEvents` | `container_oom_events_total` 增量 | 见 19.7 |

审计复跑：

```text
结果: 20 条告警引用的指标全部存在且非条件性
audit 退出码=0
```

### 19.6 镜像分发脚本，以及它自己踩的 3 个坑

`scripts/prewarm-image.sh` 把镜像主动推到所有节点。写的过程本身踩了三个坑，
都很有代表性：

**坑 1：`crictl` 没有 `export` / `import`**

第一版写成 `crictl images export ...`，实际输出是 crictl 的帮助文本——
因为这两个子命令属于 `ctr`，不属于 `crictl`。

```bash
CRICTL="crictl --runtime-endpoint unix:///run/containerd/containerd.sock"  # images/pull/rmi
CTR="ctr -n k8s.io"                                                        # export/import
```

**坑 2：用 IP 和主机名比较**

`addr_of master` 返回 `172.31.6.211`，而 `SELF` 是 `master`，
于是 `"$tip" != "$SELF"` 恒为真，脚本反复尝试 `scp` 到本机自己，全部失败。

修法：本机必须返回主机名而不是 IP。

**坑 3：`ssh`/`scp` 吃掉调用方的 stdin**

脚本是通过 `echo $b64 | base64 -d | bash` 传入的，bash 的 stdin 就是脚本流。
脚本内部一执行 `scp`，scp 把**剩余脚本当输入吃掉**，脚本中途中止且**没有任何报错**。

```bash
# 修法：ssh 加 -n，scp 加 </dev/null
SSH_OPTS="-n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5"
scp ${SSH_OPTS/-n/} src dst </dev/null
```

**这和第 9 课的"管道吞掉退出码"是同一个家族的坑**：管道让生产端提前死亡，
而你看到的输出和退出码都是下游的。

修完实测：

```text
--- 盘点 ---
  ✗ master     缺失
  ✓ node       已有
--- 导出镜像 ---
  完成，大小 45M，耗时 1s
--- 分发 ---
  → master     完成 1s
--- 复验 ---
  ✓ master     已有
  ✓ node       已有
结果: 全部节点已就绪
```

**总耗时 2 秒**，对比直连 ghcr.io 的 600 秒未完成。

### 19.7 顺手发现的真实 bug：`/simulate/memory` 没在分配内存

想验证 `ContainerOOMKilled` 时，调用 `/simulate/memory?mib=400&hold=8`，
容器 limit 是 256Mi，理应 OOM——结果什么都没发生。

看代码：

```python
block = b'x' * (1024 * 1024)
chunks = [block for _ in range(max(mib, 0))]   # ← 问题在这
```

这是**对同一个 1MiB bytes 对象的 mib 个引用**，不是 mib 份拷贝。
无论传多少，实际只占 1MiB。

```python
# 修法：逐个创建独立对象
chunks = [bytearray(1024 * 1024) for _ in range(mib)]
for buf in chunks:
    buf[0] = 1          # 写入，防止懒分配被优化
```

这个 bug 让"演练 OOM"这个功能静默失效——端点返回 200，日志正常，
但内存根本没涨。**故障注入工具本身失效，是最难发现的**，
因为你会以为"演练过了，系统没问题"。

### 19.8 OOM 告警的实测对比

修复后重新触发，这次真 OOM 了：

```text
command terminated with exit code 137     ← SIGKILL
restartCount: 0 → 1
```

告警侧结果：

| 告警 | 结果 | 说明 |
| --- | --- | --- |
| `ContainerOOMKilled` | **firing**，Alertmanager 已收到 | 依赖 ksm 的 last_terminated_reason |
| `ContainerOOMEvents` | 未触发（指标为 0） | 见下 |
| `ImagePullSlow` | pending | 真实捕获到一次 174s 的慢拉取 |

**`ContainerOOMEvents` 为什么没触发**：容器整个重启后，
cAdvisor 里旧容器的 `container_oom_events_total` 随容器消失，新容器从 0 开始。
所以"容器被杀"这类 OOM 只有 `ContainerOOMKilled` 能抓到。

它真正的价值在**另一种场景**：gunicorn 多 worker 时，OOM 只杀掉一个 worker，
master 立刻补位，**容器根本不重启**——这时 ksm 的 `last_terminated_reason` 为空，
只有 cAdvisor 的 OOM 计数能反映。这个场景本次未能构造出来，
**如实标注为未验证**。

### 19.9 ImagePullSlow 的意外验证

`ImagePullSlow` 上线后立刻 pending，查数据：

```text
P90 拉取耗时（秒）:
  node   = 174.0
  master = nan
```

174 秒——正是刚才把新镜像部署到 node 时从 ghcr.io 拉的耗时。
**告警没用造数据，直接抓到了真实的慢拉取。**

这也反过来印证了 P6 的结论：直连公网拉镜像就是分钟级，
所以必须预热或走内网 registry。

### 19.10 又一个反模式：永不消解的告警

OOM 测试做完 7 分钟后，发现 `ContainerOOMKilled` **还在 firing**：

```text
ContainerOOMKilled firing 从 2026-11-06T06:46:47 开始   （已持续 424 秒）
kube_pod_container_status_last_terminated_timestamp 距今 424 秒
```

根因：`kube_pod_container_status_last_terminated_reason` 是**持久状态**，
不是事件。容器只要 OOM 过一次，这条指标就一直是 1，
表达式 `reason == "OOMKilled"` 于是永远为真。

**后果比"没告警"更糟**：告警永不消解 → 值班的人学会忽略它 → 下一次真出事也没人看。

修法：用 `last_terminated_timestamp` 加时间窗，让告警能自动恢复。

```promql
kube_pod_container_status_last_terminated_reason{reason="OOMKilled"} == 1
  and on(namespace, pod, container)
    (time() - kube_pod_container_status_last_terminated_timestamp < 3600)
```

| 指标类型 | 告警写法 | 例子 |
| --- | --- | --- |
| **事件型**（计数器） | `increase(...[5m]) > 0` | `container_oom_events_total` |
| **状态型**（gauge） | `状态 == 坏值` + `for: 时长` | `up == 0`、`phase == Pending` |
| **持久状态型** | `状态 == 坏值` **且** `时间窗内` | 本节这条 |

**判断口诀**：告警写完后问一句"它在问题消失后会自己变回 false 吗？"
不会，就是持久状态型，必须加时间窗。

### 19.11 P7 数据汇总

| 项 | 前 | 后 |
| --- | --- | --- |
| Prometheus target | 7 | **12** |
| 可用指标数 | 744 | **1348** |
| 告警条数 | 16 | **20** |
| 死告警 | 3（+2 隐性） | **0** |
| 镜像跨节点分发 | 手动、>600s | **脚本 2s** |
| OOM 演练 | 静默失效 | 可用 |

审计命令（可作为 CI 步骤）：

```bash
kubectl -n monitoring port-forward svc/prometheus 9090:9090 &
python3 scripts/audit-alerts.py --url http://127.0.0.1:9090
python3 scripts/prewarm-image.sh --check
```
