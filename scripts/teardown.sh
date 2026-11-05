#!/usr/bin/env bash
# 一键回收实验资源。默认只删除业务与监控命名空间，不动集群系统组件。
#
# 用法：
#   ./scripts/teardown.sh              # 删除 monitoring + sre-lab
#   ./scripts/teardown.sh --dry-run    # 只打印将执行的操作
#   ./scripts/teardown.sh --keep-monitoring   # 保留监控，只删业务
#   ./scripts/teardown.sh --yes        # 跳过确认
#
# 安全边界：本脚本永不操作 kube-system / kube-flannel / kube-public / kube-node-lease，
# 也不删除 CRD、ClusterRole（除非带 --include-rbac）。
set -euo pipefail

DRY_RUN=0
KEEP_MONITORING=0
ASSUME_YES=0
INCLUDE_RBAC=0

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=1 ;;
    --keep-monitoring) KEEP_MONITORING=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    --include-rbac) INCLUDE_RBAC=1 ;;
    -h|--help) sed -n '2,20p' "$0"; exit 0 ;;
    *) echo "未知参数: $arg" >&2; exit 2 ;;
  esac
done

run() {
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "[dry-run] $*"
  else
    echo "+ $*"
    "$@"
  fi
}

confirm() {
  if [ "$ASSUME_YES" -eq 1 ] || [ "$DRY_RUN" -eq 1 ]; then
    return 0
  fi
  echo
  echo "即将删除以下命名空间："
  for ns in "$@"; do
    echo "  - $ns"
  done
  echo
  read -r -p "确认继续？输入 yes 继续：" reply
  [ "$reply" = "yes" ] || { echo "已取消"; exit 1; }
}

TARGETS=()
[ "$KEEP_MONITORING" -eq 0 ] && TARGETS+=("monitoring")
TARGETS+=("sre-lab")

echo "=== 当前资源 ==="
kubectl get ns 2>/dev/null | grep -E "NAME|monitoring|sre-lab" || true
echo

confirm "${TARGETS[@]}"

for ns in "${TARGETS[@]}"; do
  if kubectl get ns "$ns" >/dev/null 2>&1; then
    echo
    echo "--- 删除命名空间 $ns ---"
    # 先删工作负载，避免 volume/endpoint 清理卡住
    run kubectl -n "$ns" delete deploy,sts,ds --all --ignore-not-found --wait=false
    run kubectl -n "$ns" delete svc --all --ignore-not-found --wait=false
    run kubectl -n "$ns" delete pod --all --ignore-not-found --wait=false
    run kubectl delete ns "$ns" --ignore-not-found --wait=true --timeout=180s
  else
    echo "--- 命名空间 $ns 不存在，跳过 ---"
  fi
done

if [ "$INCLUDE_RBAC" -eq 1 ]; then
  echo
  echo "--- 删除集群级 RBAC ---"
  run kubectl delete clusterrole prometheus-sre-lab kube-state-metrics-sre-lab --ignore-not-found
  run kubectl delete clusterrolebinding prometheus-sre-lab kube-state-metrics-sre-lab --ignore-not-found
fi

echo
echo "=== 回收后剩余命名空间 ==="
kubectl get ns
echo
echo "=== 确认系统组件未受影响 ==="
kubectl get nodes
kubectl -n kube-system get pods --no-headers | wc -l | xargs echo "kube-system Pod 数:"

if [ "$DRY_RUN" -eq 0 ]; then
  echo
  echo "完成。若要重建，执行："
  echo "  kubectl apply -f k8s/namespace.yaml"
  echo "  kubectl apply -f k8s/app.yaml"
  echo "  kubectl apply -f k8s/monitoring/"
fi
