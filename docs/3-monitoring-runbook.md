# 监控与故障演练手册

适用对象：本仓库 `sre-devops-lab` 的实验集群（master 172.31.6.211 / node 172.31.12.103）。

前置：`kubectl apply -f k8s/monitoring/` 已执行，`kubectl -n monitoring get pods` 全部 Running。

## 一、访问入口

```bash
# 三个 UI 都只监听 127.0.0.1，必须 port-forward，不要把 9090/3000/9093 暴露到公网
kubectl -n monitoring port-forward svc/prometheus   9090:9090
kubectl -n monitoring port-forward svc/alertmanager 9093:9093
kubectl -n monitoring port-forward svc/grafana      3000:3000
```

- Prometheus：<http://127.0.0.1:9090>（`/targets` 看抓取，`/alerts` 看规则状态，`/rules` 看规则内容）
- Alertmanager：<http://127.0.0.1:9093>
- Grafana：<http://127.0.0.1:3000>，账号 `admin`，口令见 Secret `monitoring/grafana-admin`
  （清单里是 `lab-grafana-change-me`，演示前用下面的命令覆盖）

```bash
kubectl -n monitoring create secret generic grafana-admin \
  --from-literal=GF_SECURITY_ADMIN_USER=admin \
  --from-literal=GF_SECURITY_ADMIN_PASSWORD='<新口令>' \
  --dry-run=client -o yaml | kubectl apply -f -
kubectl -n monitoring rollout restart deploy/grafana
```

看板已随 ConfigMap 自动挂载，路径 `SRE Lab / SRE Lab Overview`，13 个面板：
目标存活、请求速率、5xx 比例、P95、当前 firing 告警、状态码分布、延迟分位、
Pod 内存/CPU 与 request/limit 对比、节点内存、节点磁盘、副本数、重启次数。

## 二、抓取拓扑

| job | 发现方式 | 说明 |
| --- | --- | --- |
| `prometheus` | static | 自身 |
| `alertmanager` | static | 走 Service DNS |
| `demo-api` | `kubernetes_sd_configs: pod` + 注解 | 依赖 `prometheus.io/scrape=true`、`prometheus.io/port=8080`、`prometheus.io/path=/metrics`，注解在 `k8s/app.yaml` 的 Pod template 上 |
| `node-exporter` | `kubernetes_sd_configs: node` + relabel | 把 node 地址改写到 `:9100`，对应 DaemonSet 的 hostPort |
| `kube-state-metrics` | static | 走 Service DNS |

没有安装 Prometheus Operator，因此没有 ServiceMonitor / PodMonitor。取舍：少 3 个 CRD 和一组 controller，
代价是 relabel 规则要自己写；资源受限时这是更划算的选择。

## 三、告警规则清单

| 告警 | 表达式要点 | for | 严重度 |
| --- | --- | --- | --- |
| `TargetDown` | `up == 0` | 1m | critical |
| `DeploymentReplicasMismatch` | available < spec.replicas | 2m | critical |
| `PodNotReady` | phase ∈ Pending/Unknown/Failed | 2m | warning |
| `DemoApiHighErrorRate` | 5xx 占比 > 5% | 2m | critical |
| `DemoApiHighLatencyP95` | `histogram_quantile(0.95, ...)` > 1s | 3m | warning |
| `PodRestartTooOften` | 15m 内 `increase(restarts) > 3` | 1m | warning |
| `ContainerOOMKilled` | `last_terminated_reason{reason="OOMKilled"} == 1` | 1m | critical |
| `NodeMemoryPressure` | 内存使用 > 90% | 5m | warning |
| `NodeDiskPressure` | 磁盘使用 > 85% | 5m | warning |
| `NodeHighCPU` | CPU 使用 > 85% | 10m | info |

Alertmanager 侧：`severity=critical` 走 10s 的 `group_wait` 快通道，其余 30s。
实验环境没有 SMTP 和外网回调，receiver 是 `blackhole`，**以 Alertmanager UI 的 Firing 列表作为送达证据**。
接真实通道时把 `20-alertmanager.yaml` 里注释掉的 `webhook_configs` 打开即可。

## 四、演练流程（每次都要留 RCA）

统一模板：

```text
编号 / 时间
现象：用户或监控看到什么
证据：kubectl describe 的 Events、Pod 日志、Prometheus 指标截图路径
假设：最可能的原因，以及如何证伪
动作：执行的命令
验证：恢复的指标与时间
回滚点：如何退回上一步
```

### D1 Pod 自愈（无告警，验证控制器行为）

```bash
kubectl -n sre-lab get pods -o wide
kubectl -n sre-lab delete pod <pod-name>
kubectl -n sre-lab get pods -w
```

预期：ReplicaSet 立刻建新 Pod，Service Endpoint 短暂少一个，`up` 指标不出现长时间缺失。
观察点：Grafana「Deployment Available Replicas」不跌破 1。

### D2 ImagePullBackOff

```bash
kubectl -n sre-lab set image deploy/demo-api demo-api=ghcr.io/0tinna/sre-devops-lab:missing-tag
kubectl -n sre-lab get pods -w
kubectl -n sre-lab describe pod <new-pod>    # 关注 Failed to pull image / ErrImagePull
kubectl -n sre-lab rollout undo deploy/demo-api
kubectl -n sre-lab rollout status deploy/demo-api
```

预期告警：新 Pod 起不来 → 老 Pod 因 `maxUnavailable: 0` 仍在线，`up` 不掉；
如果反复重试超过阈值再看 `PodNotReady`。这条演练的价值在于证明 `maxUnavailable: 0` 真的挡住了坏发布。

### D3 CrashLoopBackOff

```bash
kubectl -n sre-lab patch deploy/demo-api --type=json \
  -p='[{"op":"add","path":"/spec/template/spec/containers/0/command","value":["/bin/false"]}]'
kubectl -n sre-lab get pods -w
kubectl -n sre-lab logs <pod> --previous
kubectl -n sre-lab rollout undo deploy/demo-api
```

预期告警：`PodRestartTooOften`（15 分钟内 > 3 次），严重度 warning。

### D4 Pending（调度失败）

```bash
kubectl -n sre-lab patch deploy/demo-api --type=json \
  -p='[{"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"8"}]'
kubectl -n sre-lab get pods
kubectl -n sre-lab describe pod <pending-pod>   # 关注 FailedScheduling / Insufficient cpu
kubectl -n sre-lab rollout undo deploy/demo-api
```

预期告警：`PodNotReady`（phase=Pending）与 `DeploymentReplicasMismatch`。
注意：`maxUnavailable: 0` 下新 Pod Pending 时老 Pod 不动，属于**发布卡住**而不是**服务中断**，RCA 要写清这个区别。

### D5 OOMKilled

需要新镜像（`/simulate/memory` 端点是本次新增的）。先把应用重新发布一次：

```bash
# 1. 发布带 /simulate/memory 的新镜像（见 docs/4-next-phase-plan.md P1 流程）
# 2. 临时压低内存 limit
kubectl -n sre-lab set resources deploy/demo-api --limits=memory=64Mi --requests=memory=64Mi
# 3. 触发分配
kubectl -n sre-lab port-forward svc/demo-api 8080:80
curl -i 'http://127.0.0.1:8080/simulate/memory?mib=256&hold=30'
# 4. 观察
kubectl -n sre-lab get pods -w
kubectl -n sre-lab describe pod <pod> | grep -A3 "Last State"
# 5. 恢复
kubectl -n sre-lab set resources deploy/demo-api --limits=memory=256Mi --requests=memory=128Mi
```

预期告警：`ContainerOOMKilled` + `PodRestartTooOften`。
`Last State: Terminated, Reason: OOMKilled, Exit Code: 137` 是标准证据。

### D6 慢请求与 P95 告警

```bash
kubectl -n sre-lab port-forward svc/demo-api 8080:80
for i in $(seq 1 30); do curl -s -o /dev/null 'http://127.0.0.1:8080/simulate/slow' & done; wait
```

预期告警：`DemoApiHighLatencyP95`（P95 > 1s，持续 3m）。
RCA 要写清：2s 的 sleep 会把 P95 直接顶到 2s 附近，直方图默认桶在 2.5s 处仍能分辨。

### D7 5xx 比例告警

```bash
kubectl -n sre-lab run loadgen --rm -i --restart=Never \
  --image=docker.m.daocloud.io/library/busybox:1.36 --command -- sh -c \
  'for i in $(seq 1 120); do wget -q -O /dev/null http://demo-api.sre-lab.svc.cluster.local/simulate/error; wget -q -O /dev/null http://demo-api.sre-lab.svc.cluster.local/healthz; done'
```

预期告警：`DemoApiHighErrorRate`（5xx 占比 = 50%，远超 5% 阈值，2m 后 Firing）。
恢复：停止注入后约 2m 自动 Resolved。

### D8 回滚演练

```bash
python3 scripts/opsctl.py deploy ghcr.io/0tinna/sre-devops-lab:missing-tag   # 期望非零退出
python3 scripts/opsctl.py rollback
python3 scripts/opsctl.py health
```

`opsctl.py deploy` 在 `rollout status` 超时时返回非零，这是设计行为：
把「发布失败」变成脚本可判定的信号，而不是靠人看输出。

## 五、清理

```bash
# 只删监控，保留业务
kubectl delete -f k8s/monitoring/

# 全清（演示结束、省内存）
kubectl delete namespace monitoring
kubectl delete -f k8s/app.yaml
kubectl delete -f k8s/namespace.yaml
```

`monitoring` 命名空间独立，删除它不会影响 `sre-lab` 的 demo-api。

## 六、已知限制

| 限制 | 后果 | 绕法 |
| --- | --- | --- |
| 没有 StorageClass，Prometheus / Grafana 用 emptyDir | Pod 重建后历史指标与 Grafana 手工改动丢失（看板来自 ConfigMap，不受影响） | 演练前用 `--storage.tsdb.retention.time=6h` 控制体积；长期化需要先补 local-path 或 NFS |
| 没有 metrics-server | `kubectl top` 不可用，HPA 无法工作 | 集群资源看 Grafana 的节点面板，或临时装 metrics-server |
| 镜像走 daocloud 代理 | 代理抖动会导致重新拉取失败 | 备用 `registry.cn-hangzhou.aliyuncs.com`；master 上已有镜像缓存，`imagePullPolicy: IfNotPresent` 时不受影响 |
| 工作节点仅 3.6 GiB | 监控栈不能放 node | 全部 `nodeSelector` 到 master |
| 单副本监控 | 监控自身无高可用 | 实验环境可接受；面试时要主动说明这是取舍 |
