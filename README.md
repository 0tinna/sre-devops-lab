# SRE / DevOps 面试实验项目

这是一个面向 DevOps / SRE 实习生面试的最小可演示项目。

目标不是继续安装组件，而是形成一条完整闭环：

```text
代码提交 -> CI 构建镜像 -> GHCR -> Kubernetes 部署 -> 健康检查 -> 可观测性 -> 回滚 -> 事故记录
```

## 项目内容

- Flask 示例 API，提供 `/healthz`、`/readyz`、`/metrics`、`/api/orders`
- 受控故障接口：`/simulate/error`、`/simulate/slow`、`/simulate/memory`（默认关闭，`ENABLE_FAULT_ENDPOINTS=1` 开启）
- gunicorn 多 worker + `prometheus_client` multiprocess 模式，避免计数器在 worker 间抖动
- 多阶段 Dockerfile，容器以非 root 用户运行
- Kubernetes Deployment 与 Service，包含探针、资源限制和安全上下文
- GitHub Actions：校验代码、运行测试、构建并推送 GHCR
- Prometheus / Alertmanager / Grafana / node-exporter / kube-state-metrics，20 条告警规则与开箱即用的看板
- 12 个抓取目标，含 cAdvisor（容器 CPU/内存/OOM）与 Loki 自身指标
- Loki + Fluent Bit 日志集中收集，Grafana 双数据源（指标 + 日志）
- metrics-server + HPA，基于 CPU 70% 在 2-5 副本间自动扩缩
- 可用性加固：PDB、ResourceQuota、LimitRange、PriorityClass、优雅终止、拓扑分布
- `scripts/opsctl.py`：集群盘点、健康检查、日志收集、发布、回滚、监控自检
- `scripts/audit-alerts.py`：审计告警表达式引用的指标是否存在（防"死告警"）
- `scripts/prewarm-image.sh`：把镜像主动分发到所有节点（2 秒 vs 直连公网 10 分钟）
- `scripts/drills/`：11 个可注入故障场景，用于盲练排查

## 文档

**文件名前面的数字就是学习顺序**，按 1 → 9 读即可。完整索引见 [`docs/README.md`](docs/README.md)。

| 编号 | 文档 | 内容 |
| --- | --- | --- |
| 1 | [`1-manual-from-zero-to-one.md`](docs/1-manual-from-zero-to-one.md) | 从 0 到 1 实践手册：这个项目怎么搭起来的 |
| 2 | [`2-troubleshooting-sop.md`](docs/2-troubleshooting-sop.md) | **9 节课的故障排查 SOP**，真实问题提炼，每课含自检题 |
| 3 | [`3-monitoring-runbook.md`](docs/3-monitoring-runbook.md) | 监控访问、10 条告警清单、D1–D8 演练步骤 |
| 4 | [`4-next-phase-plan.md`](docs/4-next-phase-plan.md) | 下一阶段计划、实测证据与完成情况 |
| 5 | [`5-cluster-inventory.md`](docs/5-cluster-inventory.md) | 硬件、网络、已装组件的事实基线 |
| 6 | [`6-operation-log.md`](docs/6-operation-log.md) | 每个动作的时间线与执行者 |
| 7 | [`7-github-push-sop.md`](docs/7-github-push-sop.md) | GitHub 部署密钥与推送 SOP |
| 8 | [`8-handoff-2026-11-05.md`](docs/8-handoff-2026-11-05.md) | 项目交接摘要：当前状态与待办 |
| 9 | [`9-interview-pitch.md`](docs/9-interview-pitch.md) | 面试表述与追问应对：30 秒版、可深讲的故事 |
| 10 | [`10-drill-lab.md`](docs/10-drill-lab.md) | **故障演练实验室**：8 个可注入场景，采集证据自己排查 |

只想知道"现在什么状态"，读 8；想学排查方法，读 2；想准备面试，读 9；
**想动手练，直接跑 `./scripts/drills/inject.sh list`**。

## 架构

```text
GitHub Actions                      monitoring 命名空间（全部固定在 master）
    |                                 +-- Prometheus（抓取 7 个 target，16 条告警）
    | 构建并推送                      +-- Alertmanager
    v                                 +-- Grafana（Prometheus + Loki 双数据源，15 面板）
GHCR 镜像                             +-- node-exporter（DaemonSet，hostPort 9100）
    |                                 +-- kube-state-metrics
    v                                 +-- Loki（日志存储，保留 24h）
Kubernetes 命名空间 sre-lab           +-- Fluent Bit（DaemonSet，采集容器日志）
    +-- Deployment demo-api（2 副本）  <-- prometheus 通过 Pod 注解自动发现
    |     +-- startup/readiness/liveness 三层探针
    |     +-- preStop + grace 30s（优雅终止）
    |     +-- priorityClass: sre-lab-critical
    +-- Service demo-api（ClusterIP）  <-- fluent-bit tail /var/log/containers
    +-- HPA demo-api（2-5 副本）       <-- 基于 CPU 70%，metrics-server 提供指标
    +-- PodDisruptionBudget（minAvailable 1）
    +-- ResourceQuota（4 CPU / 4Gi）+ LimitRange（默认值与上限）

kube-system
    +-- metrics-server v0.8.0         <-- kubectl top / HPA 的数据来源
```

实验集群为 1 个控制面节点 + 1 个工作节点。工作节点约 3.6 GiB 内存，所以监控栈全部
`nodeSelector` 到 master 并加 control-plane taint 的 toleration，
总请求 490m CPU / 928Mi 内存。

`demo-api` 也带 control-plane toleration 作为 worker 故障时的兜底，
但 nodeAffinity 偏好 worker，正常状态下不会占用控制面资源。

## 当前集群

- master：172.31.6.211，控制面节点，4 vCPU / 15 GiB / 178 GiB
- node：172.31.12.103，工作节点，2 vCPU / 3.6 GiB / 50 GiB
- Kubernetes：v1.34.1
- 网络：Docker Hub 不可达，quay.io blob 超时，GHCR 可达，`docker.m.daocloud.io` 与 `k8s.m.daocloud.io` 可用
- `demo-api` Deployment 2/2 Running，镜像 `ghcr.io/0tinna/sre-devops-lab:652760f...`
- `monitoring` 命名空间已部署（Prometheus / Alertmanager / Grafana / node-exporter / kube-state-metrics），7 个 target 全部 up
- 存储：没有 StorageClass，Prometheus 与 Grafana 使用 emptyDir，历史数据不持久

## 快速开始

1. 在 GitHub 创建空仓库 `sre-devops-lab`。
2. 推送代码到 `main` 分支。
3. `ci` workflow 会执行代码校验和单元测试。
4. 推送到 `main` 后，流水线会发布：

```text
ghcr.io/0tinna/sre-devops-lab:latest
ghcr.io/0tinna/sre-devops-lab:<commit-sha>
```

实验环境建议把 GHCR 包设为公开，简化镜像拉取。如果使用私有包，需要创建 imagePullSecret。

## 手动部署

在 master 节点执行：

```bash
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/app.yaml
kubectl -n sre-lab set image deployment/demo-api demo-api=ghcr.io/0tinna/sre-devops-lab:<commit-sha>
kubectl -n sre-lab rollout status deployment/demo-api --timeout=120s
kubectl -n sre-lab get pods -o wide
```

验证服务：

```bash
kubectl -n sre-lab port-forward svc/demo-api 8080:80
curl -i http://127.0.0.1:8080/healthz
curl -i http://127.0.0.1:8080/readyz
curl -s http://127.0.0.1:8080/metrics | head
```

如果镜像拉取失败，先检查 Pod：

```bash
kubectl -n sre-lab describe pod <pod-name>
kubectl -n sre-lab get events --sort-by=.lastTimestamp
kubectl -n sre-lab get pod <pod-name> -o yaml
```

## 运维 CLI

在 master 节点执行：

```bash
python3 scripts/opsctl.py inventory
python3 scripts/opsctl.py health
python3 scripts/opsctl.py logs <pod-name>
python3 scripts/opsctl.py deploy ghcr.io/0tinna/sre-devops-lab:<sha>
python3 scripts/opsctl.py rollback
python3 scripts/opsctl.py monitoring
python3 scripts/opsctl.py monitoring --query 'sum(up)'
```

当健康检查失败时，CLI 会返回非零退出码，后续可以接入 CI 或定时巡检。

`monitoring` 子命令刻意不依赖 port-forward：普通检查直接读 Pod Ready 状态；
只有显式传 `--query` 时才通过 apiserver 的 service proxy 打 Prometheus HTTP API，
少开一个网络入口，也便于在无浏览器的 SSH 会话里查指标。

## 受控故障演练

只能在可丢弃的实验集群中执行。

### 镜像拉取失败

```bash
kubectl -n sre-lab set image deployment/demo-api demo-api=ghcr.io/0tinna/sre-devops-lab:missing-tag
kubectl -n sre-lab get pods -w
kubectl -n sre-lab describe pod <pod-name>
kubectl -n sre-lab rollout undo deployment/demo-api
```

记录：现象、Pod Events、假设、命令输出、修复动作和验证结果。

### CreateContainerConfigError

如果 Pod 事件出现 `container has runAsNonRoot and image has non-numeric user`，说明镜像的 `USER` 是用户名而不是数字 UID。修复方式是 Dockerfile 使用 `USER 10001:10001`，并在 Pod 的 `securityContext` 中设置 `runAsUser: 10001`、`runAsGroup: 10001`。

### 应用错误与慢请求

故障端点默认关闭，只有容器环境变量 `ENABLE_FAULT_ENDPOINTS=1` 时可用（`k8s/app.yaml` 已按实验环境开启）。关闭时返回 404。

```bash
kubectl -n sre-lab port-forward svc/demo-api 8080:80
curl -i http://127.0.0.1:8080/simulate/error
curl -i http://127.0.0.1:8080/simulate/slow
curl -i 'http://127.0.0.1:8080/simulate/memory?mib=512&hold=60'   # 演练 OOMKilled
```

### Pod 自愈

```bash
kubectl -n sre-lab delete pod <pod-name>
kubectl -n sre-lab get pods -w
```

## 下一阶段

详细拆分、验收标准与实测证据见 `docs/4-next-phase-plan.md`。

监控清单已落在 `k8s/monitoring/`（未 apply），包含 Prometheus、Alertmanager、node-exporter、kube-state-metrics、Grafana，以及 10 条告警规则：

- 监控目标不可用
- 5xx 比例过高
- P95 延迟过高
- Pod 重启过于频繁
- Deployment 可用副本不足
- 容器 OOM 被杀
- 节点内存、磁盘、CPU 压力

在告警真正触发并被处理之前，不要把它称为完整的监控体系。

## 监控清单

```bash
kubectl apply -f k8s/monitoring/
kubectl -n monitoring get pods
kubectl -n monitoring port-forward svc/prometheus 9090:9090    # /targets 检查抓取
kubectl -n monitoring port-forward svc/alertmanager 9093:9093  # 查看 firing 告警
kubectl -n monitoring port-forward svc/grafana 3000:3000       # 默认 admin / lab-grafana-change-me
```

调度约束：监控组件全部固定在 master（`nodeSelector: kubernetes.io/hostname=master` 加 control-plane taint 的 toleration），因为工作节点只有 3.6 GiB；Prometheus 用 emptyDir，`retention.time=6h`，集群没有 StorageClass。

镜像源：Docker Hub 与 quay.io 在本环境不可靠，Prometheus/Grafana 走 `docker.m.daocloud.io` 代理，kube-state-metrics 走 `registry.k8s.io`。

## 面试表达

- 为什么使用 Deployment，而不是直接创建 Pod
- readiness 与 liveness 的区别
- Service 如何通过标签和选择器找到 Pod
- 滚动更新和 `kubectl rollout undo` 的工作原理
- GitHub Actions 如何通过 `GITHUB_TOKEN` 登录 GHCR
- 如何从 Pod 状态、Events 和 describe 输出排查 ImagePullBackOff
- 为什么镜像标签同时使用 commit SHA，而不只使用 latest
- `opsctl.py` 自动化了什么，以及刻意没有做什么

## 操作透明度

本项目把自动执行和人工操作分开记录。详细时间线见 `docs/6-operation-log.md`。

- `[x]` 表示已经由 Codex 执行。
- `[ ]` 表示等待用户或后续阶段执行。
- `只读` 表示只查询，不改变集群状态。
- `写操作` 表示会修改本地文件、Git 仓库或集群。

## 安全注意事项

- 不要提交镜像仓库密码或 kubeconfig。
- 使用专用部署身份并遵循最小权限。
- 不要把 Kubernetes API 直接暴露到公网。
- 使用 commit SHA 标签保证部署可复现。
- 应用 AI 生成的 YAML 和脚本前必须人工审查。
