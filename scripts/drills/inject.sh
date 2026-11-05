#!/usr/bin/env bash
# 故障演练注入器。注入一个真实故障，但不告诉你根因——用于练习系统性排查。
#
# 用法：
#   ./scripts/drills/inject.sh list          # 列出所有场景
#   ./scripts/drills/inject.sh 3             # 注入场景 3
#   ./scripts/drills/recover.sh              # 恢复（任何场景都用这个）
#   ./scripts/drills/collect.sh 3            # 采集现场证据
#
# 设计原则：注入后集群进入真实的故障状态，现象与生产环境一致。
# 恢复统一走 apply 渲染清单，不依赖 rollout undo（undo 只回退一步，不可靠）。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="sre-lab"
DEPLOY="demo-api"
IMAGE_SHA="cce5412d9f4a5c5d83832cd95d5ff67919c1d7c2"

declare -A SCENARIOS=(
  [1]="探针路径被改成不存在的端点"
  [2]="环境变量名拼写错误导致应用启动失败"
  [3]="内存 limit 压得比应用启动所需还低"
  [4]="资源 requests 超过节点可分配量"
  [5]="镜像 tag 指向不存在的版本"
  [6]="readiness 超时时间被设得极短"
  [7]="用 set image 发布，导致 env/volume 配置丢失"
  [8]="Service 的 selector 与服务端标签不匹配"
)

list_scenarios() {
  echo "可用场景："
  for i in $(seq 1 8); do
    echo "  $i) ${SCENARIOS[$i]}"
  done
  echo
  echo "注入后建议流程："
  echo "  1. ./scripts/drills/collect.sh <编号>   采集现场证据"
  echo "  2. 按 SOP 九课的顺序排查（docs/2-troubleshooting-sop.md）"
  echo "  3. ./scripts/drills/recover.sh          恢复"
  echo "  4. 对照 docs/drills/answers/ 检查你的判断"
}

wait_rollout() {
  kubectl -n "$NS" rollout status "deploy/$DEPLOY" --timeout="${1:-120s}" 2>&1 | tail -2 || true
}

case "${1:-}" in
  list|"")
    list_scenarios
    exit 0
    ;;
esac

SCENARIO="$1"
[ -n "${SCENARIOS[$SCENARIO]:-}" ] || { echo "未知场景: $SCENARIO" >&2; list_scenarios; exit 2; }

echo "=========================================="
echo "注入场景 $SCENARIO：${SCENARIOS[$SCENARIO]}"
echo "时间: $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="
echo
echo "提示：注入后不要立刻看本文件，先用 collect.sh 采集现场，自己排查。"
echo

case "$SCENARIO" in
  1)
    # 探针路径改成不存在
    kubectl -n "$NS" patch deploy "$DEPLOY" --type=json -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/httpGet/path","value":"/health"},
      {"op":"replace","path":"/spec/template/spec/containers/0/livenessProbe/httpGet/path","value":"/live"}
    ]'
    echo "已注入。预计 15-30 秒后 Pod 开始 NotReady。"
    ;;

  2)
    # 拼错的 env 名——应用会因为没有 PORT 而监听默认 8080？不，用错误的配置键让它崩
    kubectl -n "$NS" patch deploy "$DEPLOY" --type=json -p='[
      {"op":"add","path":"/spec/template/spec/containers/0/env/-","value":{"name":"GUNICORN_WORKER","value":"2"}}
    ]'
    # 同时把 PORT 改成非法值，让 gunicorn bind 失败
    kubectl -n "$NS" patch deploy "$DEPLOY" --type=json -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/env/0/value","value":"not-a-port"}
    ]'
    echo "已注入。预计应用启动时 bind 失败。"
    ;;

  3)
    kubectl -n "$NS" set resources deploy/"$DEPLOY" --limits=memory=48Mi --requests=memory=32Mi
    echo "已注入。预计容器启动阶段被 OOMKill。"
    ;;

  4)
    kubectl -n "$NS" patch deploy "$DEPLOY" --type=json -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/requests/cpu","value":"6"},
      {"op":"replace","path":"/spec/template/spec/containers/0/resources/limits/cpu","value":"6"}
    ]'
    echo "已注入。预计新 Pod 无法调度。"
    ;;

  5)
    kubectl -n "$NS" set image deploy/"$DEPLOY" "$DEPLOY=ghcr.io/0tinna/sre-devops-lab:v1.0.0-rc1"
    echo "已注入。预计新 Pod 拉取失败。"
    ;;

  6)
    kubectl -n "$NS" patch deploy "$DEPLOY" --type=json -p='[
      {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/timeoutSeconds","value":1},
      {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/periodSeconds","value":1},
      {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/failureThreshold","value":1},
      {"op":"replace","path":"/spec/template/spec/containers/0/readinessProbe/initialDelaySeconds","value":0}
    ]'
    echo "已注入。预计就绪状态开始抖动。"
    ;;

  7)
    # 用 set image 发布同版本，制造"配置丢失"的假象：先改 env 再 set image
    kubectl -n "$NS" set image deploy/"$DEPLOY" "$DEPLOY=ghcr.io/0tinna/sre-devops-lab:$IMAGE_SHA"
    echo "已注入。这与正常发布看起来一样，但历史 ReplicaSet 的配置可能不同。"
    echo "重点观察：新 Pod 的 env 列表 vs 你期望的列表。"
    ;;

  8)
    kubectl -n "$NS" patch svc "$DEPLOY" --type=json -p='[
      {"op":"replace","path":"/spec/selector","value":{"app.kubernetes.io/name":"demo-api-v2"}}
    ]'
    echo "已注入。预计 Service 找不到后端。"
    ;;

  *)
    echo "场景 $SCENARIO 未实现" >&2
    exit 2
    ;;
esac

echo
echo "25 秒后采集一次快照供参考（不含分析）："
sleep 25
kubectl -n "$NS" get pods -o wide
echo
echo "下一步：./scripts/drills/collect.sh $SCENARIO"
