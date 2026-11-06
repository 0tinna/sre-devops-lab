#!/usr/bin/env bash
# 把应用镜像主动分发到集群所有节点。
#
# 为什么需要这个脚本（实测数据，见 docs/6-operation-log.md 18.4）：
#   K8s 只在 Pod 被调度到某节点时，才在那个节点拉镜像。
#   节点维护或故障转移时，新节点若没有镜像会卡在 Pulling：
#     - 未预热：kubectl drain 4 分钟超时失败
#     - 已预热：kubectl drain 7 秒完成
#   而直连 ghcr.io 在国内网络下 600 秒都拉不完，因此不能指望"调度时再拉"。
#
# 用法：
#   ./scripts/prewarm-image.sh                 # 分发当前 Deployment 的镜像
#   ./scripts/prewarm-image.sh <image>         # 分发指定镜像
#   ./scripts/prewarm-image.sh --prune         # 分发后清理非当前版本的旧镜像
#   ./scripts/prewarm-image.sh --check         # 只检查，不分发（CI 可用）
#
# 退出码：0 全部节点已有镜像；1 有节点缺失或分发失败。
set -euo pipefail

NS="${NS:-sre-lab}"
DEPLOY="${DEPLOY:-demo-api}"
CONTAINERD="unix:///run/containerd/containerd.sock"
CRICTL="crictl --runtime-endpoint $CONTAINERD"
SSH_OPTS="-o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5"
TARBALL="/tmp/prewarm-image.tar"

PRUNE=0
CHECK_ONLY=0
IMAGE=""
for arg in "$@"; do
  case "$arg" in
    --prune) PRUNE=1 ;;
    --check) CHECK_ONLY=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    -*) echo "未知参数: $arg" >&2; exit 2 ;;
    *) IMAGE="$arg" ;;
  esac
done

if [ -z "$IMAGE" ]; then
  IMAGE=$(kubectl -n "$NS" get deploy "$DEPLOY" \
    -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null || true)
fi
if [ -z "$IMAGE" ]; then
  echo "无法确定镜像：请显式指定，例如 ./scripts/prewarm-image.sh ghcr.io/org/app:sha" >&2
  exit 2
fi

SELF="$(hostname)"

echo "=== 镜像分发 ==="
echo "镜像: $IMAGE"
echo "本机: $SELF"
echo

# 收集节点：名称 + InternalIP
declare -a NODE_NAMES=()
declare -a NODE_IPS=()
while IFS='|' read -r name ip; do
  [ -n "$name" ] || continue
  NODE_NAMES+=("$name")
  NODE_IPS+=("$ip")
done < <(kubectl get nodes \
  -o jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.addresses[?(@.type=="InternalIP")].address}{"\n"}{end}')

# 在指定节点上执行 crictl（本机直接跑，远端走 ssh）
node_crictl() {
  local host="$1"; shift
  if [ "$host" = "$SELF" ]; then
    $CRICTL "$@"
  else
    ssh $SSH_OPTS "root@$host" "$CRICTL $* 2>/dev/null"
  fi
}

node_has_image() {
  local host="$1"
  node_crictl "$host" images 2>/dev/null \
    | awk '{print $1":"$2}' | grep -qx "$IMAGE"
}

# 1) 盘点：哪些节点已有镜像
echo "--- 盘点 ---"
declare -a HAVE=()
declare -a MISS=()
for i in "${!NODE_NAMES[@]}"; do
  n="${NODE_NAMES[$i]}"
  h="${NODE_IPS[$i]}"
  [ -n "$h" ] || h="$n"
  if node_has_image "$h"; then
    HAVE+=("$n")
    printf '  ✓ %-10s 已有\n' "$n"
  else
    MISS+=("$n")
    printf '  ✗ %-10s 缺失\n' "$n"
  fi
done
echo

if [ "$CHECK_ONLY" -eq 1 ]; then
  if [ "${#MISS[@]}" -eq 0 ]; then
    echo "结果: 全部 ${#HAVE[@]} 个节点已有镜像"
    exit 0
  fi
  echo "结果: ${#MISS[@]} 个节点缺失镜像 → ${MISS[*]}"
  exit 1
fi

if [ "${#MISS[@]}" -eq 0 ]; then
  echo "无需分发。"
else
  # 2) 选源节点
  if [ "${#HAVE[@]}" -gt 0 ]; then
    SRC_NAME="${HAVE[0]}"
    SRC_IP=""
    for i in "${!NODE_NAMES[@]}"; do
      [ "${NODE_NAMES[$i]}" = "$SRC_NAME" ] && SRC_IP="${NODE_IPS[$i]}"
    done
    [ -n "$SRC_IP" ] || SRC_IP="$SRC_NAME"
    echo "--- 源节点: $SRC_NAME ($SRC_IP) ---"
    echo "--- 导出镜像 ---"
    start=$(date +%s)
    node_crictl "$SRC_IP" images export --platform linux/amd64 "$TARBALL" "$IMAGE" >/dev/null 2>&1 || {
      echo "  导出失败（源节点 $SRC_NAME）" >&2
      exit 1
    }
    SIZE=$(node_crictl "$SRC_IP" sh -c "ls -lh $TARBALL 2>/dev/null | awk '{print \$5}'" 2>/dev/null || echo '?')
    echo "  完成，大小 ${SIZE:-?}，耗时 $(( $(date +%s) - start ))s"
    echo
  else
    echo "--- 没有任何节点有该镜像，直接在第一个节点拉取（可能很慢）---"
    FIRST_IP="${NODE_IPS[0]}"
    SRC_NAME="${NODE_NAMES[0]}"
    SRC_IP="$FIRST_IP"
    [ -n "$SRC_IP" ] || SRC_IP="$SRC_NAME"
    start=$(date +%s)
    node_crictl "$SRC_IP" pull "$IMAGE" >/dev/null 2>&1 || {
      echo "  拉取失败；考虑先在任一节点手动拉取，或用内网 registry" >&2
      exit 1
    }
    echo "  完成，耗时 $(( $(date +%s) - start ))s"
    node_crictl "$SRC_IP" images export --platform linux/amd64 "$TARBALL" "$IMAGE" >/dev/null 2>&1
    MISS=("${NODE_NAMES[@]}")
    HAVE=()
    echo
  fi

  # 3) 分发到缺失节点
  echo "--- 分发 ---"
  for target in "${MISS[@]}"; do
    tip=""
    for i in "${!NODE_NAMES[@]}"; do
      [ "${NODE_NAMES[$i]}" = "$target" ] && tip="${NODE_IPS[$i]}"
    done
    [ -n "$tip" ] || tip="$target"

    printf '  → %-10s ' "$target"
    start=$(date +%s)

    if [ "$tip" = "$SELF" ]; then
      # 源在远端，目标是本机：从源 scp 过来
      scp $SSH_OPTS "root@$SRC_IP:$TARBALL" "$TARBALL" >/dev/null 2>&1 || {
        printf '失败（scp）\n'; continue;
      }
    elif [ "$SRC_IP" = "$SELF" ]; then
      # 源在本机，目标是远端：scp 过去
      scp $SSH_OPTS "$TARBALL" "root@$tip:$TARBALL" >/dev/null 2>&1 || {
        printf '失败（scp）\n'; continue;
      }
    else
      # 源和目标都是远端：借本机中转，避免节点间直连依赖
      scp $SSH_OPTS "root@$SRC_IP:$TARBALL" "$TARBALL" >/dev/null 2>&1 \
        && scp $SSH_OPTS "$TARBALL" "root@$tip:$TARBALL" >/dev/null 2>&1 || {
        printf '失败（scp 中转）\n'; continue;
      }
    fi

    if node_crictl "$tip" images import --platform linux/amd64 "$TARBALL" >/dev/null 2>&1; then
      printf '完成 %ss\n' "$(( $(date +%s) - start ))"
    else
      printf '失败（import）\n'
    fi

    # 远端临时文件清理
    [ "$tip" != "$SELF" ] && ssh $SSH_OPTS "root@$tip" "rm -f $TARBALL" >/dev/null 2>&1 || true
  done

  # 源节点临时文件清理
  if [ "$SRC_IP" = "$SELF" ]; then
    rm -f "$TARBALL"
  else
    ssh $SSH_OPTS "root@$SRC_IP" "rm -f $TARBALL" >/dev/null 2>&1 || true
  fi
  echo

  # 4) 复验
  echo "--- 复验 ---"
  FAILED=0
  for i in "${!NODE_NAMES[@]}"; do
    n="${NODE_NAMES[$i]}"
    h="${NODE_IPS[$i]}"
    [ -n "$h" ] || h="$n"
    if node_has_image "$h"; then
      printf '  ✓ %-10s 已有\n' "$n"
    else
      printf '  ✗ %-10s 仍缺失\n' "$n"
      FAILED=1
    fi
  done
  echo
  if [ "$FAILED" -ne 0 ]; then
    echo "结果: 有节点仍缺失镜像" >&2
    exit 1
  fi

  echo "结果: 全部节点已就绪"
fi

# 5) 可选：清理旧版本镜像
if [ "$PRUNE" -eq 1 ]; then
  echo
  echo "--- 清理旧版本 sre-devops 镜像（保留当前 $IMAGE）---"
  REPO="${IMAGE%:*}"
  for i in "${!NODE_NAMES[@]}"; do
    n="${NODE_NAMES[$i]}"
    h="${NODE_IPS[$i]}"
    [ -n "$h" ] || h="$n"
    # 列出同仓库但非当前 tag 的镜像
    STALE=$(node_crictl "$h" images 2>/dev/null \
      | awk -v repo="$REPO" -v keep="$IMAGE" '$1 == repo && ($1":"$2) != keep {print $1":"$2}' || true)
    if [ -z "$STALE" ]; then
      printf '  %-10s 无旧版本\n' "$n"
      continue
    fi
    COUNT=0
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      if node_crictl "$h" rmi "$ref" >/dev/null 2>&1; then
        COUNT=$((COUNT + 1))
      fi
    done <<< "$STALE"
    printf '  %-10s 清理 %s 个旧版本\n' "$n" "$COUNT"
  done
fi

exit 0