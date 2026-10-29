# SRE / DevOps 面试实验项目

这是一个面向 DevOps / SRE 实习生面试的最小可演示项目。

目标不是继续安装组件，而是形成一条完整闭环：

```text
代码提交 -> CI 构建镜像 -> GHCR -> Kubernetes 部署 -> 健康检查 -> 可观测性 -> 回滚 -> 事故记录
```

## 项目内容

- Flask 示例 API，提供 `/healthz`、`/readyz`、`/metrics`、`/api/orders`
- 受控故障接口：`/simulate/error`、`/simulate/slow`
- 多阶段 Dockerfile，容器以非 root 用户运行
- Kubernetes Deployment 与 Service，包含探针、资源限制和安全上下文
- GitHub Actions：校验代码、运行测试、构建并推送 GHCR
- `scripts/opsctl.py`：集群盘点、健康检查、日志收集、发布和回滚
- `docs/cluster-inventory.md`：真实集群盘点记录
- `docs/github-push-sop.md`：GitHub 部署密钥与推送 SOP

## 架构

```text
GitHub Actions
    |
    | 构建并推送
    v
GHCR 镜像
    |
    v
Kubernetes 命名空间 sre-lab
    +-- Deployment demo-api（2 副本）
    +-- Service demo-api（ClusterIP）
```

实验集群为 1 个控制面节点 + 1 个工作节点。工作节点约 3.6 GiB 内存，因此监控组件必须设置较小的 requests 和 limits。

## 当前集群

- master：172.31.6.211，控制面节点，4 vCPU / 15 GiB / 178 GiB
- node：172.31.12.103，工作节点，3.6 GiB / 50 GiB
- Kubernetes：v1.34.1
- 网络：Docker Hub 不可达，GHCR 可达
- 当前没有业务工作负载、存储类和监控组件

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
```

当健康检查失败时，CLI 会返回非零退出码，后续可以接入 CI 或定时巡检。

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

### 应用错误与慢请求

```bash
kubectl -n sre-lab port-forward svc/demo-api 8080:80
curl -i http://127.0.0.1:8080/simulate/error
curl -i http://127.0.0.1:8080/simulate/slow
```

### Pod 自愈

```bash
kubectl -n sre-lab delete pod <pod-name>
kubectl -n sre-lab get pods -w
```

## 下一阶段

使用较小的资源占用部署 Prometheus、Grafana 和 Alertmanager，并配置以下告警：

- 监控目标不可用
- 5xx 比例过高
- P95 延迟过高
- Pod 重启过于频繁
- Deployment 可用副本不足
- 节点磁盘或内存压力

在告警真正触发并被处理之前，不要把它称为完整的监控体系。

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

本项目把自动执行和人工操作分开记录。详细时间线见 `docs/operation-log.md`。

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
