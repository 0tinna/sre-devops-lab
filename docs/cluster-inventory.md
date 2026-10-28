# 集群盘点记录

采集时间：2026-10-28，采集节点：master。

## 拓扑

| 节点 | 角色 | 内网 IP | 操作系统 | 内核 | 容器运行时 | CPU | 内存 | 磁盘 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| master | 控制面 | 172.31.6.211 | Ubuntu 22.04.5 LTS | 5.15.0-173-generic | containerd 2.4.2 | 4 vCPU | 15 GiB | 178 GiB |
| node | 工作节点 | 172.31.12.103 | Ubuntu 22.04.5 LTS | 5.15.0-173-generic | containerd 2.4.2 | 未采集 | 3.6 GiB | 50 GiB |

Kubernetes 版本：v1.34.1。两个节点均为 Ready。

## 已安装组件

- kube-apiserver、etcd、kube-controller-manager、kube-scheduler
- CoreDNS，2 个副本
- kube-proxy，每个节点 1 个 Pod
- Flannel CNI，每个节点 1 个 Pod
- 没有业务工作负载
- 没有 PersistentVolume 或 PersistentVolumeClaim
- 没有 StorageClass
- 没有安装 metrics-server

## 网络检查结论

- master 无法访问 Docker Hub：连接 registry-1.docker.io 超时。
- 可以访问 ghcr.io：Flannel 镜像就是从 GHCR 拉取的。
- 可以访问 registry.aliyuncs.com/google_containers，Kubernetes 镜像使用该仓库。
- 华为云 SWR 端点有响应，但测试的公共镜像路径需要认证。

设计决策：通过 GitHub Actions 把示例镜像发布到 GHCR，集群从 GHCR 拉取，不依赖 Docker Hub。

## 容量说明

工作节点只有约 3.6 GiB 内存，安装监控组件前必须检查 requests 和 limits，避免把节点压垮。

## 当前缺口

- 还没有接入 CI/CD 流水线。
- 还没有 Prometheus 告警规则和 Alertmanager 配置。
- 示例应用镜像还没有构建。
- 还没有做回滚演练。
- 没有 Ingress Controller。
- 没有 StorageClass。

这些缺口是有意保留的，它们就是面试项目的下一阶段任务。

## 面试表述

我基于华为云和本地虚拟机搭建了一个两节点 Kubernetes 实验集群，包含一个控制面节点和一个工作节点。我验证了两个节点均为 Ready，检查了控制面组件、CNI、CoreDNS 和 kube-proxy，并记录了集群容量和网络限制。由于 Docker Hub 不可达，我选择 GHCR 作为镜像仓库，因为集群已经可以拉取 GHCR 镜像。随后我把下一阶段拆成 CI/CD、可观测性和受控故障演练三部分。
