# 面试表述与追问应对

本文件是 `sre-devops-lab` 项目的**对外表达版本**。文档 1–8 是过程记录，这一篇是结论。
所有数字都可以在文档 6（操作审计）、8（交接摘要）里找到出处。

## 一、30 秒版

> 我在 1 master + 1 worker 的 Kubernetes 实验集群上，把一个 Flask 服务从代码做到可部署、可观测、可回滚。
> CI 用 GitHub Actions 跑单测、构建镜像推 GHCR；部署用 Deployment + Service，配 readiness/liveness、
> 资源限制和非 root 安全上下文，`maxUnavailable: 0` 保证坏发布不中断服务。
> 监控侧没引 Operator，用 pod 注解做服务发现，12 个抓取目标、1344 个指标、20 条告警规则，
> **8 条真实触发验证过，其余 12 条如实标注未验证**——我用 `command: /bin/false` 造 CrashLoop，
> 看到告警进 Firing、Alertmanager 收到，修复后自动恢复。
> 还做了日志集中化、HPA 自动扩缩容和可用性加固，写了三个工具：
> 告警指标审计、镜像预热分发、11 个可注入的故障演练场景。
> 过程中定位了几个**不报错**的故障：探针端点写错导致 Pod 永远 NotReady、
> gunicorn 多 worker 计数器互相覆盖让 `rate()` 失真 3400 倍、
> Promtail 的 K8s 服务发现在 1.34 上静默失效、以及 3 条引用了不存在指标的"死告警"。

## 二、2 分钟版（可展开）

按「做了什么 → 怎么验证 → 踩了什么坑 → 学到了什么」四段讲。

**做了什么**
- 应用：Flask + gunicorn，`/healthz`、`/readyz`、`/metrics`、`/api/orders`，加五个受控故障端点。
- 镜像：多阶段 Dockerfile，非 root、数字 UID 10001、`seccompProfile: RuntimeDefault`、drop 全部 capability。
- CI：compile check + unittest + 构建推送 GHCR，tag 同时打 `latest` 和 commit SHA。
- CD：SSH 经跳板机到 master，`apply` 渲染清单 + 校验关键字段（不用 `set image`，见下）。
- 部署：Deployment 2 副本，`maxUnavailable: 0` + `maxSurge: 1` 滚动更新，
  三层探针 + `preStop` 优雅终止 + PDB + ResourceQuota + PriorityClass。
- 监控：Prometheus / Alertmanager / Grafana / node-exporter / kube-state-metrics /
  metrics-server / Loki / Fluent Bit，12 个抓取目标、20 条告警。
- 扩缩容：HPA 2-5 副本，CPU 70%，实测 30 秒 2→4、60 秒触顶。
- 运维 CLI：`opsctl.py` 提供 inventory / health / logs / deploy / rollback / monitoring；
  另有 `audit-alerts.py`（死告警审计）与 `prewarm-image.sh`（镜像分发）。

**怎么验证**
- 部署前：`py_compile`、`unittest`、`kubectl apply --dry-run=client`。
- 部署后：`rollout status`、Pod Events、日志、`/healthz`、`/readyz`、`/metrics`、Prometheus `/targets`。
- 告警：注入 5xx 流量看 `DemoApiHighErrorRate` 从 pending 到 firing，停止注入后自动 resolved。
- **告警审计**：脚本比对规则表达式引用的指标与 Prometheus 实际存在的指标，
  揪出"health=ok 但永远不会触发"的死告警。

**踩了什么坑**（这是最能体现能力的一段，展开讲）
1. `CreateContainerConfigError`——Events 里已经有 `Pulled`，说明不是拉取问题，根因是 `USER app` 非数字。
2. kube-state-metrics 永远 NotReady——探针端点分布在两个端口，`8081` 只有 `/readyz`。
3. 5xx 告警永不触发——计数器在 worker 间抖动，`rate()` 失真有 3400 倍误差。
4. Promtail 在 K8s 1.34 上 0 targets 且零报错——用 `static_configs` 做二分才确认是 discovery 的问题。
5. 3 条告警引用不存在的指标——YAML、promtool、`health=ok` 全部通过，但它们永远不会响。
6. `rollout undo` 只回退一步——连续两次坏发布会"回滚"到另一个坏版本。
7. drain 卡 4 分钟——PDB 数值上正确，但镜像没预热导致新副本起不来。

**学到了什么**
- 监控不是"装上去就行"，**没触发过的告警等于没有告警**。
- 指标错误比服务错误更危险，因为它不报错。
- **"配置全对"和"能工作"是两件事**——版本不兼容、指标不存在、阈值不合理，都不会报错。
- 修复时要问"为什么会发生"，而不只是"这次怎么改好"。

## 三、五个可深讲的故事

**故事 1–3 是"配置错误"，故事 4–5 是"配置全对但不工作"——后者更难，也更值钱。**

### 故事 1：为什么 `USER app` 会让容器起不来

**一句话**：`runAsNonRoot: true` 只认数字 UID，字符串 `app` 无法证明非 root。

**追问预判**

| 追问 | 回答 |
| --- | --- |
| 为什么 K8s 不去镜像里查 UID？ | 需要解析镜像文件系统，成本高且不可靠；fail-safe 地拒绝更安全 |
| 只改 Pod 的 `runAsUser` 行不行？ | 不干净。镜像元数据仍是字符串，不同运行时行为可能不一致，应同时改 Dockerfile |
| 怎么快速区分它和 ImagePullBackOff？ | 看 Events：有 `Pulled` 就是启动配置问题 |

### 故事 2：探针 404 导致 Pod 永远 NotReady

**一句话**：探针问错了端口，Pod 是 Running、应用完全正常，但没有 Endpoint。

**因果链**（要能一口气说出来）

```text
探针 404 → Pod NotReady → 不进 Service Endpoints → ClusterIP 访问 refused
```

**追问预判**

| 追问 | 回答 |
| --- | --- |
| 你怎么确认应用是好的？ | 用临时 busybox Pod 直连 Pod IP 逐端口探测，看到 `8080/healthz` 返回 200 |
| 为什么不用 port-forward？ | Service 无 Endpoint 时 port-forward 也会失败，分不清是应用挂了还是路由没建好 |
| readiness 和 liveness 为什么分开？ | readiness 失败只摘流量，liveness 失败会重启；混用会导致流量抖动或该重启的不重启 |

### 故事 3：告警永不触发——指标在撒谎

**这是最有含金量的一个**，因为它不报错。

**一句话**：gunicorn 2 个 worker 各持一份计数器，`/metrics` 只返回命中的那个，
Prometheus 看到伪 reset，`rate()` 失真。

**证据链**（要能复述数字）

```text
注入 720 次 500 后，5xx 比例只有 0.0006
query_range 显示计数器在跳：53536 → 66702 → 53542 → 66708
rate(/readyz[2m]) 算出 1366/s，真实探针速率 0.1/s
→ 误差 3400 倍
```

**怎么修的**（三处配合）
- `app.py`：`PROMETHEUS_MULTIPROC_DIR` 存在时用 `MultiProcessCollector` 聚合。
- `gunicorn.conf.py`：`child_exit` 调 `mark_process_dead` 清理 mmap。
- Deployment：提供 emptyDir，启动前清空残留文件。

**修复后验证**

```text
容器内计数器：3 → 6 → 9 → 12 → 15 → 18 → 21 → 24   （单调递增）
query_range drops：0/7                                （修复前 3/12）
rate(/readyz[2m])：0.400/s                            （探针 5s × 2 Pod，吻合）
告警：pending → firing → Alertmanager active → 自动 resolved
```

**追问预判**

| 追问 | 回答 |
| --- | --- |
| 怎么发现这个问题的？ | 告警配好但不触发，先查表达式，表达式没错，再查原始指标，用 `query_range` 看到计数器回退 |
| 为什么瞬时值看不出来？ | 随机落在高值那次采样上时完全正常，必须看序列连续性 |
| 单 worker 不就行了？ | 可以止血，但吞吐和抗阻塞下降。正确修复是 multiprocess 模式 |
| 还有哪些场景会遇到？ | uWSGI、celery 等多进程 Python 服务接入 Prometheus 时都会遇到 |

### 故事 4：所有配置都对，但工具就是不工作

**一句话**：Promtail 的 `kubernetes_sd_configs` 在 K8s v1.34.1 上静默失效——
0 targets、`/ready` 返回 500，但**日志里一条 error 都没有**。

**排查过程**（这一段能体现方法论）

```text
① 常规原因全部排除：
   - hostPath 挂载：容器内能 ls 到 /var/log/pods
   - 手工 glob：能匹配到 *.log 文件
   - RBAC：kubectl auth can-i list pods → yes
   - DNS：getent hosts kubernetes.default.svc → 10.96.0.1
   - API 连通：容器内 openssl 直连 → HTTP/1.1 200 OK + 完整 PodList

② 二分实验（决定性）：
   static_configs        → target=1，ready 200，tail 正常
   kubernetes_sd_configs → target=0，ready 500
   同一份二进制、同样挂载、同样权限，只有 discovery 方式不同

③ 换版本验证：2.9.4 和 3.5.0 都复现 → 不是版本 bug，是兼容性问题

④ 换实现：Fluent Bit 3.1.9，它的 tail input 不依赖 API 做文件发现
   → 启动日志直接给出判据：connectivity OK / local POD info OK / inotify_fs_add
```

**为什么这个故事值钱**

> **"没报错"不等于"没问题"。** 这类问题所有常规检查都能通过：
> 权限对、挂载对、网络通、配置语法合法、进程在跑。
> 唯一的判据是功能缺失本身。

**追问预判**

| 追问 | 回答 |
| --- | --- |
| 你怎么确定不是权限问题？ | 容器内直接用 SA token 手工发 HTTPS 请求，拿到 200 和完整 PodList |
| 为什么想到用二分？ | 配置全对但功能缺失时，读源码太慢；换一个变量做对比最快 |
| 换成 Fluent Bit 就一定有保障吗？ | 不一定，但它的文件发现不依赖 API，绕开了这个失效路径；同时用 `--check` 思路持续验证 |
| 生产上怎么防？ | 监控采集链路自身（`LogCollectorDown` + Loki 无写入告警），而不是假设它一定在跑 |

### 故事 5：三条永远不会响的告警

**一句话**：20 条告警里有 3 条引用了**不存在的指标**——YAML 语法合法、
`promtool check rules` 通过、`/api/v1/rules` 里 `health` 全是 `ok`，但它们永远不会触发。

**怎么发现的**

不是靠眼睛看，是写了个工具比对：

```text
① 从 /api/v1/rules 拉全部规则表达式
② 从 /api/v1/label/__name__/values 拉全部真实存在的指标名
③ 从表达式里抽 metric{ 形式的标识符（最可靠的指标引用）
④ 比对，报出引用了不存在指标的告警
```

**根因有两层**

| 层次 | 原因 |
| --- | --- |
| 显性 | 只有 7 个抓取目标，没有 cAdvisor，也没有 Loki 自身指标 |
| 隐性 | kube-state-metrics 的 `--resources` 是**白名单**，排除了 `horizontalpodautoscalers` 和 `poddisruptionbudgets` |

隐性那层最坑：两条 HPA 告警从写下的那一刻就是死的，而我以为它们在保护我。

**修复 + 结果**

```text
target     7 → 12（补 cAdvisor、kubelet、loki）
指标       744 → 1348
死告警     3 → 0
```

**追问预判**

| 追问 | 回答 |
| --- | --- |
| 为什么不直接看 `health`？ | `health` 只表示"表达式语法能解析"，不表示"引用的指标存在" |
| 告警不响你怎么知道？ | 不知道——这正是这类问题最危险的地方：**"没触发"和"不可能触发"长得一模一样** |
| 怎么防止再出现？ | 把审计脚本作为 CI 步骤，每次改规则都跑一遍 |
| 还有类似的坑吗？ | 有。`last_terminated_reason` 是持久状态，只写 `== 1` 会导致一次 OOM 后永久 firing |

## 四、设计取舍（面试官最爱问的）

| 问题 | 我的选择 | 理由 |
| --- | --- | --- |
| 为什么不用 Prometheus Operator？ | 用 pod 注解 + `kubernetes_sd_configs` | 省 3 个 CRD 和一组 controller，资源受限时更划算；代价是 relabel 自己写 |
| 监控组件为什么放 master？ | `nodeSelector` + control-plane toleration | 工作节点只有 3.6 GiB，装了会挤掉业务；master 15 GiB 只用了 1% |
| 为什么不用持久卷？ | emptyDir，Prometheus 保留 6h/1GB，Loki 24h | 集群没有 StorageClass；明确这是实验环境限制，不是设计缺陷 |
| 为什么镜像 tag 用 SHA？ | `latest` + commit SHA 双打 | SHA 保证可复现和可回滚，`latest` 只方便手工试 |
| CD 为什么走 SSH 而不上 runner？ | 自托管 runner 下载只有 21 KB/s，100MB 要 80 分钟 | SSH 经跳板机立即可用；代价是部署私钥要进 GitHub Secrets |
| 为什么用 Fluent Bit 而不是 Promtail？ | Promtail 的 SD 在 K8s 1.34 静默失效 | Fluent Bit 的 tail 不依赖 API 做文件发现；代价是元数据靠 filter 补 |
| 业务为什么能调度到控制面？ | control-plane toleration + 偏好 worker 的 nodeAffinity | 只有 1 个 worker，不加 toleration 就是单点；正常状态下仍优先 worker |
| `opsctl.py` 刻意没做什么？ | 没做自动扩缩容、没碰 kube-system | 工具边界要清楚，避免误操作面扩大 |

## 五、反问面试官（体现你在想什么）

1. 你们现在的告警有多少条是**真的触发过**的？平均 MTTA 多久？
2. 监控栈是自建还是托管？有没有遇到过指标静默失效的情况？
3. 发布流程里，回滚是人工决策还是自动？判定标准是什么？
4. 集群资源规划上，是宁可留余量还是尽量提高装箱率？
5. 团队怎么看"演练"这件事——是定期做，还是出事才复盘？

## 六、数据速查（面试时可以直接报数）

```text
集群      1 master(4C/15G) + 1 worker(2C/3.6G)，K8s v1.34.1，containerd 2.4.2
应用      demo-api 2 副本，非 root UID 10001，request 100m/128Mi，limit 500m/256Mi
扩缩容    HPA 2-5 副本，CPU 70%；实测扩容 30s→4 副本、60s→5 副本，缩容遵守 300s 稳定窗口
可用性    PDB minAvailable 1；drain 预热后 7 秒完成，未预热卡 4 分钟超时
监控      9 Pod（含 Loki、Fluent Bit），requests 490m/928Mi，limits 2400m/2112Mi
抓取      12 个 target，15 秒间隔；1344 个指标
告警      20 条 / 4 组（availability 4、reliability 6、capacity 6、autoscaling 4）
告警验证  8 条真实触发过（TargetDown、PodRestartTooOften、ContainerOOMKilled、
          DeploymentReplicasMismatch、DemoApiHighErrorRate、DemoApiHighLatencyP95、
          NodeHighCPU、ImagePullSlow）；12 条如实标注未验证
日志      Loki 2.9.4 + Fluent Bit 3.1.9，保留 24h，Grafana 双数据源 15 面板
镜像源    Docker Hub 不可达 / quay.io blob 超时 / 走 docker.m.daocloud.io
镜像分发  直连 ghcr.io >600s 未完成 vs 内网搬运 45MB/22s
关键误差  rate() 修复前 1366/s，修复后 0.400/s，差 3400 倍
演练      11 个可注入场景，每次采集 11 类现场证据
```

## 七、如果被问"你觉得自己最不足的地方"

诚实的答案比包装好：

> 这套环境的**可观测性已经覆盖指标和日志，但链路追踪完全没有**——
> 跨服务调用出了问题，我只能从日志时间戳去猜。
> 另外 20 条告警里还有 12 条没有经过真实触发验证，它们能不能响我并不能保证。
> 告警也只做到"能触发"，没有分级响应流程和值班机制，离生产级的 on-call 还有距离。
> 还有一个结构性短板：只有 1 个 worker 节点，业务的 2 个副本实际还在同一台机器上，
> 真正的跨节点容灾我并没有验证过，只是把 toleration 和拓扑分布配好了。

**这个回答的要点**：说的是"我知道自己的边界在哪"，不是"我什么都做得好"。
面试官问这个问题，想听的是判断力，不是谦虚。
