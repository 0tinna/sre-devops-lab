#!/usr/bin/env bash
# 采集故障现场证据。生成一个时间戳目录，里面是可以离线分析的全部材料。
#
# 用法：
#   ./scripts/drills/collect.sh <场景编号> [--label 名称]
#
# 产出目录：docs/drills/cases/<场景编号>-<时间戳>/
#   summary.txt       现象速览（不给结论）
#   pods.txt          Pod 列表与状态
#   describe.txt      每个 Pod 的完整 describe（含 Events）
#   logs-current.txt  当前容器日志
#   logs-previous.txt 崩溃前日志（有重启记录时）
#   events.txt        命名空间事件（按时间排序）
#   endpoints.txt     Service 与 Endpoint（排查路由问题）
#   deploy.json       Deployment 完整定义（排查配置问题）
#   rs.txt            历史 ReplicaSet 的配置对比（排查"回退后仍异常"）
#   metrics.txt       相关 Prometheus 指标快照
#   rollout.txt       rollout 状态与历史
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="sre-lab"
DEPLOY="demo-api"
SCENARIO="${1:?用法: collect.sh <场景编号> [--label 名称]}"
LABEL=""
shift || true
while [ $# -gt 0 ]; do
  case "$1" in
    --label) LABEL="$2"; shift 2 ;;
    *) shift ;;
  esac
done

STAMP="$(date '+%Y%m%dT%H%M%S')"
NAME="S${SCENARIO}-${STAMP}${LABEL:+-$LABEL}"
OUT="$REPO_ROOT/docs/drills/cases/$NAME"
mkdir -p "$OUT"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROM_PARSER="$SCRIPT_DIR/parse_prom.py"

say() { printf '%s\n' "$*" | tee -a "$OUT/_progress.txt" >/dev/null; }
echo "采集场景 $SCENARIO 现场 -> $OUT"

# ── 1. 现象速览 ────────────────────────────────────────
{
  echo "场景编号：$SCENARIO"
  echo "采集时间：$(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "命名空间：$NS"
  echo "Deployment：$DEPLOY"
  echo
  echo "=== 集群基础 ==="
  kubectl get nodes -o wide 2>&1
  echo
  echo "=== 工作负载状态 ==="
  kubectl -n "$NS" get deploy,pods,svc,endpoints 2>&1
  echo
  echo "=== 最近 5 条事件摘要（只列 Reason，不含分析）==="
  kubectl -n "$NS" get events --sort-by=.lastTimestamp 2>&1 | tail -6
} > "$OUT/summary.txt" 2>&1
say "summary.txt"

# ── 2. Pod 详情 ────────────────────────────────────────
kubectl -n "$NS" get pods -o wide > "$OUT/pods.txt" 2>&1
say "pods.txt"

{
  for pod in $(kubectl -n "$NS" get pods -o name 2>/dev/null); do
    echo "############ $pod ############"
    kubectl -n "$NS" describe "$pod" 2>&1
    echo
  done
} > "$OUT/describe.txt" 2>&1
say "describe.txt"

# ── 3. 日志 ────────────────────────────────────────────
{
  for pod in $(kubectl -n "$NS" get pods -o name 2>/dev/null); do
    echo "############ $pod 当前日志 ############"
    kubectl -n "$NS" logs "$pod" --tail=100 --all-containers=true 2>&1 || true
    echo
  done
} > "$OUT/logs-current.txt" 2>&1
say "logs-current.txt"

{
  for pod in $(kubectl -n "$NS" get pods -o name 2>/dev/null); do
    echo "############ $pod 上一次容器日志 ############"
    kubectl -n "$NS" logs "$pod" --previous --tail=100 --all-containers=true 2>&1 || echo "(无 previous 日志)"
    echo
  done
} > "$OUT/logs-previous.txt" 2>&1
say "logs-previous.txt"

# ── 4. 事件与路由 ──────────────────────────────────────
kubectl -n "$NS" get events --sort-by=.lastTimestamp > "$OUT/events.txt" 2>&1
say "events.txt"

{
  echo "=== Service ==="
  kubectl -n "$NS" get svc "$DEPLOY" -o yaml 2>&1
  echo
  echo "=== Endpoints ==="
  kubectl -n "$NS" get endpoints "$DEPLOY" -o yaml 2>&1
  echo
  echo "=== Pod 标签（对照 Service selector）==="
  kubectl -n "$NS" get pods --show-labels 2>&1
} > "$OUT/endpoints.txt" 2>&1
say "endpoints.txt"

# ── 5. 配置与历史 ──────────────────────────────────────
kubectl -n "$NS" get deploy "$DEPLOY" -o yaml > "$OUT/deploy.json" 2>&1
say "deploy.json"

{
  echo "=== rollout 状态 ==="
  kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=5s 2>&1 || true
  echo
  echo "=== rollout 历史 ==="
  kubectl -n "$NS" rollout history deploy/"$DEPLOY" 2>&1
  echo
  echo "=== 各 ReplicaSet 的关键配置对比 ==="
  for rs in $(kubectl -n "$NS" get rs -o name 2>/dev/null); do
    echo "--- $rs ---"
    kubectl -n "$NS" get "$rs" \
      -o jsonpath='  image: {.spec.template.spec.containers[0].image}{"\n"}  env:   {.spec.template.spec.containers[0].env[*].name}{"\n"}  cpu:   {.spec.template.spec.containers[0].resources.requests.cpu}/{.spec.template.spec.containers[0].resources.limits.cpu}{"\n"}  mem:   {.spec.template.spec.containers[0].resources.requests.memory}/{.spec.template.spec.containers[0].resources.limits.memory}{"\n"}  ready: {.spec.template.spec.containers[0].readinessProbe.httpGet.path}{"\n"}' 2>&1
  done
} > "$OUT/rs.txt" 2>&1
say "rs.txt"

# ── 6. 指标快照（尽力而为，Prometheus 不可用时不阻塞）────
{
  if kubectl -n monitoring get svc prometheus >/dev/null 2>&1; then
    kubectl -n monitoring port-forward svc/prometheus 19091:9090 >/tmp/pf-collect.log 2>&1 &
    PF_PID=$!
    READY=0
    for i in $(seq 1 20); do
      if curl -sf -o /dev/null http://127.0.0.1:19091/-/ready 2>/dev/null; then READY=1; break; fi
      sleep 1
    done
    if [ "$READY" -eq 0 ]; then
      echo "(Prometheus port-forward 未能就绪，跳过指标采集)"
      kill $PF_PID 2>/dev/null || true
    else
      for q in \
        'sum(up)' \
        'ALERTS{alertstate="firing"}' \
        'kube_pod_container_status_restarts_total{namespace="sre-lab"}' \
        'kube_pod_container_status_last_terminated_reason{namespace="sre-lab"}' \
        'sum by (pod) (rate(demo_http_requests_total[5m]))' \
        'histogram_quantile(0.95, sum by (le) (rate(demo_http_request_duration_seconds_bucket[5m])))' \
        'kube_deployment_status_replicas_available{namespace="sre-lab"}'
      do
        echo "### $q"
        curl -s --get --data-urlencode "query=$q" http://127.0.0.1:19091/api/v1/query \
          | python3 "$PROM_PARSER" 2>/dev/null || echo "  (查询或解析失败)"
        echo
      done
      kill $PF_PID 2>/dev/null || true
    fi
  else
    echo "(monitoring 命名空间不可用，跳过指标采集)"
  fi
} > "$OUT/metrics.txt" 2>&1
say "metrics.txt"

# ── 7. 日志证据（Loki，尽力而为）─────────────────────────
{
  if kubectl -n monitoring get svc loki >/dev/null 2>&1; then
    kubectl -n monitoring port-forward svc/loki 13100:3100 >/tmp/pf-loki.log 2>&1 &
    LOKI_PID=$!
    LOKI_READY=0
    for i in $(seq 1 20); do
      if curl -sf -o /dev/null http://127.0.0.1:13100/ready 2>/dev/null; then LOKI_READY=1; break; fi
      sleep 1
    done

    if [ "$LOKI_READY" -eq 0 ]; then
      echo "(Loki port-forward 未就绪，跳过日志采集)"
      kill $LOKI_PID 2>/dev/null || true
    else
      echo "=== 采集时间 ==="
      date '+%Y-%m-%d %H:%M:%S'
      echo
      echo "=== 各命名空间的日志量（近 15 分钟）==="
      curl -s --get --data-urlencode 'query=sum by (namespace) (count_over_time({namespace=~".+"}[15m]))' \
        http://127.0.0.1:13100/loki/api/v1/query 2>/dev/null | python3 "$PROM_PARSER" 2>/dev/null \
        || echo "  (查询失败)"
      echo
      echo "=== sre-lab 各 Pod 的日志量（近 15 分钟）==="
      curl -s --get --data-urlencode 'query=sum by (pod) (count_over_time({namespace="sre-lab"}[15m]))' \
        http://127.0.0.1:13100/loki/api/v1/query 2>/dev/null | python3 "$PROM_PARSER" 2>/dev/null \
        || echo "  (查询失败)"
      echo
      echo "=== sre-lab 中的 ERROR/FATAL 日志行数（近 15 分钟）==="
      curl -s --get --data-urlencode 'query=sum by (pod) (count_over_time({namespace="sre-lab"} |~ "(?i)error|fatal|exception|panic" [15m]))' \
        http://127.0.0.1:13100/loki/api/v1/query 2>/dev/null | python3 "$PROM_PARSER" 2>/dev/null \
        || echo "  (查询失败)"
      echo
      echo "=== sre-lab 最近 40 行原始日志 ==="
      START_NS=$(( $(date +%s) - 900 ))000000000
      curl -s --get --data-urlencode 'query={namespace="sre-lab"}' \
        --data-urlencode "start=$START_NS" --data-urlencode "limit=40" --data-urlencode "direction=backward" \
        http://127.0.0.1:13100/loki/api/v1/query_range -o /tmp/loki-recent.json 2>/dev/null
      python3 - /tmp/loki-recent.json <<'PY' 2>/dev/null || echo "  (查询失败)"
import sys, json
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)["data"]["result"]
except Exception:
    print("  (无数据)"); raise SystemExit
if not d:
    print("  (Loki 中没有任何流 —— 采集链路可能已中断)"); raise SystemExit
for s in d:
    labels = s["stream"]
    print("--- pod=%s container=%s ---" % (labels.get("pod", "?"), labels.get("container", "?")))
    for ts, line in s["values"][:5]:
        print("   ", line[:160])
PY
      echo
      echo "=== ERROR 日志样本（最近 15 分钟，最多 20 行）==="
      curl -s --get --data-urlencode 'query={namespace="sre-lab"} |~ "(?i)error|fatal|exception|panic"' \
        --data-urlencode "start=$START_NS" --data-urlencode "limit=20" --data-urlencode "direction=backward" \
        http://127.0.0.1:13100/loki/api/v1/query_range -o /tmp/loki-err.json 2>/dev/null
      python3 - /tmp/loki-err.json <<'PY' 2>/dev/null || echo "  (查询失败)"
import sys, json
try:
    with open(sys.argv[1]) as fh:
        d = json.load(fh)["data"]["result"]
except Exception:
    print("  (无数据)"); raise SystemExit
if not d:
    print("  (没有匹配 error 的日志)")
for s in d:
    print("--- pod=%s ---" % s["stream"].get("pod", "?"))
    for ts, line in s["values"][:5]:
        print("   ", line[:200])
PY
      kill $LOKI_PID 2>/dev/null || true
    fi
  else
    echo "(Loki 不可用，跳过日志采集)"
  fi
} > "$OUT/logs-loki.txt" 2>&1
say "logs-loki.txt"

rm -f "$OUT/_progress.txt"

echo
echo "=========================================="
echo "采集完成：$OUT"
echo "文件数：$(ls -1 "$OUT" | wc -l)"
echo "=========================================="
echo
echo "建议排查顺序（不要跳步）："
echo "  1. summary.txt        先看整体：是调度、启动、还是运行期问题"
echo "  2. describe.txt       找 Events，这是最权威的证据"
echo "  3. logs-previous.txt  如果容器重启过，崩溃原因在这里"
echo "  4. endpoints.txt      Service 找不到后端时看这里"
echo "  5. logs-loki.txt      应用日志：有没有 error、日志量是否异常、采集是否断了"
echo "  6. deploy.json / rs.txt  配置是否被意外改动"
echo "  7. metrics.txt        用指标交叉验证你的假设"
echo
echo "排查完执行：./scripts/drills/recover.sh"
