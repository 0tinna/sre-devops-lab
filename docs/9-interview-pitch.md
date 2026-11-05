# 面试表述与追问应对

本文件是 `sre-devops-lab` 项目的**对外表达版本**。文档 1–8 是过程记录，这一篇是结论。
所有数字都可以在文档 5（集群盘点）、6（操作审计）里找到出处。

## 一、30 秒版

> 我在 1 master + 1 worker 的 Kubernetes 实验集群上，把一个 Flask 服务从代码做到可部署、可观测、可回滚。
> CI 用 GitHub Actions 跑单测、构建镜像推 GHCR；部署用 Deployment + Service，配 readiness/liveness、
> 资源限制和非 root 安全上下文，`maxUnavailable: 0` 保证坏发布不中断服务。
> 监控侧没引 Operator，用 pod 注解做服务发现，10 条告警规则覆盖可用性、错误率、延迟、重启和容量，
> **并且真的触发过**——我用 `command: /bin/false` 造 CrashLoop，看到告警进 Firing、Alertmanager 收到，
> `rollout undo` 后自动恢复。
> 过程中定位了两个不报错的故障：探针端点写错导致 Pod 永远 NotReady，以及 gunicorn 多 worker
> 计数器互相覆盖导致 `rate()` 算出 1366 req/s 而真实值只有 0.4。

## 二、2 分钟版（可展开）

按「做了什么 → 怎么验证 → 踩了什么坑 → 学到了什么」四段讲。

**做了什么**
- 应用：Flask + gunicorn，`/healthz`、`/readyz`、`/metrics`、`/api/orders`，加三个受控故障端点。
- 镜像：多阶段 Dockerfile，非 root、数字 UID 10001、`seccompProfile: RuntimeDefault`、drop 全部 capability。
- CI：compile check + unittest + 构建推送 GHCR，tag 同时打 `latest` 和 commit SHA。
- 部署：Deployment 2 副本，`maxUnavailable: 0` + `maxSurge: 1` 滚动更新。
- 监控：Prometheus / Alertmanager / Grafana / node-exporter / kube-state-metrics，10 条告警。
- 运维 CLI：`opsctl.py` 提供 inventory / health / logs / deploy / rollback / monitoring。

**怎么验证**
- 部署前：`py_compile`、`unittest`、`kubectl apply --dry-run=client`。
- 部署后：`rollout status`、Pod Events、日志、`/healthz`、`/readyz`、`/metrics`、Prometheus `/targets`。
- 告警：注入 5xx 流量看 `DemoApiHighErrorRate` 从 pending 到 firing，停止注入后自动 resolved。

**踩了什么坑**（这是最能体现能力的一段，展开讲）
1. `CreateContainerConfigError`——Events 里已经有 `Pulled`，说明不是拉取问题，根因是 `USER app` 非数字。
2. kube-state-metrics 永远 NotReady——探针端点分布在两个端口，`8081` 只有 `/readyz`。
3. 5xx 告警永不触发——计数器在 worker 间抖动，`rate()` 失真有 3400 倍误差。

**学到了什么**
- 监控不是"装上去就行"，**没触发过的告警等于没有告警**。
- 指标错误比服务错误更危险，因为它不报错。
- 修复时要问"为什么会发生"，而不只是"这次怎么改好"。

## 三、三个可深讲的故事

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

## 四、设计取舍（面试官最爱问的）

| 问题 | 我的选择 | 理由 |
| --- | --- | --- |
| 为什么不用 Prometheus Operator？ | 用 pod 注解 + `kubernetes_sd_configs` | 省 3 个 CRD 和一组 controller，资源受限时更划算；代价是 relabel 自己写 |
| 监控组件为什么放 master？ | `nodeSelector` + control-plane toleration | 工作节点只有 3.6 GiB，装了会挤掉业务；master 15 GiB 只用了 1% |
| 为什么不用持久卷？ | emptyDir + `retention.time=6h` | 集群没有 StorageClass；明确这是实验环境限制，不是设计缺陷 |
| 为什么镜像 tag 用 SHA？ | `latest` + commit SHA 双打 | SHA 保证可复现和可回滚，`latest` 只方便手工试 |
| 为什么 CD 没做成全自动？ | 需要集群凭证，公网 runner 不应持有 | 备选是在 master 跑 self-hosted runner，属于下一阶段 |
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
监控      5 组件 6 Pod，requests 290m/608Mi，limits 1500m/1280Mi，全在 master
抓取      7 个 target，15 秒间隔，10 条规则，3 个规则组
镜像源    Docker Hub 不可达 / quay.io blob 超时 / 走 docker.m.daocloud.io
告警验证  TargetDown、PodRestartTooOften、DemoApiHighErrorRate 三条真实触发过
关键误差  rate() 修复前 1366/s，修复后 0.400/s，差 3400 倍
```

## 七、如果被问"你觉得自己最不足的地方"

诚实的答案比包装好：

> 这套环境的**可观测性只覆盖了指标**，日志还是 `kubectl logs` 手工看，没有集中收集和检索；
> 链路追踪完全没有。另外告警只做到"能触发"，没有分级响应流程和值班机制，
> 离生产级的 on-call 还有距离。这些是我下一步想补的。
