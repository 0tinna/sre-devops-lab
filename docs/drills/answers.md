# 演练答案与判据

**先排查完再看**。这里的价值不在结论，在于"你是怎么排除其他可能性的"。

每个场景给出：根因 → 判据链（怎么一步步证实的）→ 常见误判 → 修复 → 对应课。

---

## S1 · 探针路径指向不存在的端点

### 根因

`readinessProbe.httpGet.path` 和 `livenessProbe.httpGet.path` 被改成 `/health` 和 `/live`，
而应用只提供 `/healthz` 和 `/livez`。探针请求返回 404，Pod 永远不 Ready。

### 判据链（这是排查过程，不是结论）

```text
① summary.txt → 新 Pod 是 Running 但 0/1，Deployment 却显示 2/2 AVAILABLE
   → 排除调度问题（不是 Pending）、排除启动问题（不是 CrashLoop）
   → 指向"探针/就绪"这一类（SOP 第 5 课）

② describe.txt 的 Events →
   Readiness probe failed: HTTP probe failed with statuscode: 404
   → 应用在响应，但响应的路径不对

③ 关键：怎么确认应用本身是好的？
   Events 里有 Created/Started，没有 Crash → 进程活着
   metrics.txt 里 restarts=1 且有 last_terminated_reason=Completed（exit 0）
   → 那次重启是 liveness 404 被杀，不是应用崩溃

④ endpoints.txt → Endpoints 只有老的两个 IP，没有新 Pod 的 IP
   → 印证"未 Ready 就不进 Endpoints"这条因果链

⑤ deploy.json → readinessProbe.httpGet.path = /health（应为 /readyz）
```

### 常见误判

| 误判 | 为什么错 |
| --- | --- |
| "应用挂了" | 进程活着，`/healthz` 能手工访问成功 |
| "镜像有问题" | Events 里 `Pulled` 且 `Created/Started` 都正常 |
| "Deployment 不是 2/2 吗，没问题" | `AVAILABLE` 只统计老 Pod；新 Pod 卡在滚动里，`rollout status` 会超时 |
| "加个 replicas 就好了" | 副本数不解决探针配置错误 |

### 修复

```bash
kubectl -n sre-lab patch deploy demo-api --type=json -p='[
  {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/readyz"},
  {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/healthz"}
]'
# 或直接 ./scripts/drills/recover.sh
```

### 对应课

SOP 第 5 课「探针与就绪语义」。

---

## S2 · 环境变量非法导致容器无法启动

### 根因

`PORT` 环境变量被改成 `not-a-port`，gunicorn 执行 `bind = '0.0.0.0:not-a-port'` 时
抛异常退出，容器立即重启，形成 `CrashLoopBackOff`。

### 判据链

```text
① summary.txt → CrashLoopBackOff，RESTARTS 持续增长
   → 启动阶段问题（SOP 第 3 课）

② logs-current.txt → 可能是空的
   因为容器起来就跑挂了，日志还没来得及刷出来

③ logs-previous.txt → 这里有真正的原因
   gunicorn: error: invalid port number 'not-a-port'
   → 定位到 PORT 环境变量

④ deploy.json → env[0].value = "not-a-port"
```

### 关键点：为什么 current 日志可能是空的

`logs-current.txt` 取的是**当前这次**运行的日志。如果一个进程启动即崩、
还没写任何东西就退出，你看到的就是空。
`--previous` 才能拿到上一次（也就是崩溃那次）的完整输出。

**这是新手最常见的坑**：看到 current 是空的就以为"没有日志"，其实要看 previous。

### 常见误判

| 误判 | 为什么错 |
| --- | --- |
| "日志是空的，没法查" | 要看 `--previous`，或 `describe` 里的 `Last State` |
| "镜像坏了" | 同一个镜像在老 Pod 上跑得好好的 |
| "内存不够" | OOMKilled 的退出码是 137，这里是 1 或 2（应用主动退出） |

### 修复

```bash
kubectl -n sre-lab set env deploy/demo-api PORT=8080
# 或 ./scripts/drills/recover.sh
```

### 对应课

SOP 第 3 课「容器启动与安全上下文」+ 第 1 课的诊断命令速查（`--previous`）。

---

## S3 · 内存 limit 低于应用启动所需

### 根因

`limits.memory` 被压到 48Mi。Python + gunicorn 两个 worker 仅启动就要超过这个数，
容器在启动阶段被 cgroup OOM killer 杀掉。

### 判据链

```text
① summary.txt → CrashLoopBackOff 或 Error，RESTARTS 增长
② describe.txt → Last State:
     Reason: OOMKilled, Exit Code: 137
   → 内存被杀（SOP 第 4 课）

③ 关键判断：是"泄漏"还是"limit 太小"？
   - 容器还没处理请求就被杀 → limit 太小
   - 运行一段时间后内存持续爬升被杀 → 泄漏
   看 metrics.txt:
     kube_pod_container_status_restarts_total 快速递增
     last_terminated_reason = OOMKilled
   restarts 在十几秒内就 >2，说明是启动阶段死的

④ deploy.json → limits.memory = 48Mi
```

### 依赖时长怎么判断

| 现象 | 结论 |
| --- | --- |
| 启动几秒就 OOMKilled，日志还没有请求记录 | limit 太小，连启动都不够 |
| 跑几分钟到几小时才 OOMKilled，内存单调上升 | 泄漏 |
| OOMKilled 但内存曲线是平的 | 可能是 RSS 峰值瞬时冲高，看 limit 余量 |

### 常见误判

| 误判 | 为什么错 |
| --- | --- |
| "内存泄漏了" | 启动阶段就死，根本没有运行期 |
| "加个 restartPolicy 就好" | 重启解决不了 limit 不足 |
| "退出码 137 就是 SIGKILL，一定是 K8s 杀的" | 137 = 128+9，OOM killer 发的就是 SIGKILL；要结合 `reason` 看 |

### 修复

恢复合理的 request/limit。本项目实测 128Mi/256Mi 对 gunicorn 2worker 是够的。

### 对应课

SOP 第 4 课「调度与容量规划」中的资源约束部分。

---

## S4 · 资源 requests 超过节点可分配量

### 根因

`requests.cpu` 和 `limits.cpu` 同时被改成 `6`。master 只有 4 CPU 且带
`NoSchedule` taint，node 只有 2 CPU 且已被占用一部分，两个节点都无法满足。

### 判据链

```text
① summary.txt → Pod 状态 Pending，NODE 列是 <none>
   → 调度阶段问题，根本没到节点上（SOP 第 4 课）

② describe.txt → Events:
   FailedScheduling: 0/2 nodes are available:
     1 Insufficient cpu,
     1 node(s) had untolerated taint {node-role.kubernetes.io/control-plane:}
   → 这句话同时告诉你两个节点的原因，要分别读

③ 为什么没有日志？因为容器从未启动。Pending 的 Pod 没有日志是正常的。

④ deploy.json → requests.cpu = 6 > 节点 allocatable
```

### 关键读法

```text
0/2 nodes are available:
  1 Insufficient cpu                                       ← node 资源不够
  1 node(s) had untolerated taint {...control-plane}        ← master 被 taint 挡住
```

**两个原因不能混为一谈**：前者要降低 request，后者要加 toleration（如果确实要上 master）。

### 常见误判

| 误判 | 为什么错 |
| --- | --- |
| "节点挂了" | 两个节点都是 Ready |
| "去查日志" | Pending 阶段没有容器，没有日志 |
| "加 toleration 就行" | node 那边是资源不足，加 toleration 只解决 master 那一半 |
| "requests 不能大于 limits 吧" | 对，所以注入时两个一起调——只调 requests 会被 API 直接拒绝 |

### 修复

恢复 request/limit，或把 request 降到节点能容纳的范围。

### 对应课

SOP 第 4 课「调度与容量规划」。

---

## S5 · 镜像 tag 指向不存在的版本

### 根因

`image` 被改成 `ghcr.io/0tinna/sre-devops-lab:v1.0.0-rc1`，这个 tag 从未构建过。

### 判据链

```text
① summary.txt → ImagePullBackOff 或 ErrImagePull
   → 镜像阶段问题（SOP 第 2 课）

② describe.txt → Events:
   Failed to pull image "...:v1.0.0-rc1": not found
   → 关键词 "not found" = 标签/仓库问题，不是网络问题

③ 用 crictl 直接验证，排除 Deployment 干扰：
   crictl pull ghcr.io/0tinna/sre-devops-lab:v1.0.0-rc1

④ 关键：老 Pod 还在服务吗？
   summary.txt → Deployment 2/2 AVAILABLE
   → maxUnavailable: 0 让坏发布不中断服务

⑤ 验证服务可用：
   kubectl get --raw "/api/v1/namespaces/sre-lab/services/demo-api:80/proxy/healthz"
   → {"status":"ok"}
```

### 这个场景最重要的观察

**服务没有中断**。这是 `maxUnavailable: 0` + `maxSurge: 1` 的直接效果：
新 Pod 起不来，老 Pod 就不撤。

面试时这是很好的素材：**坏发布不等于事故，取决于滚动策略**。

### 常见误判

| 误判 | 为什么错 |
| --- | --- |
| "网络不通拉不下来" | `not found` 是仓库说"没这个 tag"，不是连不上 |
| "服务挂了快回滚" | 先确认服务是否真的受影响（本例没有） |
| "回滚一下就完事" | `rollout undo` 只回退一步，连续坏发布会失效（见 S7） |

### 修复

```bash
kubectl -n sre-lab set image deploy/demo-api demo-api=ghcr.io/0tinna/sre-devops-lab:<正确SHA>
# 或 ./scripts/drills/recover.sh
```

### 对应课

SOP 第 2 课「镜像供应链」。

---

## S6 · readiness 参数过严导致状态抖动

### 根因

`readinessProbe` 被改成：

```yaml
timeoutSeconds: 1
periodSeconds: 1
failureThreshold: 1
initialDelaySeconds: 0
```

每秒探测一次、1 秒超时、失败一次立刻标记 NotReady。任何轻微的 GC 停顿或
请求排队都会让探针超时，Pod 在 Ready/NotReady 之间来回跳。

### 判据链

```text
① summary.txt → Pod 状态在 1/1 和 0/1 之间变化
   → 不是稳定失败，是抖动

② describe.txt → Events 里 Unhealthy 的间隔非常短（几秒一次）
   对比正常配置应该是 periodSeconds=10

③ deploy.json → 探针参数被改小

④ endpoints.txt 多次采集会看到 Endpoint 列表变化
```

### 抖动比稳定失败更危险

| 表现 | 影响 |
| --- | --- |
| 稳定 NotReady | 该 Pod 被摘除，其他 Pod 承担流量，影响可控 |
| Ready/NotReady 抖动 | 流量反复涌入又切断，上游看到间歇性 5xx/超时，且**很难定位** |

这是"探针配得太敏感"的典型后果，而不是"探针没用"。

### 参数各自的作用

| 参数 | 作用 | 设太小会怎样 |
| --- | --- | --- |
| `periodSeconds` | 探测间隔 | 太频繁，浪费资源且放大抖动 |
| `timeoutSeconds` | 单次超时 | 正常慢请求被误判失败 |
| `failureThreshold` | 连续失败几次才判定 | 一次抖动就摘流量 |
| `successThreshold` | 连续成功几次才恢复 | 恢复太快，可能反复 |
| `initialDelaySeconds` | 启动后等多久开始探 | 应用没起来就探，必然失败 |

### 修复

恢复成项目基线：`periodSeconds: 5`、`timeoutSeconds: 默认1`、`failureThreshold: 3`。

### 对应课

SOP 第 5 课「探针与就绪语义」。

---

## S7 · 发布"成功"但配置丢了

### 根因

用 `set image` 发布，而 Deployment 的模板里有更早版本遗留的配置差异。
`set image` **只改镜像字段**，不会同步 env / volume / probe。

更隐蔽的是：`rollout status` 会成功，Pod 全 Ready，但用的不是你以为的那份配置。

### 判据链

```text
① summary.txt → 一切正常，Pod 全 1/1 Running
   → 从"状态"看不出来任何问题

② 这一步必须跳出状态表，去对比配置：
   kubectl -n sre-lab get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'
   → 期望 5 个 env，实际可能只有 PORT

③ rs.txt 是关键 —— 它列出所有历史 ReplicaSet 的配置：
   会发现只有某一个 RS 带完整 5 个 env，其余都只有 PORT
   → 证明"当前生效的模板"与"你以为的模板"不一致

④ 功能层面验证：
   kubectl -n sre-lab exec <pod> -- python3 -c "import urllib.request; ..."
   访问 /simulate/memory → 404 说明 ENABLE_FAULT_ENDPOINTS 没生效
```

### 为什么这是最难的场景

**没有任何错误信号**：Pod 正常、健康检查通过、日志无异常、指标正常。
只有对比**期望配置**和**实际配置**才能发现。

这类问题在生产里会表现为"新功能上线了但不起作用"，排查成本极高。

### 判据口诀

> `rollout status` 成功只能证明"Pod 起来了"，不能证明"Pod 用的是你以为的配置"。

**每次发布后抽查关键字段**，这是唯一可靠的防线。

### 修复

```bash
# 用 apply，不用 set image
sed "s|:latest|:<SHA>|" k8s/app.yaml > /tmp/app-render.yaml
kubectl apply -f /tmp/app-render.yaml
# 然后立刻抽查
kubectl -n sre-lab get deploy demo-api -o jsonpath='{.spec.template.spec.containers[0].env[*].name}'
```

### 对应课

SOP 第 9 课 9.2「`set image` 不会应用 env 和 volume」。

---

## S8 · Service selector 与 Pod 标签不匹配

### 根因

Service 的 `spec.selector` 被改成 `app.kubernetes.io/name: demo-api-v2`，
而 Pod 的标签仍是 `app.kubernetes.io/name: demo-api`。selector 匹配不到任何 Pod，
Endpoints 为空。

### 判据链

```text
① summary.txt → Pod 全 1/1 Running，但访问服务不通
   → 排除应用问题，指向路由（SOP 第 5 课的因果链）

② endpoints.txt →
   Endpoints: <none>  或完全没有该 Service 的条目
   → Service 找不到后端

③ 对比两边的标签：
   Service selector:  app.kubernetes.io/name=demo-api-v2
   Pod labels:        app.kubernetes.io/name=demo-api
   → 不匹配

④ 直接访问 Pod IP 验证应用正常：
   kubectl get --raw "/api/v1/namespaces/sre-lab/pods/<pod>:8080/proxy/healthz"
   → 200，说明应用没问题，是路由问题
```

### 因果链（第 5 课的核心）

```text
selector 不匹配 → Endpoints 为空 → ClusterIP 无后端 → 访问 refused/超时
```

注意这跟"探针失败"是**两条不同的路径**，但最终都表现为"服务访问不通"：

| 原因 | Pod READY | Endpoints | 应用本身 |
| --- | --- | --- | --- |
| 探针失败（S1） | 0/1 | 缺该 Pod | 正常 |
| selector 错（S8） | 1/1 | 完全为空 | 正常 |

**用 Pod 的 READY 状态就能区分这两类**，这是排查捷径。

### 修复

```bash
kubectl -n sre-lab patch svc demo-api --type=merge \
  -p='{"spec":{"selector":{"app.kubernetes.io/name":"demo-api"}}}'
```

### 对应课

SOP 第 5 课「探针与就绪语义」中的因果链部分。

---

## S9 · 日志有 ERROR，但指标全绿

### 根因

`/simulate/degraded` 模拟下游依赖超时：异常被 `try/except` 捕获，
应用降级返回缓存数据，**HTTP 状态码 200**，但日志里记 `ERROR`。

这是"静默降级"——用户拿到的是过期数据，但所有技术指标都显示正常。

### 判据链

```text
① summary.txt / describe.txt → Pod 全 1/1 Running，无重启，无 Events 异常
   → 排除调度、启动、探针问题

② metrics.txt →
   ALERTS{alertstate="firing"} = (无数据)      ← 没有任何告警
   sum by (pod) (rate(demo_http_requests_total[5m])) → 只有 200，没有 5xx
   histogram_quantile(0.95, ...) = 0.00475      ← P95 只有 4.7ms，极快
   → 从指标看，一切完美

③ logs-loki.txt 是关键转折点 →
   各 Pod 的 ERROR 行数: demo-api-xxx = 21, demo-api-yyy = 19
   ERROR 样本: "downstream call failed, serving stale cache:
                inventory-service did not respond within 2.4s"
   → 日志里明确写了"降级返回"

④ 对照最近日志：
   "GET /simulate/degraded HTTP/1.1" 200 144
   紧邻的上一行是 ERROR
   → 每个 200 响应的背后都有一次失败的下游调用
```

### 为什么指标完全看不出来

| 维度 | 该场景下的表现 | 原因 |
| --- | --- | --- |
| HTTP 状态码 | 200 | 应用决定降级而不报错 |
| 5xx 比例 | 0 | 没有 5xx |
| P95 延迟 | 4.7ms（更快了） | 走缓存，比正常查库还快 |
| 请求速率 | 正常 | 流量没有变化 |
| Pod 重启 | 0 | 容器健康 |

**这是最危险的故障类型**：所有 SLO 指标都好看，但业务已经错了。

### 常见误判

| 误判 | 为什么错 |
| --- | --- |
| "指标全绿说明没问题" | 指标只反映"请求有没有成功返回"，不反映"返回的内容对不对" |
| "延迟还降低了，是不是优化了" | 降级走缓存，当然更快——**变快可能是变坏的信号** |
| "没告警就不用管" | 告警是基于指标的，指标没覆盖到的故障自然不告警 |
| 只看 `kubectl get pods` | 状态正常不代表业务正常 |

### 修复与预防

**这类问题不可能靠"修复"解决，只能靠"发现"**：

1. **日志告警**：基于 Loki 的 `count_over_time({...} |~ "ERROR" [5m])` 建告警
2. **业务指标**：加一个 `demo_degraded_responses_total` 计数器，让降级行为可被度量
3. **契约测试**：响应里带 `source=stale-cache` 时，上游应该能识别
4. **SLO 定义**：把"返回新鲜数据"纳入 SLI，而不只是"返回 200"

本项目的改进方向（可作为后续任务）：

```python
# 在 /simulate/degraded 里加计数器
DEGRADED_COUNT = Counter('demo_degraded_responses_total', 'Responses served from stale cache')
DEGRADED_COUNT.inc()
# 然后加告警：rate(demo_degraded_responses_total[5m]) > 0
```

### 对应课

SOP 第 7 课「告警表达式设计」+ 附录 D。

**核心教训**：**指标的覆盖面决定了监控的天花板**。
没有对应的指标，再多的告警规则也看不见这类故障。

---

## S10 · 日志采集静默中断

### 根因

给 Fluent Bit 的 DaemonSet 加了不匹配的 `nodeSelector`（`drill-disabled: "true"`），
两个节点上的采集器 Pod 都被驱逐。**日志不再上报到 Loki，但服务完全不受影响。**

### 判据链

```text
① summary.txt → 集群、服务、Pod 全部正常
   demo-api 2/2 Running，无重启，无 Events 异常

② metrics.txt →
   sum(up) = 7          ← Prometheus 抓取正常
   ALERTS = (无数据)     ← 没有告警
   → 指标维度完全健康

③ logs-loki.txt 的对比是关键 →
   采集时间:     2026-11-05 17:04:23
   最新日志时间: 2026-11-05T17:00:17
   → 差了 4 分钟。正常情况下应该是几秒到十几秒

④ 继续看 logs-loki.txt →
   各命名空间日志量: monitoring = 87, sre-lab = 633
   这些是"存量"，不是新增
   → 日志管道已经断了

⑤ 去查采集器本身 →
   kubectl -n monitoring get pods -l app.kubernetes.io/name=fluent-bit
   → No resources found
   kubectl -n monitoring get ds fluent-bit -o jsonpath='{.spec.template.spec.nodeSelector}'
   → {"drill-disabled":"true"}   ← 找到了
```

### 关键判据：时间差

**这是排查"日志断了"唯一可靠的量化判据**：

```text
采集时间 - 最新日志时间戳 = ?
  几秒 ~ 几十秒  → 正常
  几分钟以上     → 管道断了（或应用真的不打日志了）
```

只看"日志量 633 行"会以为没问题，但那可能是几十分钟前积累的存量。

### 三种"查不到日志"的区分

| 情况 | Pod 状态 | Loki 有历史 | 时间差 | 结论 |
| --- | --- | --- | --- | --- |
| 应用没打日志 | 正常 | 有 | 大 | 应用问题，看代码 |
| 采集器挂了 | 正常 | 有 | 大 | **本场景** |
| Loki 挂了 | 正常 | 无/查询失败 | — | 存储问题 |

**区分方法**：看采集器 Pod 是否存在，再看 Loki 自身 `/ready`。

### 常见误判

| 误判 | 为什么错 |
| --- | --- |
| "日志量还有 633 行，说明正常" | 那是存量。要看**最新一条的时间** |
| "服务正常，日志不重要" | 出故障时你就是瞎的——这次能查，下次真出事查不了 |
| "查不到日志就是应用没打" | 先确认采集链路活着，再怀疑应用 |
| 只看 Prometheus 的 `up` | `up` 只反映抓取目标，不反映日志管道 |

### 修复

```bash
# 清除错误的 nodeSelector（注意：apply 是 merge，不会删字段，必须显式置空）
kubectl -n monitoring patch ds fluent-bit --type=merge \
  -p='{"spec":{"template":{"spec":{"nodeSelector":null}}}}'
kubectl apply -f k8s/monitoring/75-fluent-bit.yaml
# 或直接 ./scripts/drills/recover.sh
```

### 预防：监控日志管道自身

这是本场景最重要的收获——**日志管道也要被监控**：

```promql
# 1. 采集器是否在线（DaemonSet 期望 vs 就绪）
kube_daemonset_status_number_ready{daemonset="fluent-bit"}
  < kube_daemonset_status_desired_number_scheduled{daemonset="fluent-bit"}

# 2. Loki 是否还在收数据（日志速率骤降为 0）
sum(rate({namespace="sre-lab"}[5m])) == 0
```

本项目的告警规则里**还没有这两条**，这是一个已知缺口，
建议加到 `k8s/monitoring/10-prometheus.yaml` 的容量组：

```yaml
- alert: LogPipelineStalled
  expr: |
    sum(rate({namespace=~".+"}[10m])) == 0
  for: 10m
  labels:
    severity: critical
  annotations:
    summary: '日志管道可能已中断'
    description: '近 10 分钟没有收到任何日志，检查 Fluent Bit 与 Loki'
```

注意：这条规则属于 Loki 数据源，需要放在 Loki 的 ruler 里，
或者用 Prometheus 的 `kube_daemonset_status_number_ready` 间接监控。

### 对应课

SOP 第 6 课「指标正确性」+ 附录 D。

**核心教训**：**监控系统本身也需要被监控**。
如果日志是排障的主要手段，那"日志管道挂了"就是一级故障——
只是它不会自己喊出来。

---

## S11 · PDB 阻塞节点维护

### 根因

`PodDisruptionBudget` 的 `minAvailable` 被改成了 `2`，与副本数相等。
这意味着"任何时刻都必须有 2 个可用副本"，而总共只有 2 个——
所以**任何自愿驱逐都会被拒绝**，`ALLOWED DISRUPTIONS` 恒为 0。

### 判据链

```text
① summary.txt → 一切正常
   demo-api 2/2 Running，无重启，无 Events 异常
   指标正常，告警 0 条

② 执行维护动作才暴露问题
   kubectl drain node --ignore-daemonsets --delete-emptydir-data
   → error when evicting pods/"demo-api-xxx":
     Cannot evict pod as it would violate the pod's disruption budget.

③ 看 PDB 本身
   kubectl -n sre-lab get pdb demo-api
   NAME       MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS
   demo-api   2               N/A               0        ← 关键
   
   ALLOWED DISRUPTIONS = 0 表示"一个都不许动"

④ 对比副本数
   kubectl -n sre-lab get deploy demo-api → replicas: 2
   minAvailable(2) == replicas(2) → 死锁
```

### 关键概念：PDB 保护的是"可维护性"，不是"可用性"

这是最容易搞反的一点：

| 你以为 | 实际 |
| --- | --- |
| PDB 让服务更可用 | PDB 限制**你能做多少破坏性操作** |
| minAvailable 越大越安全 | minAvailable 越大越难维护，等于 副本数时完全不能维护 |
| 没有 PDB 就危险 | 没有 PDB 可以随意驱逐，但也没有保护 |

**PDB 是一把刹车，不是发动机。** 它不产生可用性，只约束中断。

### `ALLOWED DISRUPTIONS` 的含义

```text
ALLOWED DISRUPTIONS = (当前健康副本数) - minAvailable

2 副本 + minAvailable 1 → 允许 1 个被驱逐
2 副本 + minAvailable 2 → 允许 0 个，永远卡住
3 副本 + minAvailable 2 → 允许 1 个
```

### 常见误判

| 误判 | 为什么错 |
| --- | --- |
| "服务是好的，所以没问题" | 服务好≠可维护。这次故障只有在你做维护时才暴露 |
| "PDB 设严一点更安全" | 设成等于副本数就等于禁止一切维护，包括紧急修复 |
| "删掉 PDB 就好了" | 删掉后 drain 能过，但也失去了滚动发布时的保护 |
| "等业务低峰再维护" | 低峰也是同样的 PDB 约束，跟时间无关 |

### 修复

```bash
# 把 minAvailable 调回 1（2 副本时允许 1 个被驱逐）
kubectl -n sre-lab patch pdb demo-api --type=merge \
  -p='{"spec":{"minAvailable":1}}'
# 或直接 apply 正确清单
kubectl apply -f k8s/availability.yaml
# 或 ./scripts/drills/recover.sh
```

### 预防：正确选型

| 副本数 | 推荐配置 | 理由 |
| --- | --- | --- |
| 2 | `minAvailable: 1` | 允许 1 个被驱逐，滚动维护可行 |
| 2 | `maxUnavailable: 1` | 语义等价，但意图更清楚 |
| 3+ | `minAvailable: 2` | 容忍 1 个故障，同时保留冗余 |
| 1 | 不建议设 PDB | 设了就无法维护，等于自锁 |

**经验法则**：`minAvailable` 必须**严格小于**副本数，否则等于禁止维护。

### 怎么提前发现

这类问题不会自己报警，只能主动检查：

```promql
# PDB 的 allowed disruptions 为 0 超过一段时间 = 维护能力已丧失
kube_poddisruptionbudget_status_expected_pods{namespace="sre-lab"}
  - kube_poddisruptionbudget_status_current_healthy{namespace="sre-lab"}
  <= 0
```

建议加成告警（本项目尚未实现）：

```yaml
- alert: PDBBlocksMaintenance
  expr: |
    kube_poddisruptionbudget_status_desired_healthy{namespace="sre-lab"}
      - kube_poddisruptionbudget_status_current_healthy{namespace="sre-lab"} <= 0
  for: 30m
  labels:
    severity: warning
  annotations:
    summary: 'PDB {{ $labels.poddisruptionbudget }} 不允许任何中断'
    description: 'ALLOWED DISRUPTIONS 为 0，节点维护与滚动升级都会被阻塞。'
```

### 对应课

SOP 附录 E「可用性配置的正确失败」。

**核心教训**：**一个只影响"未来操作"的配置错误，不会体现在任何实时指标上**。
它安静地躺着，直到你真正需要维护的那一天。

---

## 判据速查表

| 现象 | 最先查 | 关键判据 |
| --- | --- | --- |
| Pending | `describe` 的 FailedScheduling | 是资源不足还是 taint |
| ImagePullBackOff | Events 的错误原文 | `not found` vs `timeout` vs `unauthorized` |
| CrashLoopBackOff | `logs --previous` | 退出码 + 最后几行 |
| Running 但 0/1 | Events 的探针结果 | 404 / timeout / connection refused |
| 全部正常但访问不通 | Endpoints | 空 = selector/标签问题 |
| 全部正常但功能缺失 | `jsonpath` 对比期望配置 | env / volume / probe 是否被丢 |
| 状态抖动 | 探针参数 | period / timeout / failureThreshold |
| **指标全绿但日志有 ERROR** | `logs-loki.txt` 的 ERROR 行数 | 错误被应用吞掉，状态码仍是 200 |
| **日志查不到** | 采集时间 vs 最新日志时间戳 | 差值 > 几分钟 = 管道断了 |
| **采集器是否存在** | `get pods -l app.kubernetes.io/name=fluent-bit` | 空 = 被驱逐或配置错误 |
| **drain/evict 被拒** | `get pdb` 的 ALLOWED DISRUPTIONS | 0 = minAvailable 设得太严 |
| **维护操作卡住** | `describe pod` 的 Events | `Pulling image` = 镜像分发热点 |

## 通用原则

1. **先定层次，再定细节。** Pod 状态本身就把可能性砍掉一大半。
2. **Events 优先于日志。** 日志是应用自己说的，Events 是 kubelet 说的。
3. **`--previous` 不能忘。** 崩溃前的日志才是原因。
4. **对比优于猜测。** 期望配置 vs 实际配置，Pod 标签 vs Service selector。
5. **Penging/未启动的 Pod 没有日志。** 这不代表"没线索"，线索在 Events。
6. **抖动比失败更难查。** 多采集几次，看变化而不是看单点。
