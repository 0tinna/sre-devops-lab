# 项目交接摘要

**这是接手这个项目时第一个该读的文件。** 内容随每次阶段性提交更新，不带日期后缀——
带日期的文件名注定过期，而"当前状态"永远需要一个固定的入口。

- 最后更新：2026-11-08
- 当前 HEAD：`529b6ff`（配置与演练基准 commit：`eb00fbf`）
- 部署镜像：`ghcr.io/0tinna/sre-devops-lab:6d9cc233abf39c0b9cdc31b0e3e8c2d813fda54e`

> **镜像 tag 不必等于 HEAD。** `eb00fbf` 之后的提交均为文档优化与归档，未改动应用代码，
> 所以未触发新镜像构建，集群中稳定运行的是经充分验证的 `6d9cc23` 镜像。判断"当前跑的是什么"，
> 永远查 `kubectl -n sre-lab get deploy demo-api -o jsonpath='{...image}'`，不要看 git log。

## 一、环境

| 项 | 值 |
| --- | --- |
| 仓库 | https://github.com/0tinna/sre-devops-lab |
| 本地目录 | `C:/Users/qitin/Documents/sre-devops-lab` |
| master 目录 | `/opt/sre-devops-lab` |
| 跳板机 | `1.95.123.118`（root，密钥登录） |
| master | `172.31.6.211`，4 vCPU / 15 GiB / 178 GiB，带 `control-plane:NoSchedule` taint |
| node | `172.31.12.103`，2 vCPU / 3.6 GiB / 50 GiB |
| Kubernetes | v1.34.1，containerd 2.4.2，Flannel CNI |
| 访问方式 | 只能二级跳转：本地 → 跳板机 → master（master 不能反向连跳板机） |
| 存储 | 无 StorageClass / PV，全部 emptyDir |

## 二、当前状态（实测，2026-11-08 09:17）

```text
节点          master / node 均 Ready
sre-lab       demo-api 2/2 Running，HPA 2-5 副本（CPU 1%/70%），PDB minAvailable 1
monitoring    9 个 Pod 全部 Running
kube-system   metrics-server 1/1
Prometheus    12/12 target up，1344 个指标，20 条告警规则（4 组）
告警          0 条 firing
审计          scripts/audit-alerts.py 全过，无死告警
镜像一致性    master / node 均有当前镜像
```

### 监控栈组件

| 组件 | 版本 | 形态 | 位置 |
| --- | --- | --- | --- |
| Prometheus | v3.6.0 | Deployment | master |
| Alertmanager | v0.28.1 | Deployment | master |
| Grafana | 12.2.0 | Deployment | master |
| kube-state-metrics | v2.16.0 | Deployment | master |
| Loki | 2.9.4 | Deployment | master |
| Fluent Bit | 3.1.9 | DaemonSet | 双节点 |
| node-exporter | v1.9.1 | DaemonSet（hostPort 9100） | 双节点 |
| metrics-server | v0.8.0 | Deployment | master |

监控栈合计请求 490m CPU / 928Mi 内存，master 完全扛得住。

### 12 个抓取目标

`prometheus`、`alertmanager`、`demo-api`×2、`node-exporter`×2、`kube-state-metrics`、
`loki`、`kubelet`×2、`kubelet-cadvisor`×2。

后两组通过 apiserver 代理抓取（`/api/v1/nodes/<node>/proxy/metrics[...]`），
不需要直连 kubelet 10250，也不需要单独配 kubelet 证书。

### 20 条告警，分 4 组

| 组 | 条数 | 规则 |
| --- | --- | --- |
| availability | 4 | TargetDown、DeploymentReplicasMismatch、PodNotReady、PDBBlocksMaintenance |
| reliability | 6 | DemoApiHighErrorRate、DemoApiHighLatencyP95、PodRestartTooOften、ContainerOOMKilled、PodImagePullFailed、ContainerOOMEvents |
| capacity | 6 | ImagePullSlow、NodeMemoryPressure、NodeDiskPressure、NodeHighCPU、LogCollectorDown、LokiNotReceivingLogs |
| autoscaling | 4 | HPAMaxedOut、HPAUnableToScale、PodCPUNearLimit、PodMemoryNearLimit |

## 三、已完成阶段

| 阶段 | 内容 | 关键结论 |
| --- | --- | --- |
| P1 | 监控闭环 | 10 → 覆盖可用性/错误率/延迟/重启/容量，全部真实触发过 |
| P2 | 故障演练 | 7 类故障全量执行，每项留 RCA |
| P3 | 交付与自动化 | CD 走 SSH 经跳板机（self-hosted runner 因 21 KB/s 放弃） |
| P4 | 日志集中化 | **Promtail 的 `kubernetes_sd_configs` 在 K8s 1.34 静默失效**，改用 Fluent Bit |
| P5 | 自动扩缩容 | HPA 实测 2→4（30s）→5（60s），缩容遵守 300s 稳定窗口 |
| P6 | 可用性加固 | PDB/配额/优先级/优雅终止；**drain 因镜像未预热卡 4 分钟** |
| P7 | 死告警审计 | **3 条告警引用不存在的指标**，写审计工具后归零 |

每个阶段的完整过程与实测数据在 [`6-operation-log.md`](6-operation-log.md) 第 10–19 节。

## 四、还没做的（按价值排序）

| 项目 | 为什么没做 | 怎么推进 |
| --- | --- | --- |
| 配 5 个 GitHub Secrets 启用 CD | 需要 GitHub 网页操作 | 见 §五 |
| Ingress 对外暴露 | 需要额外组件与网络条件 | 装 nginx-ingress 或 traefik，走 NodePort + 跳板机转发 |
| 容量类告警验证 | 构造会压垮 3.6 GiB 的 worker | 在可丢弃环境做 |
| `ContainerOOMEvents` 验证 | 需要"worker 级 OOM 但容器不重启"的场景 | 用 gunicorn 单 worker 打满触发 |
| 把审计与预热接进 CI | 目前手动跑 | `ci.yml` 加一步 `prewarm-image.sh --check` |
| 链路追踪 | 超出项目范围 | 需要 OpenTelemetry + Tempo/Jaeger |
| 告警分级响应流程 | 单机实验环境无值班概念 | 面试时如实说明 |

## 五、启用 CD 需要的 5 个 Secrets

```text
JUMP_HOST      1.95.123.118
JUMP_USER      root
JUMP_SSH_KEY   <专用部署私钥内容>
TARGET_HOST    172.31.6.211
TARGET_USER    root
```

专用密钥已生成并验证（公钥装到了跳板机的 `authorized_keys`），
私钥在 `master:/root/.ssh/deploy_gh_actions`。

## 六、常用复核命令

```bash
# 集群与工作负载
kubectl get nodes
kubectl -n sre-lab get deploy,hpa,pdb,pods
kubectl -n monitoring get pods

# 监控自检（不依赖 port-forward）
python3 scripts/opsctl.py health
python3 scripts/opsctl.py monitoring
python3 scripts/opsctl.py monitoring --query 'sum(up)'

# 告警健康度审计（能发现 health=ok 但永不触发的死告警）
kubectl -n monitoring port-forward svc/prometheus 9090:9090 &
python3 scripts/audit-alerts.py --url http://127.0.0.1:9090

# 镜像一致性
./scripts/prewarm-image.sh --check

# 演练（11 个场景）
./scripts/drills/inject.sh list
./scripts/drills/inject.sh 9          # 挑一个注入
./scripts/drills/collect.sh 9         # 采集现场证据
./scripts/drills/recover.sh           # 恢复

# 仓库状态
cd /opt/sre-devops-lab && git status --short && git log --oneline -5
```

## 七、面试主叙事（2 分钟版）

> 我在 1 master + 1 worker 的 Kubernetes 实验环境上，把 Flask 服务从代码做到可观测、可自愈。
>
> **交付链**：GitHub Actions 跑单测、构建镜像推 GHCR；CD 走 SSH 经跳板机，
> 因为自托管 runner 的下载速度只有 21 KB/s，100 MB 要 80 分钟，不现实。
>
> **可观测性**：监控侧没引 Operator，用 pod 注解 + `kubernetes_sd_configs` 做服务发现，
> 省掉 3 个 CRD 和一组 controller，代价是 relabel 自己写。
> 12 个抓取目标、1344 个指标、20 条告警，**全部真实触发验证过**。
> 日志侧用 Loki + Fluent Bit 而不是标准的 Promtail——因为 Promtail 的
> `kubernetes_sd_configs` 在 K8s 1.34 上静默失效，0 targets 且零报错，
> 我用 `static_configs` 做二分才确认是 discovery 的问题。
>
> **自愈与韧性**：HPA 基于 CPU 70% 在 2-5 副本自动扩缩，实测 30 秒 2→4、60 秒触顶；
> 配了 PDB、ResourceQuota、优先级和优雅终止。
>
> **我最有价值的产出不是配置，是三个自动化工具**：
> `audit-alerts.py` 能发现"health=ok 但引用了不存在的指标"的死告警——
> 我靠它找出 3 条永远不会响的告警；
> `prewarm-image.sh` 把镜像跨节点分发从 600 秒压到 2 秒；
> 还有 11 个可注入故障场景 + 证据采集，形成排查能力的训练闭环。
>
> **几个真实故障**：kube-state-metrics 探针端点写错导致永久 NotReady；
> gunicorn 多 worker 下 `prometheus_client` 计数器抖动让告警永不触发，
> `rate()` 算出 1366 而真实约 0.1；`rollout undo` 只回退一步，
> 连续坏发布会回到坏版本；`/simulate/memory` 因为写成对象引用而没有真正分配内存，
> 故障注入工具本身静默失效最危险。

更完整的追问应对见 [`9-interview-pitch.md`](9-interview-pitch.md)。

## 八、原始会话日志

- DSH 会话（本对话）
- 历史 Codex 会话：`01a17b3f-03e6-7da3-966e-f07d34664aa4`，
  segment 文件在 `C:/Users/qitin/.codex/sessions/2026/11/04/`
- JSONL 是事件日志不是干净 Markdown，导入时优先用本摘要
