# 集群盘点记录

> **这是 2026-10-28 的初始基线，保留作历史对照。**
> 现在集群里跑的东西远多于本文记录的内容（监控栈、日志栈、metrics-server、HPA 等）。
> 想看当前状态请读 [`8-handoff.md`](8-handoff.md)。

采集时间：2026-10-28，采集节点：master。

## 拓扑

| 节点 | 角色 | 内网 IP | 操作系统 | 内核 | 容器运行时 | CPU | 内存 | 磁盘 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| master | 控制面 | 172.31.6.211 | Ubuntu 22.04.5 LTS | 5.15.0-173-generic | containerd 2.4.2 | 4 vCPU | 15 GiB | 178 GiB |
| node | 工作节点 | 172.31.12.103 | Ubuntu 22.04.5 LTS | 5.15.0-173-generic | containerd 2.4.2 | 未采集 | 3.6 GiB | 50 GiB |

Kubernetes 版本：v1.34.1。两个节点均为 Ready。

## 已安装组件（2026-10-28 基线）

- kube-apiserver、etcd、kube-controller-manager、kube-scheduler
- CoreDNS，2 个副本
- kube-proxy，每个节点 1 个 Pod
- Flannel CNI，每个节点 1 个 Pod
- 没有业务工作负载
- 没有 PersistentVolume 或 PersistentVolumeClaim
- 没有 StorageClass
- 没有安装 metrics-server（**后于 P5 安装 v0.8.0**）

## 网络检查结论

- master 无法访问 Docker Hub：连接 registry-1.docker.io 超时。
- 可以访问 ghcr.io：Flannel 镜像就是从 GHCR 拉取的。
- 可以访问 registry.aliyuncs.com/google_containers，Kubernetes 镜像使用该仓库。
- 华为云 SWR 端点有响应，但测试的公共镜像路径需要认证。

设计决策：通过 GitHub Actions 把示例镜像发布到 GHCR，集群从 GHCR 拉取，不依赖 Docker Hub。

## 容量说明

工作节点只有约 3.6 GiB 内存，安装监控组件前必须检查 requests 和 limits，避免把节点压垮。

## 初始缺口（已于 P1–P7 补齐，保留作对照）

| 缺口 | 状态 |
| --- | --- |
| 还没有接入 CI/CD 流水线 | ✅ P3 完成（SSH 经跳板机，待配 Secrets） |
| 还没有 Prometheus 告警规则和 Alertmanager 配置 | ✅ P1 完成，现 20 条 |
| 示例应用镜像还没有构建 | ✅ 完成 |
| 还没有做回滚演练 | ✅ P2 完成（并发现 `rollout undo` 只回退一步的陷阱） |
| 没有 metrics-server | ✅ P5 安装 v0.8.0 |
| 没有日志集中收集 | ✅ P4 完成（Loki + Fluent Bit） |
| 没有 Ingress Controller | ⬜ 仍未做，见 `8-handoff.md` §四 |
| 没有 StorageClass | ⬜ 仍未做，是有意保留的实验环境限制 |

## 面试表述

我基于华为云和本地虚拟机搭建了一个两节点 Kubernetes 实验集群，包含一个控制面节点和一个工作节点。我验证了两个节点均为 Ready，检查了控制面组件、CNI、CoreDNS 和 kube-proxy，并记录了集群容量和网络限制。由于 Docker Hub 不可达，我选择 GHCR 作为镜像仓库，因为集群已经可以拉取 GHCR 镜像。随后我把下一阶段拆成 CI/CD、可观测性和受控故障演练三部分。
