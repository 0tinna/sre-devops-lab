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
set -uo pipefail

NS="${NS:-sre-lab}"
DEPLOY="${DEPLOY:-demo-api}"
# crictl 负责 images / pull / rmi；注意它**没有** export / import 子命令，
# 那两个是 ctr 的能力，混用会得到一条 crictl 帮助信息而不是镜像。
CRICTL="crictl --runtime-endpoint unix:///run/containerd/containerd.sock"
CTR="ctr -n k8s.io"
# -n 很关键：ssh/scp 默认会读 stdin。若本脚本是通过 ``... | bash`` 管道传入的，
# 子进程会把剩余脚本当输入吃掉，导致脚本中途中止且没有报错（踩过）。
SSH_OPTS="-n -o BatchMode=yes -o StrictHostKeyChecking=no -o ConnectTimeout=5"
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

# 在指定主机上执行任意 shell 命令（本机直接跑，远端走 ssh）。
# 统一入口，避免"某类操作只能本机 / 某类只能远端"的分裂。
on_node() {
  local host="$1"
  local cmd="$2"
  if [ "$host" = "$SELF" ]; then
    bash -c "$cmd"
  else
    ssh $SSH_OPTS "root@$host" "$cmd"
  fi
}

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

# 节点名 -> 访问地址（优先 InternalIP）。
# 本机必须返回主机名而不是 IP：后续所有"是不是本机"的判断
# 都拿它和 $SELF 比，返回 IP 会永远判成远端（踩过：master 的
# InternalIP 是 172.31.6.211，而 SELF 是 master，于是反复尝试
# scp 到自己，全部失败）。
addr_of() {
  local want="$1" i
  if [ "$want" = "$SELF" ]; then
    echo "$SELF"
    return 0
  fi
  for i in "${!NODE_NAMES[@]}"; do
    if [ "${NODE_NAMES[$i]}" = "$want" ]; then
      if [ -n "${NODE_IPS[$i]}" ]; then echo "${NODE_IPS[$i]}"; else echo "$want"; fi
      return 0
    fi
  done
  echo "$want"
}

node_has_image() {
  local host="$1"
  on_node "$host" "$CRICTL images 2>/dev/null | awk '{print \$1\":\"\$2}' | grep -qx '$IMAGE'" 2>/dev/null
}

# 1) 盘点
echo "--- 盘点 ---"
declare -a HAVE=()
declare -a MISS=()
for i in "${!NODE_NAMES[@]}"; do
  n="${NODE_NAMES[$i]}"
  h="$(addr_of "$n")"
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
  else
    echo "--- 没有任何节点有该镜像，在第一个节点拉取（可能很慢）---"
    SRC_NAME="${NODE_NAMES[0]}"
    FIRST_IP="$(addr_of "$SRC_NAME")"
    start=$(date +%s)
    if ! on_node "$FIRST_IP" "$CRICTL pull '$IMAGE'"; then
      echo "  拉取失败；考虑先在任一节点手动拉取，或用内网 registry" >&2
      exit 1
    fi
    echo "  拉取完成，耗时 $(( $(date +%s) - start ))s"
    HAVE=("$SRC_NAME")
    MISS=()
    for n in "${NODE_NAMES[@]}"; do
      [ "$n" = "$SRC_NAME" ] || MISS+=("$n")
    done
  fi

  SRC_IP="$(addr_of "$SRC_NAME")"
  echo "--- 源节点: $SRC_NAME ($SRC_IP) ---"

  # 3) 导出
  echo "--- 导出镜像 ---"
  start=$(date +%s)
  if ! on_node "$SRC_IP" "$CTR images export --platform linux/amd64 '$TARBALL' '$IMAGE'"; then
    echo "  导出失败（源节点 $SRC_NAME）" >&2
    on_node "$SRC_IP" "rm -f $TARBALL" >/dev/null 2>&1
    exit 1
  fi
  SIZE=$(on_node "$SRC_IP" "ls -lh '$TARBALL' 2>/dev/null | awk '{print \$5}'" 2>/dev/null)
  if [ -z "$SIZE" ]; then
    echo "  导出后找不到 $TARBALL（源节点 $SRC_NAME）" >&2
    exit 1
  fi
  echo "  完成，大小 ${SIZE}，耗时 $(( $(date +%s) - start ))s"
  echo

  # 4) 分发到缺失节点
  echo "--- 分发 ---"
  FAILED=0
  for target in "${MISS[@]}"; do
    tip="$(addr_of "$target")"
    printf '  → %-10s ' "$target"
    start=$(date +%s)

    # 统一借本机中转：源 → 本机 → 目标。
    # 不依赖节点之间的直连 SSH，也不要求源和目标谁能连谁。
    if [ "$SRC_IP" != "$SELF" ]; then
      if ! scp ${SSH_OPTS/-n/} "root@$SRC_IP:$TARBALL" "$TARBALL" </dev/null >/dev/null 2>&1; then
        printf '失败（从源拉取）\n'; FAILED=1
        continue
      fi
    fi
    if [ "$tip" != "$SELF" ]; then
      if ! scp ${SSH_OPTS/-n/} "$TARBALL" "root@$tip:$TARBALL" </dev/null >/dev/null 2>&1; then
        printf '失败（推送到目标）\n'; FAILED=1
        continue
      fi
    fi

    if on_node "$tip" "$CTR images import --platform linux/amd64 '$TARBALL'" >/dev/null 2>&1; then
      printf '完成 %ss\n' "$(( $(date +%s) - start ))"
    else
      printf '失败（import）\n'; FAILED=1
    fi
    on_node "$tip" "rm -f $TARBALL" >/dev/null 2>&1
  done

  # 清理：本机与源节点
  [ "$SRC_IP" != "$SELF" ] && on_node "$SRC_IP" "rm -f $TARBALL" >/dev/null 2>&1
  rm -f "$TARBALL"
  echo

  # 5) 复验
  echo "--- 复验 ---"
  for i in "${!NODE_NAMES[@]}"; do
    n="${NODE_NAMES[$i]}"
    h="$(addr_of "$n")"
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

# 6) 可选：清理旧版本镜像
if [ "$PRUNE" -eq 1 ]; then
  echo
  echo "--- 清理旧版本镜像（保留当前 $IMAGE）---"
  REPO="${IMAGE%:*}"
  for i in "${!NODE_NAMES[@]}"; do
    n="${NODE_NAMES[$i]}"
    h="$(addr_of "$n")"
    STALE=$(on_node "$h" "$CRICTL images 2>/dev/null | awk -v repo='$REPO' -v keep='$IMAGE' '\$1 == repo && (\$1\":\"\$2) != keep {print \$1\":\"\$2}'" 2>/dev/null)
    if [ -z "$STALE" ]; then
      printf '  %-10s 无旧版本\n' "$n"
      continue
    fi
    COUNT=0
    while IFS= read -r ref; do
      [ -n "$ref" ] || continue
      on_node "$h" "$CRICTL rmi '$ref'" >/dev/null 2>&1 && COUNT=$((COUNT + 1))
    done <<< "$STALE"
    printf '  %-10s 清理 %s 个旧版本\n' "$n" "$COUNT"
  done
fi

exit 0