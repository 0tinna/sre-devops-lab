#!/usr/bin/env bash
# 在 master 节点安装 GitHub Actions self-hosted runner，用于实现全自动 CD。
#
# 前置：需要在 GitHub 上获取 registration token（有效期 1 小时）：
#   仓库 Settings → Actions → Runners → New self-hosted runner
#   页面里给出的 --token 值就是，或复制页面上的完整配置命令。
#   也可用 API：curl -sX POST -H "Authorization: token <PAT>" \
#     https://api.github.com/repos/<owner>/<repo>/actions/runners/registration-token | jq -r .token
#
# 用法：
#   sudo ./scripts/install-runner.sh --token <REGISTRATION_TOKEN>
#   sudo ./scripts/install-runner.sh --token <T> --version 2.329.0
#
# 卸载：
#   cd /opt/actions-runner && ./svc.sh stop && ./svc.sh uninstall && ./config.sh remove --token <TOKEN>
set -euo pipefail

RUNNER_VERSION="2.329.0"
RUNNER_HOME="/opt/actions-runner"
RUNNER_USER="root"
REPO_URL="${REPO_URL:-https://github.com/0tinna/sre-devops-lab}"
LABELS="self-hosted,linux,sre-lab"
TOKEN=""

while [ $# -gt 0 ]; do
  case "$1" in
    --token) TOKEN="$2"; shift 2 ;;
    --version) RUNNER_VERSION="$2"; shift 2 ;;
    --repo) REPO_URL="$2"; shift 2 ;;
    --labels) LABELS="$2"; shift 2 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -n "$TOKEN" ] || { echo "缺少 --token，请先到 GitHub 页面获取 registration token" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "需要 root 权限（systemd 服务安装）" >&2; exit 2; }

echo "=== 1. 检查前置条件 ==="
for cmd in curl tar kubectl; do
  command -v "$cmd" >/dev/null || { echo "缺少依赖: $cmd" >&2; exit 1; }
done
kubectl get nodes >/dev/null || { echo "kubectl 无法访问集群，先确认 kubeconfig" >&2; exit 1; }
echo "  kubectl 可用，集群: $(kubectl config current-context 2>/dev/null || echo default)"
echo "  GitHub 可达性:"
curl -s -o /dev/null -w "    github.com -> %{http_code}\n" --max-time 10 https://github.com

echo
echo "=== 2. 下载 runner $RUNNER_VERSION ==="
ARCH=$(uname -m)
case "$ARCH" in
  x86_64) RUNNER_ARCH="x64" ;;
  aarch64|arm64) RUNNER_ARCH="arm64" ;;
  *) echo "不支持的架构: $ARCH" >&2; exit 1 ;;
esac
PKG="actions-runner-linux-${RUNNER_ARCH}-${RUNNER_VERSION}.tar.gz"
URL="https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/${PKG}"

mkdir -p "$RUNNER_HOME"
cd "$RUNNER_HOME"
if [ ! -f "$PKG" ]; then
  curl -fL --retry 3 --max-time 300 -o "$PKG" "$URL"
fi
echo "  已下载: $(du -h "$PKG" | cut -f1)"

echo
echo "=== 3. 解压 ==="
tar xzf "$PKG"

echo
echo "=== 4. 配置 runner ==="
./config.sh \
  --url "$REPO_URL" \
  --token "$TOKEN" \
  --name "sre-lab-master" \
  --labels "$LABELS" \
  --work "_work" \
  --unattended \
  --replace

echo
echo "=== 5. 安装为 systemd 服务 ==="
./svc.sh install "$RUNNER_USER"
./svc.sh start
sleep 3
./svc.sh status || true

echo
echo "=== 6. 验证 ==="
systemctl is-active "actions.runner.$(echo "$REPO_URL" | sed 's|https://github.com/||; s|/|-|g').sre-lab-master.service" 2>/dev/null \
  || systemctl list-units --type=service --all | grep -i actions.runner || true

echo
echo "完成。回到 GitHub 的 Runners 页面应看到 sre-lab-master 为 Idle。"
echo "之后 ci 在 main 上成功后，cd workflow 会自动部署到本机集群。"
echo
echo "提醒：runner 以 root 运行且持有集群权限，只适用于实验环境。"
echo "      生产环境应使用专用用户、最小 RBAC、以及 ephemeral runner。"
