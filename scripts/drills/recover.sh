#!/usr/bin/env bash
# 恢复演练现场到已知good状态。
#
# 为什么不用 rollout undo：
#   undo 只回退一步，连续注入多个场景后会回到某个也是坏的 revision；
#   且它回退整个 Pod template，历史 RS 里只有当前那个带完整 5 个 env，
#   落到旧 RS 上会把 PROMETHEUS_MULTIPROC_DIR 一起丢掉。
#   实测踩过，见 docs/2-troubleshooting-sop.md 第 9 课 9.3。
#
# 因此统一用 apply 渲染清单恢复。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NS="sre-lab"
DEPLOY="demo-api"
IMAGE_SHA="${IMAGE_SHA:-cce5412d9f4a5c5d83832cd95d5ff67919c1d7c2}"

cd "$REPO_ROOT"

echo "=== 恢复到基线 ==="
echo "目标镜像: ghcr.io/0tinna/sre-devops-lab:$IMAGE_SHA"
echo

echo "--- 1. 恢复 Service selector（场景 8）---"
kubectl -n "$NS" patch svc "$DEPLOY" --type=merge -p='{"spec":{"selector":{"app.kubernetes.io/name":"demo-api"}}}' 2>/dev/null \
  && echo "    selector 已恢复" || echo "    (Service 无变化或不存在)"

echo
echo "--- 2. 渲染清单并 apply（恢复镜像/资源/探针/env）---"
sed "s|image: ghcr.io/0tinna/sre-devops-lab:latest|image: ghcr.io/0tinna/sre-devops-lab:$IMAGE_SHA|" \
  k8s/app.yaml > /tmp/app-recover.yaml
kubectl apply -f /tmp/app-recover.yaml

echo
echo "--- 2b. 恢复日志采集器（场景 10 的 nodeSelector）---"
if [ -f k8s/monitoring/75-fluent-bit.yaml ]; then
  # apply 是 merge，不会删除清单里没有的字段，所以 nodeSelector 必须显式置空
  kubectl -n monitoring patch ds fluent-bit --type=merge \
    -p='{"spec":{"template":{"spec":{"nodeSelector":null}}}}' >/dev/null 2>&1 || true
  kubectl apply -f k8s/monitoring/75-fluent-bit.yaml >/dev/null 2>&1
  kubectl -n monitoring rollout status ds/fluent-bit --timeout=180s 2>&1 | tail -1
else
  echo "    (未找到 fluent-bit 清单，跳过)"
fi

echo
echo "--- 3. 等待就绪 ---"
if kubectl -n "$NS" rollout status deploy/"$DEPLOY" --timeout=300s; then
  echo "    rollout 成功"
else
  echo "    rollout 超时，手动检查："
  kubectl -n "$NS" get pods -o wide
  kubectl -n "$NS" describe pod -l app.kubernetes.io/name="$DEPLOY" | sed -n '/Events/,$p' | tail -10
  exit 1
fi

echo
echo "--- 4. 清理可能残留的演练 Pod ---"
kubectl -n "$NS" delete pod loadgen slowgen drill-probe degradedgen --ignore-not-found 2>/dev/null || true

echo
echo "--- 5. 验证配置完整性（这是恢复成功的真正判据）---"
{
  echo "  image: $(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].image}')"
  echo "  env:   $(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}')"
  echo "  cpu:   $(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}/{.spec.template.spec.containers[0].resources.limits.cpu}')"
  echo "  mem:   $(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].resources.requests.memory}/{.spec.template.spec.containers[0].resources.limits.memory}')"
  echo "  ready: $(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].readinessProbe.httpGet.path}')"
  echo "  live:  $(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].livenessProbe.httpGet.path}')"
}

EXPECTED_ENV="PORT ENABLE_FAULT_ENDPOINTS PROMETHEUS_MULTIPROC_DIR GUNICORN_WORKERS GUNICORN_THREADS"
ACTUAL_ENV="$(kubectl -n "$NS" get deploy "$DEPLOY" -o jsonpath='{.spec.template.spec.containers[0].env[*].name}')"
if [ "$ACTUAL_ENV" = "$EXPECTED_ENV" ]; then
  echo
  echo "  ✓ env 完整（5 个）"
else
  echo
  echo "  ✗ env 不匹配！期望: $EXPECTED_ENV"
  echo "                实际: $ACTUAL_ENV"
  exit 1
fi

echo
echo "--- 6. 最终健康检查 ---"
kubectl -n "$NS" get pods
python3 scripts/opsctl.py health || true

echo
echo "=== 恢复完成 ==="
echo "建议等 2 分钟让告警自动消解，然后确认："
echo "  ./scripts/opsctl.py monitoring --query 'ALERTS{alertstate=\"firing\"}'"
