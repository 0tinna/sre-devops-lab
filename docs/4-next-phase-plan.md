# 阶段规划与完成情况（P1–P7）

最后更新：2026-11-08 · 当前 HEAD `eb00fbf`

## 总览

| 阶段 | 主题 | 状态 | 记录位置 |
| --- | --- | --- | --- |
| P1 | 监控闭环 | ✅ 完成 | 本文 §2、§7；日志第 10–13 节 |
| P2 | 故障演练 | ✅ 完成 | 本文 §3、§7；日志第 14 节 |
| P3 | 交付与自动化 | ✅ 主体完成（CD 待配 Secrets） | 本文 §4、§7 |
| P4 | 日志集中化 | ✅ 完成 | 日志第 15、16 节 |
| P5 | 自动扩缩容与告警补全 | ✅ 完成 | 日志第 17 节 |
| P6 | 可用性加固 | ✅ 完成 | 日志第 18 节 |
| P7 | 死告警审计与容器级指标 | ✅ 完成 | 日志第 19 节 |

> **本文的读法**：§0–§6 是**当初写下的计划**（含当时的实测数据），保留原样作为决策留痕。
> §7 之后是逐阶段的完成情况。想知道"现在什么状态"，读 [`8-handoff.md`](8-handoff.md)，
> 不要从本文的 §0 推断——那里的数字是 2026-11-05 的快照，已经过期。

---

## 0. 本轮实测的现状（2026-11-05 快照，仅作历史）

> **⚠ 这一节已经过期，不要用它判断当前状态。** 保留是为了记录"决策当时看到的是什么"。
> 当前状态见 [`8-handoff.md`](8-handoff.md)。
>
> 过期对照：metrics-server 后来在 P5 装了；日志集中化在 P4 做了；
> 告警从 10 条扩到 20 条；target 从 7 个扩到 12 个。

本文件接手 `sre-devops-lab-agent-handoff.md`，把「尚未完成」的四项拆成可验收的阶段任务，并附上本轮实测证据。

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

## 1. 已落地的产物（当时快照：2026-11-05，尚未 apply）

> **⚠ 本节数字是 P1 初始规划时的快照。** 后来 P4–P7 把 job 数从 4 扩到 12、
> 告警从 10 扩到 20、监控文件增加了 `50-grafana-dashboard.yaml`/`60-loki.yaml`/`75-fluent-bit.yaml`。

清单目录 `k8s/monitoring/`，21 个对象已通过 `kubectl apply --dry-run=client` 校验：

| 文件 | 内容 |
| --- | --- |
| `00-namespace-rbac.yaml` | namespace `monitoring`、Prometheus 的 SA / ClusterRole（node、pod、endpoint、`/metrics`）/ 绑定 |
| `10-prometheus.yaml` | Prometheus 配置（初始 4 个 job，后扩至 12）、**初始 10 条告警规则（后扩至 20）**、Deployment、Service |
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

## 7. 完成情况（2026-11-05 14:20 更新，P1–P3）

> 本节数字是 P1–P3 完成时的快照。P4–P7 后来把 target 扩到 12、告警扩到 20，
> 详见 §8 的阶段小结与操作日志第 15–19 节。

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

### P2 故障演练 —— 已完成

全部 7 项在 2026-11-05 15:23–15:45 执行完毕，每项都有实测证据。

| # | 故障 | 结果 | 关键证据 |
| --- | --- | --- | --- |
| P2-1 | Pod 自愈 | ✅ PASS | 删除 Pod 后约 15 秒重建；`up` 始终为 7，抓取无缺口 |
| P2-2 | ImagePullBackOff | ✅ PASS | 新 Pod `ImagePullBackOff`，Events 显示 `not found`；**老 Pod 2/2 继续服务，`/healthz` 返回 200** |
| P2-3 | CrashLoopBackOff | ✅ PASS | `command: /bin/false` → 4 次重启 → `TargetDown` + `PodRestartTooOften` firing |
| P2-4 | Pending（资源不足） | ✅ PASS | `requests.cpu=8` → Events：`1 Insufficient cpu, 1 node(s) had untolerated taint` |
| P2-5 | OOMKilled | ✅ PASS（超预期） | limit 压到 64Mi 后 **两个 Pod 都 OOMKilled**，一次触发 5 类告警 |
| P2-6 | P95 延迟 | ✅ PASS | 注入慢请求后 P95 稳定 2.2–2.35s，`DemoApiHighLatencyP95` 3 分钟后 firing |
| P2-7 | 回滚演练 | ✅ PASS（发现陷阱） | `opsctl deploy` 坏镜像返回 1；`opsctl rollback` 恢复正常 |

**P2-5 的意外收获**：64Mi 连 gunicorn 启动都不够，两个 Pod 直接 CrashLoopBackOff。
这不是"我设计的演练"，而是更真实的故障——照抄配置压得太狠会连启动都过不去。
一次同时触发 `ContainerOOMKilled`×2、`PodRestartTooOften`×2、`TargetDown`×2、
`DeploymentReplicasMismatch`，共 7 条告警，是最好的告警演示现场。

**P2-7 暴露的陷阱**：连续两次坏发布后 `rollout undo` 只回退一步，
回退到的仍是坏版本（image 还是 `another-bad-tag`）。**undo ≠ 回到好版本**。
正确做法是 `apply` 一份已知good的渲染清单。已写入 SOP 第 9 课。

### 演练期间的告警覆盖情况

| 告警 | 是否被真实触发 | 触发场景 |
| --- | --- | --- |
| `TargetDown` | ✅ | CrashLoop、OOMKilled |
| `PodRestartTooOften` | ✅ | CrashLoop、OOMKilled |
| `ContainerOOMKilled` | ✅ | OOMKilled（limit 64Mi） |
| `DeploymentReplicasMismatch` | ✅ | OOMKilled 期间副本不可用 |
| `DemoApiHighErrorRate` | ✅ | 注入 500 |
| `DemoApiHighLatencyP95` | ✅ | 注入 /simulate/slow |
| `PodNotReady` | ⬜ | 未单独构造（Pending 场景会命中，但未等到 firing） |
| `NodeMemoryPressure` / `NodeDiskPressure` / `NodeHighCPU` | ⬜ | 未构造（不想压垮节点） |

**10 条规则中 6 条经过真实触发验证**，剩余 4 条是容量类，构造成本高且风险大，
在文档里如实标注为"未验证"，不假装验证过。

### P3 交付与自动化 —— 大部分完成

| 项目 | 状态 | 说明 |
| --- | --- | --- |
| `scripts/teardown.sh` | ✅ 完成 | `--dry-run` / `--keep-monitoring` / `--include-rbac`，语法校验通过 |
| `opsctl health` 误报修复 | ✅ 完成 | 跳过 `deletionTimestamp` 非空的 Pod，滚动期间不再误报 |
| CD workflow（SSH 版） | ✅ 完成，待配 Secrets | `.github/workflows/cd.yml`，链路已验证 |
| CD workflow（self-hosted 版） | ⚠️ 保留备用 | runner 包下载仅 21 KB/s，100MB 需 80 分钟，本环境不可行 |
| 部署密钥与链路 | ✅ 已验证 | 专用 ed25519 密钥，跳板机 → master 二级跳转实测通过 |

**CD 的两种方案取舍**（面试可讲）：

| 方案 | 优点 | 缺点 | 本项目选择 |
| --- | --- | --- | --- |
| self-hosted runner | 私钥不出 GitHub，runner 在集群内 | 需下载 100MB runner（本环境 80 分钟） | 保留备用 |
| SSH 经跳板机 | 无需下载，立即可用 | 部署私钥要存进 GitHub Secrets | **采用** |

启用 SSH 版 CD 需要配置 5 个 GitHub Secrets：

```text
JUMP_HOST      1.95.123.118
JUMP_USER      root
JUMP_SSH_KEY   <专用部署私钥内容>
TARGET_HOST    172.31.6.211
TARGET_USER    root
```

专用密钥已生成并验证（`root@1.95.123.118:~/.ssh/authorized_keys` 已装公钥），
私钥文件在 `master:/root/.ssh/deploy_gh_actions`。

### 本轮新增发现（已补进 SOP）

| 发现 | 归入 |
| --- | --- |
| `rollout undo` 只回退一步，连续坏发布会回到坏版本 | SOP 第 9 课 |
| `opsctl health` 把 Terminating Pod 报成故障 | 已修复 |
| 管道会吞掉前一条命令的退出码（`cmd \| tail` 后 `$?` 是 tail 的） | SOP 第 9 课 |
| `requests.cpu` 不能大于 `limits.cpu`，K8s 会在 API 层拒绝 | SOP 第 4 课 |

### 新增发现（原计划的盲区）

| 发现 | 影响 | 已处理 |
| --- | --- | --- |
| kube-state-metrics 探针端点写错 | Pod 永远 NotReady | 改为 `telemetry/readyz` + `http-metrics/livez` |
| gunicorn 多 worker 计数器抖动 | 5xx 告警永不触发 | multiprocess 模式，实测 `drops` 从 3/12 → 0/7 |
| 5xx 比例被探针稀释 | 阈值永远达不到 | 分母排除 `/healthz\|/readyz\|/metrics` |
| `set image` 不应用 env/volume | 新配置静默丢失 | 改用 `apply` + 抽查关键字段 |
| `opsctl deploy` 超时 120s 偏紧 | 冷启动拉取会误报失败 | 演练时显式传 `--timeout 300s` |
| registry.k8s.io 重定向域名解析失败 | kube-state-metrics 拉不下来 | 改用 `k8s.m.daocloud.io` |

## 8. 剩余待办

P1–P7 全部完成。剩下的都是**需要外部条件、或在真实环境才有意义**的项：

| 项目 | 阻塞原因 | 怎么推进 |
| --- | --- | --- |
| 配 5 个 GitHub Secrets 启用 CD | 需要在 GitHub 网页操作 | 见 §7 P3 的 Secrets 清单 |
| Ingress 对外暴露 | 需要额外组件与网络条件 | 装 nginx-ingress 或 traefik，NodePort + 跳板机端口转发 |
| 12 条未验证告警 | 需要专门构造场景 | 优先用 `10-drill-lab.md` 的 11 个场景覆盖；清单见 `3-monitoring-runbook.md` §三 |
| 把审计与预热接进 CI | 目前手动跑 | `ci.yml` 加 `audit-alerts.py` 与 `prewarm-image.sh --check` |
| 容量类告警验证（内存/磁盘/CPU） | 构造会压垮 3.6 GiB 的 worker | 在可丢弃环境做，或用 node-exporter 的 `--collector` 限流模拟 |
| 链路追踪 | 超出本项目范围 | 需要 OpenTelemetry + Tempo/Jaeger |
| 告警分级响应流程 | 单机实验环境无值班概念 | 面试时如实说明这是差距 |

### P4–P7 阶段小结（详细记录在操作日志）

| 阶段 | 核心产出 | 最有价值的发现 |
| --- | --- | --- |
| P4 日志 | Loki 2.9.4 + Fluent Bit 3.1.9，Grafana 双数据源 | **Promtail 的 `kubernetes_sd_configs` 在 K8s 1.34 静默失效**（0 targets、零报错） |
| P5 扩缩容 | metrics-server v0.8.0 + HPA 2-5 副本 | 阈值必须按实测校准：`HPAMaxedOut` 原本 `for: 10m`，压测只 6.5 分钟，永远等不到 |
| P6 可用性 | PDB / ResourceQuota / LimitRange / PriorityClass / 优雅终止 | **PDB 保证"可用副本数"，不保证这个保证能及时兑现**——镜像没预热时 drain 卡 4 分钟 |
| P7 审计 | 12 个 target、20 条告警、两个新工具 | **3 条告警引用了不存在的指标**，但 YAML/promtool/health 全部通过 |
