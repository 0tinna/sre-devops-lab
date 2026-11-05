# 操作审计记录

记录日期：2026-10-29

执行者：Codex（在用户授权下执行）

## 结论先行

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

| 项目 | 当前状态 | 说明 |
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
