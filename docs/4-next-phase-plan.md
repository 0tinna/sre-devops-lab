# 下一阶段执行计划（监控闭环 → 故障演练 → 交付）

核对时间：2026-11-05 09:40 CST（经跳板机 1.95.123.118 到 master 172.31.6.211，全部为只读查询）

本文件接手 `sre-devops-lab-agent-handoff.md`，把「尚未完成」的四项拆成可验收的阶段任务，并附上本轮实测证据。

## 0. 本轮实测的现状

> **更新（2026-11-05 14:20）**：本文档写作时监控栈尚未部署、应用镜像仍是 `652760f`。
> 现在 **P1 已全部完成**，监控栈上线、新镜像 `cce5412d` 已发布、multiprocess 修复验证通过。
> 完成情况见 §7。

| 项目 | 实测结果 | 结论 |
| --- | --- | --- |
| 节点 | master / node 均 Ready，v1.34.1，已运行 7d | 环境仍在，可直接继续 |
| demo-api | `2/2` Available，镜像 `652760f...`，两个 Pod Running，0 重启 | 上一阶段成果稳定 |
| master 容量 | 4 vCPU / 15495 MiB allocatable；已用 950m CPU(23%)、290Mi 内存(1%) | 有充足余量承载监控栈 |
| node 容量 | 2 vCPU / 3619 MiB；内存 request 已占 14% | **不要**把 Prometheus 放 node |
| master taint | `node-role.kubernetes.io/control-plane:NoSchedule` | 监控工作负载必须带 toleration + nodeSelector |
| 存储 | 无 StorageClass、无 PV/PVC | 只能用 emptyDir，Prometheus 历史数据随 Pod 重建丢失 |
| metrics-server | 未安装 | `kubectl top` / HPA 不可用 |
| helm | 未安装 | 监控栈走原生 YAML，不引入 helm |
| Docker Hub | `registry-1.docker.io` 超时（000） | 镜像必须走代理源 |
| quay.io | API 可达（manifest 200），但 **blob 下载 60s 超时**，`crictl pull` 失败 | 直接拉 quay.io 不可靠 |
| ghcr.io | 200，本仓库镜像拉取正常 | 项目自身镜像链路没问题 |
| docker.m.daocloud.io | 401（正常 token 挑战），`busybox` 实测拉取成功 | 作为 Prometheus / Grafana 官方镜像的代理源 |
| registry.k8s.io | 307 重定向可跟 | kube-state-metrics 走这里 |

一句话：**监控组件放 master，镜像走 daocloud 代理，存储用 emptyDir。**

## 1. 已落地的产物（本轮直接完成，尚未 apply）

清单目录 `k8s/monitoring/`，21 个对象已通过 `kubectl apply --dry-run=client` 校验：

| 文件 | 内容 |
| --- | --- |
| `00-namespace-rbac.yaml` | namespace `monitoring`、Prometheus 的 SA / ClusterRole（node、pod、endpoint、`/metrics`）/ 绑定 |
| `10-prometheus.yaml` | Prometheus 配置（4 个 job：self、alertmanager、demo-api 注解发现、node-exporter 节点发现、kube-state-metrics）、**10 条告警规则**、Deployment、Service |
| `20-alertmanager.yaml` | 路由（critical 快通道）、抑制规则、Deployment、Service |
| `30-exporters.yaml` | node-exporter DaemonSet（hostNetwork:9100，覆盖 master 的 taint）、kube-state-metrics 全套 RBAC + Deployment + Service |
| `40-grafana.yaml` | 管理员 Secret、Prometheus 数据源 provisioning、Deployment、Service |

资源预算（全部落在 master）：Prometheus 512Mi 上限 + Alertmanager 128Mi + kube-state-metrics 256Mi + Grafana 256Mi + node-exporter 2×64Mi ≈ **1.3 GiB 上限，请求约 0.6 GiB**，master 现有 14.4 GiB 可用，安全。

告警规则覆盖交接文档列出的六项，另加三条：

```text
TargetDown                     目标不可用（up == 0，1m）
DeploymentReplicasMismatch     可用副本不足（2m）
PodNotReady                    Pod 非 Running（2m）
DemoApiHighErrorRate           5xx 占比 > 5%（2m）
DemoApiHighLatencyP95          P95 > 1s（3m）
PodRestartTooOften             15m 内重启 > 3 次
ContainerOOMKilled             OOM 被杀
NodeMemoryPressure / NodeDiskPressure / NodeHighCPU   容量类
```

## 2. P1 监控闭环（目标：1 个工作日，全部可验收）

| # | 动作 | 验收标准 |
| --- | --- | --- |
| P1-1 | 推送 `k8s/monitoring/` 到 main，master 上 `git pull` | `git log -1` 含 monitoring 清单 |
| P1-2 | `kubectl apply -f k8s/monitoring/` | `kubectl -n monitoring get pods` 全 Running，无 CrashLoop |
| P1-3 | 检查抓取：`kubectl -n monitoring port-forward svc/prometheus 9090` → `/targets` | 4 个 job 全部 `UP`，rule 文件 10 条规则 Loaded |
| P1-4 | Grafana 建 3 个面板：服务 RED（rate/错误率/P95）、Pod 资源（CPU/内存 vs request）、节点容量（内存/磁盘） | 面板能出图，数据源 `Prometheus` 默认可用 |
| P1-5 | **告警注入**：`for i in $(seq 1 40); do curl -s .../simulate/error; done` | Prometheus 里 `DemoApiHighErrorRate` 依次 Pending → Firing；Alertmanager UI 出现该告警 |
| P1-6 | 告警恢复：停止注入 2 分钟后观察 | 告警变为 Resolved，`docs/6-operation-log.md` 记录起止时间与截图路径 |

演示前必须把 Grafana 默认口令改掉（清单里已写覆盖命令）。

## 3. P2 故障演练（目标：1 个工作日，每项留 RCA）

顺序按「影响面从小到大」，每项都要求：现象 → 证据（Events/日志/指标）→ 假设 → 修复 → 验证 → 回滚点。

| # | 故障 | 注入方式 | 预期告警 | 回滚 |
| --- | --- | --- | --- | --- |
| P2-1 | 自愈 | `kubectl -n sre-lab delete pod <pod>` | 无（验证控制器重建） | 不需要 |
| P2-2 | ImagePullBackOff | `set image ... :missing-tag` | `TargetDown`（副本掉到 0 后） | `rollout undo` |
| P2-3 | CrashLoopBackOff | 临时改 `command` 为 `["/bin/false"]` 或注入错误环境变量 | `PodRestartTooOften` | `rollout undo` |
| P2-4 | Pending | 临时把 `requests.cpu` 改成 `8` | 副本不足 / `TargetDown` | `rollout undo` |
| P2-5 | OOMKilled | 加 `/simulate/memory` 端点 + `limits.memory: 32Mi` | `ContainerOOMKilled` + `PodRestartTooOften` | 恢复 limit |
| P2-6 | 迟到/慢请求 | `curl /simulate/slow` 持续打 | `DemoApiHighLatencyP95` | 停止压测 |
| P2-7 | 回滚演练 | `opsctl.py deploy <bad-sha>` → `opsctl.py rollback` | 回滚期间副本不足 | `rollout status` 2/2 |

P2-5 需要给 `app/app.py` 加一个受控内存分配端点（默认关闭，靠环境变量开启），否则 OOM 无法可控复现。

## 4. P3 交付与自动化（目标：半天到 1 天）

1. **CD 决策**：在 `ci.yml` 增加 `deploy` job 需要集群凭证。两种方案，计划采用 B：
   - A：把 kubeconfig 存为 GitHub Secret —— 公网 runner 直连内网 master，需要端口暴露，**不采用**。
   - B：在 master 上跑 self-hosted runner（需外网出站，已确认 GitHub 可达），只在 `main` 上触发 `kubectl set image` + `rollout status`。
2. `scripts/opsctl.py` 增加 `monitoring` 子命令：打印 targets 健康度与当前 firing 告警，失败返回非零（可接定时巡检）。
3. 更新 `README.md` 的「下一阶段」为「当前状态」，补监控架构图。
4. 资源清理脚本 `scripts/teardown.sh`：`kubectl delete -f k8s/monitoring/` + `kubectl delete ns sre-lab`（演示结束后可一键回收，node 3.6 GiB 环境不宜长期挂着）。

## 5. 面试叙事对应

| 面试点 | 本项目证据 |
| --- | --- |
| 为什么要 toleration + nodeSelector | master 有 NoSchedule taint，node 只有 3.6 GiB，监控栈必须落在控制面 |
| ServiceMonitor 还是静态配置 | 未装 operator，用 pod 注解 + `kubernetes_sd_configs`，解释取舍：少 3 个 CRD、少 operator 组件，代价是 relabel 自己要写 |
| 告警有没有真的触发过 | P1-5/P2 有 Firing 与 Resolved 时间线，不是「配了就算」 |
| 存储取舍 | 没有 StorageClass，Prometheus 用 emptyDir + `retention.time=6h`，重启丢历史，明确说这是实验环境的限制 |
| 镜像源策略 | Docker Hub 不可达、quay.io blob 超时，改用 daocloud 代理 + registry.k8s.io |
| 资源受限下的调度 | 用 request/limit 把 1.3 GiB 的监控栈压进 15 GiB 控制面，node 只跑业务 |

## 6. 风险与回滚

- 所有监控组件在独立 `monitoring` 命名空间，`kubectl delete ns monitoring` 即可完全回滚，不影响 `sre-lab`。
- node-exporter 用 `hostNetwork` + `hostPort 9100`：仅占用一个端口，删除 DaemonSet 后释放。
- 镜像代理是外部依赖，若 daocloud 失效，备用 `registry.cn-hangzhou.aliyuncs.com` 与 `quay.io`（需容忍超时重试）。
- 压测与故障注入只在 `sre-lab` 命名空间内进行，禁止动 `kube-system`。

## 7. 完成情况（2026-11-05 14:20 更新）

### P1 监控闭环 —— 已完成

| # | 动作 | 状态 | 证据 |
| --- | --- | --- | --- |
| P1-1 | 清单推送 main | ✅ | 提交 `84a0d4f`，push 到 `cce5412` |
| P1-2 | `kubectl apply` 监控栈 | ✅ | monitoring 命名空间 6/6 Pod Ready |
| P1-3 | 抓取检查 | ✅ | 7/7 target `up`，10 条规则 `health=ok` |
| P1-4 | Grafana 看板 | ✅ | 数据源 + 13 面板均由 ConfigMap provisioning，无需手工导入 |
| P1-5 | 告警注入 | ✅ | `DemoApiHighErrorRate` pending → firing，Alertmanager 收到 active |
| P1-6 | 告警恢复 | ✅ | 停止注入后自动 resolved，alerts 归零 |

额外完成：`TargetDown`、`PodRestartTooOften` 在 CrashLoop 演练中真实触发并自动消解。

### P2 故障演练 —— 部分完成

| # | 故障 | 状态 | 说明 |
| --- | --- | --- | --- |
| P2-1 | 自愈 | 未单独执行 | 发布滚动中已间接验证 |
| P2-2 | ImagePullBackOff | 待执行 | 需占位 tag |
| P2-3 | CrashLoopBackOff | ✅ 已执行 | `command: /bin/false` → 4 次重启 → 双告警 firing → `rollout undo` 恢复 |
| P2-4 | Pending | 待执行 | |
| P2-5 | OOMKilled | **可执行** | `/simulate/memory` 已随新镜像上线，验证返回 200 |
| P2-6 | 慢请求 P95 | 待执行 | |
| P2-7 | 回滚演练 | ✅ 部分 | `rollout undo` 已验证，`opsctl rollback` 待补 |

### 新增发现（原计划的盲区）

| 发现 | 影响 | 已处理 |
| --- | --- | --- |
| kube-state-metrics 探针端点写错 | Pod 永远 NotReady | 改为 `telemetry/readyz` + `http-metrics/livez` |
| gunicorn 多 worker 计数器抖动 | 5xx 告警永不触发 | multiprocess 模式，实测 `drops` 从 3/12 → 0/7 |
| 5xx 比例被探针稀释 | 阈值永远达不到 | 分母排除 `/healthz\|/readyz\|/metrics` |
| `set image` 不应用 env/volume | 新配置静默丢失 | 改用 `apply` + 抽查关键字段 |
| `opsctl deploy` 超时 120s 偏紧 | 冷启动拉取会误报失败 | 演练时显式传 `--timeout 300s` |
| registry.k8s.io 重定向域名解析失败 | kube-state-metrics 拉不下来 | 改用 `k8s.m.daocloud.io` |

### P3 交付与自动化 —— 未开始

- self-hosted runner：未开始。
- `opsctl monitoring`：**已完成**（超出原计划，提前交付）。
- `scripts/teardown.sh`：未开始。
