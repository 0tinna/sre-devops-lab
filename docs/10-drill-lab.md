# 故障演练实验室

**用途**：制造真实故障 → 采集真实现场证据 → 你自己系统性排查 → 对照答案。
不是"看文档学"，是"看证据猜"。

## 怎么用

```bash
cd /opt/sre-devops-lab

# 1. 看有哪些场景（先别看答案）
./scripts/drills/inject.sh list

# 2. 注入一个场景
./scripts/drills/inject.sh 3

# 3. 采集现场证据到 docs/drills/cases/S3-<时间戳>/
./scripts/drills/collect.sh 3

# 4. 自己排查（建议顺序见下）
#    查完再翻 docs/drills/answers.md

# 5. 恢复
./scripts/drills/recover.sh
```

**重要**：`inject.sh` 只注入，不解释。`collect.sh` 只采集，不分析。
答案在 `docs/drills/answers.md`，**先排查完再看**。

## 现场包包含什么

每次 `collect.sh` 生成一个目录，11 个文件：

| 文件 | 内容 | 什么时候用 |
| --- | --- | --- |
| `summary.txt` | 集群/工作负载/事件速览 | **第一个看**，判断问题层次 |
| `describe.txt` | 每个 Pod 完整 describe | **最权威**，Events 在这里 |
| `logs-current.txt` | 当前容器日志 | 应用层报错 |
| `logs-previous.txt` | 崩溃前日志 | 容器重启过时必看 |
| `events.txt` | 命名空间事件时间线 | 找时间顺序 |
| `endpoints.txt` | Service / Endpoints / Pod 标签 | 路由问题 |
| `deploy.json` | Deployment 完整定义 | 配置是否被改 |
| `rs.txt` | 各 ReplicaSet 配置对比 | "回退后仍异常"时看 |
| `metrics.txt` | 7 组 Prometheus 指标快照 | 交叉验证假设 |

## 建议的排查顺序

```text
① summary.txt 里的工作负载状态
     ├─ Pending          → 调度问题（第 4 课）
     ├─ ImagePullBackOff → 镜像问题（第 2 课）
     ├─ CrashLoopBackOff → 启动/运行问题（第 3、6 课）
     ├─ Running 但 0/1   → 探针问题（第 5 课）
     └─ Running 且 1/1，但访问不通 → 路由问题（第 5 课）
② describe.txt 的 Events —— 不要跳过，这是最权威的证据
③ 按 ② 指向的方向继续查，用 metrics.txt 交叉验证
④ 最后看 deploy.json / rs.txt 确认配置是否被改
```

## 11 个场景（现象卡，不含答案）

### 场景 1 · 服务还在跑，但新 Pod 一直不就绪

**你会看到**：`kubectl get pods` 里新 Pod 是 `Running` 但 `READY 0/1`，
老 Pod 正常。Deployment 显示 `2/2 AVAILABLE`。

**现场包**：`docs/drills/cases/S1-*/`

**关键问题**：
- 应用到底有没有正常工作？
- 为什么 `0/1` 但 Deployment 还说 2/2 可用？
- Endpoints 里有没有这个新 Pod？

### 场景 2 · 发布后容器反复重启

**你会看到**：新 Pod `CrashLoopBackOff`，`RESTARTS` 持续增长，日志很少或直接空。

**现场包**：`docs/drills/cases/S2-*/`

**关键问题**：
- 容器是什么状态退出的？退出码是多少？
- 日志为什么可能是空的？
- `logs-previous.txt` 和 `logs-current.txt` 有什么区别？

### 场景 3 · 新版本一上线就挂

**你会看到**：新 Pod 起不来，`lastState.terminated.reason` 是 `OOMKilled`，
退出码 137。

**现场包**：`docs/drills/cases/S3-*/`

**关键问题**：
- OOMKilled 一定是"内存泄漏"吗？
- 容器还没处理任何请求就被杀，说明什么？
- 怎么区分"limit 太小"和"真的泄漏"？

### 场景 4 · Pod 一直 Pending，不调度

**你会看到**：Pod 状态 `Pending`，`NODE` 列是 `<none>`，没有任何日志。

**现场包**：`docs/drills/cases/S4-*/`

**关键问题**：
- Pending 说明问题在哪一层？
- Events 里 `FailedScheduling` 的具体原因是什么？
- 两个节点分别因为什么被排除？

### 场景 5 · 镜像拉不下来

**你会看到**：`ImagePullBackOff` / `ErrImagePull`。

**现场包**：`docs/drills/cases/S5-*/`

**关键问题**：
- 是网络问题、权限问题，还是标签问题？
- 用 `crictl pull` 直接测能排除哪些可能？
- 老 Pod 还在服务吗？为什么？

### 场景 6 · 服务间歇性不可用

**你会看到**：Pod 在 `1/1` 和 `0/1` 之间反复跳，Endpoints 时有时无。

**现场包**：`docs/drills/cases/S6-*/`

**关键问题**：
- 探针的哪个参数会导致"抖动"而不是"稳定失败"？
- `timeoutSeconds` / `periodSeconds` / `failureThreshold` 各自影响什么？
- 这种抖动对上游调用方意味着什么？

### 场景 7 · 发布成功但功能不对

**你会看到**：Pod 全部 Running，健康检查通过，但某些功能缺失或指标异常。

**现场包**：`docs/drills/cases/S7-*/`

**关键问题**：
- `rollout status` 成功能证明配置正确吗？
- 怎么对比新旧 Pod 的实际配置差异？
- 历史 ReplicaSet 里藏着什么线索？

### 场景 8 · 服务访问不通，但 Pod 都正常

**你会看到**：Pod 全 `1/1 Running`，应用日志正常，但通过 Service 访问失败或 502。

**现场包**：`docs/drills/cases/S8-*/`

**关键问题**：
- Pod 正常但 Service 不通，问题可能在哪？
- Service 靠什么找到 Pod？
- Endpoints 为空说明什么？

### 场景 9 · 日志里一直有 ERROR，但指标全绿

**你会看到**：`kubectl get pods` 全 `1/1 Running`，Prometheus 里没有任何告警，
5xx 比例是 0，P95 延迟正常。但 Loki 里有大量 ERROR 日志。

**现场包**：`docs/drills/cases/S9-*/`（`logs-loki.txt` 是关键）

**关键问题**：
- 为什么 HTTP 200 也会记 ERROR？
- 指标为什么完全看不出来？
- 如果只看仪表盘，你会漏掉什么？
- 什么样的告警能覆盖这种"静默降级"？

### 场景 10 · 日志突然查不到了，但服务一切正常

**你会看到**：服务正常、Pod 正常、指标正常、告警为空。
但 Loki 里最新日志的时间戳停在几分钟前，之后没有任何新日志。

**现场包**：`docs/drills/cases/S10-*/`（对比 `logs-loki.txt` 的采集时间与最新日志时间）

**关键问题**：
- "查不到日志"有几种可能？
- 怎么判断是"应用没打日志"还是"日志没送到"？
- 如果监控只依赖日志，会有什么后果？
- 应该怎么监控日志管道自身？

### 场景 11 · 节点再也无法维护了，但服务完全正常

**你会看到**：`kubectl get pods` 全 `1/1 Running`，指标正常，告警为 0。
但执行 `kubectl drain node` 会一直失败：

```text
error when evicting pods/"demo-api-xxx": Cannot evict pod as it would violate
the pod's disruption budget.
```

**现场包**：`docs/drills/cases/S11-*/`

**关键问题**：
- PDB 是什么？它保护的是"可用性"还是"可维护性"？
- `ALLOWED DISRUPTIONS` 为 0 意味着什么？
- 服务好好的，为什么不能下线节点？
- 这种"配置错误但无告警"的问题该怎么提前发现？

## 一个真实案例（S1 的完整现场）

这是实际注入场景 1 后采集的证据，作为"现场包长什么样"的示例：

```text
# summary.txt 里的事件摘要
29s   Normal   Pulled      Container image "ghcr.io/...:cce5412d..." already present on machine
29s   Normal   Created     Created container: demo-api
29s   Normal   Started     Started container demo-api
 9s   Warning  Unhealthy   Liveness probe failed: HTTP probe failed with statuscode: 404
 2s   Warning  Unhealthy   Readiness probe failed: HTTP probe failed with statuscode: 404
```

```text
# metrics.txt 里的交叉验证线索
kube_pod_container_status_restarts_total{pod=新Pod} = 1          ← 重启过一次
kube_pod_container_status_last_terminated_reason{...} = Completed ← 退出码 0，不是崩溃
rate(demo_http_requests_total{pod=新Pod}) = 0.04                  ← 几乎没有流量（老 Pod 是 0.36）
kube_deployment_status_replicas_available = 2                      ← Deployment 层看不出来异常
```

**注意最后一行**：只看 Deployment 的 `AVAILABLE` 会以为一切正常。
这是本场景最容易误判的地方——必须看到 Pod 粒度的 `READY`。

排查完对照 `docs/drills/answers.md` 的 S1。

## 设计约定

**为什么用 `apply` 恢复而不是 `rollout undo`**：
`undo` 只回退一步，连续注入多个场景后会回到某个也是坏的 revision；
且它回退整个 Pod template，历史 RS 里只有当前那个带完整 5 个 env，
落到旧 RS 上会把 `PROMETHEUS_MULTIPROC_DIR` 一起丢掉。实测踩过（SOP 第 9 课 9.3）。

**为什么注入用 `patch` 而不是改文件再 apply**：
`patch` 能精确制造单个字段的偏差，模拟"有人手滑改了一个参数"这种真实场景。
改文件再 apply 会把所有字段都重置，反而看不出差异。

**为什么答案单独放**：
自己排查出来的结论记得住，看答案记住的只有答案本身。

## 场景清单速查

| 编号 | 表现 | 对应 SOP 课 |
| --- | --- | --- |
| 1 | Running 但 NotReady | 第 5 课 |
| 2 | CrashLoopBackOff | 第 3 课 |
| 3 | OOMKilled 起不来 | 第 4 课 |
| 4 | Pending 不调度 | 第 4 课 |
| 5 | ImagePullBackOff | 第 2 课 |
| 6 | 就绪状态抖动 | 第 5 课 |
| 7 | 发布成功但功能缺失 | 第 9 课 |
| 8 | Service 访问不通 | 第 5 课 |
| 9 | **日志有 ERROR，指标全绿** | 第 7 课 + 附录 D |
| 10 | **日志断流，服务正常** | 第 6 课 + 附录 D |
| 11 | **PDB 阻塞节点维护** | 附录 E |

**1-8 练的是"指标和状态"，9-10 练的是"日志与指标不一致"，11 练的是"可用性配置"**。
后三个更接近真实故障——生产环境里最危险的情况往往是"看板全绿但目标没达成"。

## 日志维度现场包新增内容

`collect.sh` 现在会额外生成 `logs-loki.txt`，包含：

```text
各命名空间的日志量（近 15 分钟）
sre-lab 各 Pod 的日志量
ERROR/FATAL 日志行数（按 Pod）
最近 40 行原始日志
ERROR 日志样本
```

**关键判据**：把「采集时间」和「最新日志的时间戳」对比。
差值正常是几秒到十几秒；如果差了几分钟，说明日志管道断了（场景 10）。

排查场景 9 时看 `ERROR 行数` 和 `metrics.txt` 的对比：
日志有 ERROR、指标无异常 → 错误被应用吞掉了。
