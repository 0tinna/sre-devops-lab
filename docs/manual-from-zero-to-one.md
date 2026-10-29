# 从 0 到 1 手动实践手册

本手册面向完全由个人操作的环境。你不需要依赖 Codex 之前执行过的步骤。

本手册使用的环境：

| 项目 | 值 |
| --- | --- |
| 跳板机 | 1.95.123.118 |
| master | 172.31.6.211 |
| node | 172.31.12.103 |
| GitHub 用户名 | 0tinna |
| GitHub 仓库 | sre-devops-lab |
| 本地项目目录 | C:/Users/qitin/Documents/sre-devops-lab |
| master 项目目录 | /opt/sre-devops-lab |

如果你使用另一套环境，请先替换这些值。

## 0. 最终目标

完成后形成完整闭环：

~~~text
本地代码 -> Git 提交 -> push GitHub -> Actions 测试 -> Actions 构建
-> GHCR 镜像 -> Kubernetes 拉取 -> 滚动发布 -> 健康检查 -> 回滚
~~~

最终应能执行：

~~~bash
kubectl -n sre-lab get deploy demo-api
kubectl -n sre-lab get pods
curl http://127.0.0.1:18080/healthz
curl http://127.0.0.1:18080/metrics
~~~

## 1. 开始前检查

### 1.1 检查 Windows SSH 密钥

在 PowerShell 执行：

~~~powershell
Test-Path $HOME/.ssh/id_ed25519
~~~

预期输出 True。没有密钥时生成：

~~~powershell
ssh-keygen -t ed25519 -C "sre-lab" -f $HOME/.ssh/id_ed25519
Get-Content $HOME/.ssh/id_ed25519.pub
~~~

把公钥添加到跳板机的 /root/.ssh/authorized_keys。

### 1.2 测试跳板机

~~~powershell
ssh -i $HOME/.ssh/id_ed25519 root@1.95.123.118 "hostname; whoami"
~~~

预期看到跳板机主机名和 root。

### 1.3 测试 master

master 不信任本机公钥，需要通过跳板机转发：

~~~powershell
ssh -i $HOME/.ssh/id_ed25519 root@1.95.123.118 "ssh root@172.31.6.211 'hostname; whoami'"
~~~

预期看到 master 和 root。

### 1.4 可选：跳板机交互式别名

登录跳板机：

~~~powershell
ssh -i $HOME/.ssh/id_ed25519 root@1.95.123.118
~~~

在跳板机执行：

~~~bash
cat >> ~/.bashrc <<'EOF'
alias master='ssh root@172.31.6.211'
alias node='ssh root@172.31.12.103'
EOF
source ~/.bashrc
~~~

别名只适合交互式 shell，不适合 ssh host "命令" 这种非交互执行。

## 2. 集群基线检查

登录 master：

~~~powershell
ssh -i $HOME/.ssh/id_ed25519 root@1.95.123.118
~~~

在跳板机执行：

~~~bash
ssh root@172.31.6.211
~~~

进入 master 后执行：

~~~bash
kubectl get nodes -o wide
kubectl get pods -A -o wide
kubectl get deploy,sts,ds,svc,ingress -A
kubectl get pv,pvc -A
kubectl get sc
kubectl get --raw='/readyz?verbose'
free -h
df -h /
~~~

预期：两个节点 Ready，系统组件正常，没有业务工作负载，readyz check passed。

检查网络：

~~~bash
curl -I -m 10 https://registry-1.docker.io/v2/
curl -I -m 10 https://ghcr.io/v2/
~~~

本环境的预期结果：Docker Hub 超时，GHCR 可访问。构建放在 GitHub Actions，集群从 GHCR 拉取最终镜像。

## 3. 创建本地项目

在 Windows PowerShell 执行：

~~~powershell
$project = "C:/Users/qitin/Documents/sre-devops-lab"
New-Item -ItemType Directory -Path $project -Force | Out-Null
New-Item -ItemType Directory -Path "$project/app" -Force | Out-Null
New-Item -ItemType Directory -Path "$project/k8s" -Force | Out-Null
New-Item -ItemType Directory -Path "$project/tests" -Force | Out-Null
New-Item -ItemType Directory -Path "$project/scripts" -Force | Out-Null
New-Item -ItemType Directory -Path "$project/.github/workflows" -Force | Out-Null
~~~

使用编辑器创建以下文件。

### 3.1 app/requirements.txt

~~~text
Flask==3.0.3
gunicorn==22.0.0
prometheus-client==0.20.0
~~~

### 3.2 app/app.py

~~~python
import os
import random
import time

from flask import Flask, Response, g, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest


app = Flask(__name__)

REQUEST_COUNT = Counter(
    'demo_http_requests_total',
    'Total HTTP requests',
    ['method', 'path', 'status'],
)
REQUEST_LATENCY = Histogram(
    'demo_http_request_duration_seconds',
    'HTTP request duration in seconds',
    ['method', 'path'],
)


@app.before_request
def start_timer():
    g.start_time = time.perf_counter()


@app.after_request
def record_metrics(response):
    duration = time.perf_counter() - getattr(g, 'start_time', time.perf_counter())
    REQUEST_COUNT.labels(request.method, request.path, str(response.status_code)).inc()
    REQUEST_LATENCY.labels(request.method, request.path).observe(duration)
    return response


@app.get('/')
def index():
    return jsonify(service='sre-devops-lab', status='ok')


@app.get('/healthz')
def healthz():
    return jsonify(status='ok')


@app.get('/readyz')
def readyz():
    return jsonify(status='ready')


@app.get('/api/orders')
def create_order():
    time.sleep(random.uniform(0.01, 0.05))
    return jsonify(order_id=random.randint(1000, 9999), status='created')


@app.get('/simulate/error')
def simulate_error():
    return jsonify(error='simulated failure'), 500


@app.get('/simulate/slow')
def simulate_slow():
    time.sleep(2)
    return jsonify(status='slow response')


@app.get('/metrics')
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.getenv('PORT', '8080')))
~~~

### 3.3 Dockerfile

Dockerfile 必须放在仓库根目录。GitHub Actions 默认读取根目录 Dockerfile。

~~~dockerfile
FROM python:3.12-slim AS builder

WORKDIR /build
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

WORKDIR /app
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /install /usr/local
COPY app/app.py .

USER 10001:10001
EXPOSE 8080

CMD gunicorn --bind 0.0.0.0:8080 --workers 2 --threads 2 --access-logfile - app:app
~~~

关键点：USER 必须使用数字 UID。写成 USER app 会导致 Kubernetes 的 runAsNonRoot 无法验证，出现 CreateContainerConfigError。

### 3.4 k8s/namespace.yaml

~~~yaml
apiVersion: v1
kind: Namespace
metadata:
  name: sre-lab
  labels:
    app.kubernetes.io/part-of: sre-devops-lab
~~~

### 3.5 k8s/app.yaml

~~~yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-api
  namespace: sre-lab
  labels:
    app.kubernetes.io/name: demo-api
    app.kubernetes.io/part-of: sre-devops-lab
spec:
  replicas: 2
  strategy:
    type: RollingUpdate
    rollingUpdate:
      maxUnavailable: 0
      maxSurge: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: demo-api
  template:
    metadata:
      labels:
        app.kubernetes.io/name: demo-api
        app.kubernetes.io/part-of: sre-devops-lab
      annotations:
        prometheus.io/scrape: 'true'
        prometheus.io/port: '8080'
        prometheus.io/path: '/metrics'
    spec:
      securityContext:
        runAsNonRoot: true
        runAsUser: 10001
        runAsGroup: 10001
        fsGroup: 10001
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: demo-api
          image: ghcr.io/0tinna/sre-devops-lab:latest
          imagePullPolicy: IfNotPresent
          ports:
            - name: http
              containerPort: 8080
          env:
            - name: PORT
              value: '8080'
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 500m
              memory: 256Mi
          readinessProbe:
            httpGet:
              path: /readyz
              port: http
            initialDelaySeconds: 5
            periodSeconds: 5
          livenessProbe:
            httpGet:
              path: /healthz
              port: http
            initialDelaySeconds: 10
            periodSeconds: 10
          securityContext:
            allowPrivilegeEscalation: false
            capabilities:
              drop:
                - ALL
---
apiVersion: v1
kind: Service
metadata:
  name: demo-api
  namespace: sre-lab
  labels:
    app.kubernetes.io/name: demo-api
    app.kubernetes.io/part-of: sre-devops-lab
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: demo-api
  ports:
    - name: http
      port: 80
      targetPort: http
~~~

### 3.6 tests/test_app.py

~~~python
import unittest

from app.app import app


class AppTestCase(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()

    def test_healthz(self):
        response = self.client.get('/healthz')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()['status'], 'ok')

    def test_readyz(self):
        response = self.client.get('/readyz')
        self.assertEqual(response.status_code, 200)
        self.assertEqual(response.get_json()['status'], 'ready')

    def test_metrics_endpoint(self):
        response = self.client.get('/metrics')
        self.assertEqual(response.status_code, 200)
        self.assertIn(b'demo_http_requests_total', response.data)


if __name__ == '__main__':
    unittest.main()
~~~

### 3.7 .github/workflows/ci.yml

~~~yaml
name: ci

on:
  pull_request:
  push:
    branches:
      - main

permissions:
  contents: read
  packages: write

jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-python@v5
        with:
          python-version: '3.12'
      - name: Install dependencies
        run: pip install -r app/requirements.txt
      - name: Compile check
        run: python -m compileall app
      - name: Unit tests
        run: python -m unittest discover -s tests

  image:
    needs: validate
    if: github.event_name == 'push' && github.ref == 'refs/heads/main'
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          push: true
          tags: |
            ghcr.io/${{ github.repository_owner }}/sre-devops-lab:latest
            ghcr.io/${{ github.repository_owner }}/sre-devops-lab:${{ github.sha }}
~~~

说明：push 到 main 自动触发；validate 做测试；image 构建并推送 GHCR；GITHUB_TOKEN 由 GitHub 提供；packages: write 是推送权限。

### 3.8 最小巡检脚本

创建 scripts/cluster-check.sh：

~~~bash
#!/usr/bin/env bash
set -euo pipefail

echo "=== Nodes ==="
kubectl get nodes -o wide

echo "=== Pods ==="
kubectl get pods -A -o wide

echo "=== Deployments ==="
kubectl get deploy -A

echo "=== Recent events ==="
kubectl get events -A --sort-by=.lastTimestamp | tail -20
~~~

完整版运维 CLI 在仓库 scripts/opsctl.py，第一次实践可以先完成部署，再补这个工具。

## 4. 把项目传到 master

在 Windows PowerShell 执行：

~~~powershell
$archive = "C:/Users/qitin/Documents/sre-devops-lab.tar.gz"
tar -czf $archive -C "C:/Users/qitin/Documents" "sre-devops-lab"

scp -i $HOME/.ssh/id_ed25519 $archive root@1.95.123.118:/tmp/sre-devops-lab.tar.gz

ssh -i $HOME/.ssh/id_ed25519 root@1.95.123.118 "scp /tmp/sre-devops-lab.tar.gz root@172.31.6.211:/tmp/sre-devops-lab.tar.gz"

ssh -i $HOME/.ssh/id_ed25519 root@1.95.123.118 "ssh root@172.31.6.211 'mkdir -p /opt && tar -xzf /tmp/sre-devops-lab.tar.gz -C /opt'"
~~~

检查：

~~~powershell
ssh -i $HOME/.ssh/id_ed25519 root@1.95.123.118 "ssh root@172.31.6.211 'find /opt/sre-devops-lab -maxdepth 2 -type f | sort'"
~~~

预期能看到 Dockerfile、app/app.py、k8s/app.yaml、tests/test_app.py。

如果 Windows 没有 tar，可以用 Compress-Archive 生成 zip，再在 master 用 unzip 解压。

## 5. 在 master 上做静态校验

~~~bash
cd /opt/sre-devops-lab
python3 -m py_compile app/app.py tests/test_app.py
kubectl apply --dry-run=client -f k8s/namespace.yaml -f k8s/app.yaml
~~~

预期输出 namespace、deployment、service 的 dry run 成功。dry-run 不会创建真实资源。

## 6. 创建 GitHub 仓库

在 GitHub 创建空仓库 sre-devops-lab，不要勾选自动生成 README、gitignore 或 license。

仓库地址：

~~~text
https://github.com/0tinna/sre-devops-lab.git
~~~

## 7. 生成部署密钥并推送

### 7.1 master 生成专用密钥

~~~bash
ssh-keygen -t ed25519 -C sre-lab-master -f /root/.ssh/github_sre_lab_ed25519 -N ''
chmod 600 /root/.ssh/github_sre_lab_ed25519
cat /root/.ssh/github_sre_lab_ed25519.pub
~~~

复制公钥输出。

### 7.2 GitHub 添加部署密钥

打开：

~~~text
https://github.com/0tinna/sre-devops-lab/settings/keys
~~~

点击 Add deploy key：

- Title：sre-lab-master
- Key：粘贴公钥
- 勾选 Allow write access

### 7.3 配置 Git 并推送

~~~bash
cd /opt/sre-devops-lab
git init -b main
git config user.name 0tinna
git config user.email 0tinna@users.noreply.github.com
git config core.sshCommand 'ssh -i /root/.ssh/github_sre_lab_ed25519 -o IdentitiesOnly=yes'
git add .
git commit -m 'Initial SRE DevOps lab'
git remote add origin git@github.com:0tinna/sre-devops-lab.git
ssh -i /root/.ssh/github_sre_lab_ed25519 -o IdentitiesOnly=yes -T git@github.com
git push -u origin main
~~~

认证成功时会看到：

~~~text
Hi 0tinna/sre-devops-lab! You've successfully authenticated, but GitHub does not provide shell access.
~~~

## 8. 观察 GitHub Actions

打开：

~~~text
https://github.com/0tinna/sre-devops-lab/actions
~~~

应看到 ci workflow：

- validate：安装依赖、编译检查、单元测试
- image：构建并推送 GHCR

如果 image 被跳过，检查是否 push 到 main、是否 Pull Request 事件、workflow 文件是否存在。

构建产物：

~~~text
ghcr.io/0tinna/sre-devops-lab:latest
ghcr.io/0tinna/sre-devops-lab:<commit-sha>
~~~

## 9. 设置 GHCR 可见性

打开：

~~~text
https://github.com/0tinna?tab=packages
~~~

实验环境建议把包设为 Public。私有包需要 imagePullSecret：

~~~bash
kubectl -n sre-lab create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=0tinna \
  --docker-password=<具有 read:packages 权限的 PAT>
~~~

然后在 Deployment 的 Pod 模板加入：

~~~yaml
imagePullSecrets:
  - name: ghcr-secret
~~~

不要把 PAT 写入 Git。

## 10. 部署到 Kubernetes

在 master 执行：

~~~bash
cd /opt/sre-devops-lab
SHA=$(git rev-parse HEAD)
echo $SHA

kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/app.yaml
kubectl -n sre-lab set image deployment/demo-api \
  demo-api=ghcr.io/0tinna/sre-devops-lab:$SHA
kubectl -n sre-lab rollout status deployment/demo-api --timeout=300s
kubectl -n sre-lab get pods -o wide
~~~

预期：rollout successfully，两个 Pod 都是 Running。

如果部署的是文档提交，代码没有变化，可以继续使用上一次验证过的代码 commit SHA，不要为了最新而部署文档提交镜像。

## 11. 验证服务

在 master 开一个终端：

~~~bash
kubectl -n sre-lab port-forward svc/demo-api 18080:80
~~~

另开终端：

~~~bash
curl -i http://127.0.0.1:18080/healthz
curl -i http://127.0.0.1:18080/readyz
curl -s http://127.0.0.1:18080/metrics | head
~~~

预期：healthz 和 readyz 返回 200，metrics 返回 Prometheus 指标。

查看日志：

~~~bash
kubectl -n sre-lab logs deploy/demo-api --tail=50
~~~

## 12. 故障演练

### 12.1 镜像拉取失败

~~~bash
kubectl -n sre-lab set image deployment/demo-api \
  demo-api=ghcr.io/0tinna/sre-devops-lab:missing-tag
kubectl -n sre-lab get pods -w
~~~

另开终端：

~~~bash
kubectl -n sre-lab describe pod <pod-name>
kubectl -n sre-lab get events --sort-by=.lastTimestamp
~~~

观察 ImagePullBackOff 或 ErrImagePull，然后回滚：

~~~bash
kubectl -n sre-lab rollout undo deployment/demo-api
kubectl -n sre-lab rollout status deployment/demo-api --timeout=120s
~~~

### 12.2 Pod 自愈

~~~bash
kubectl -n sre-lab delete pod <pod-name>
kubectl -n sre-lab get pods -w
~~~

### 12.3 应用错误与慢请求

~~~bash
curl -i http://127.0.0.1:18080/simulate/error
curl -i http://127.0.0.1:18080/simulate/slow
~~~

### 12.4 CreateContainerConfigError

如果看到：

~~~text
container has runAsNonRoot and image has non-numeric user (app),
cannot verify user is non-root
~~~

说明镜像的 USER 是用户名而不是数字 UID。修复：

- Dockerfile 使用 USER 10001:10001
- Deployment 设置 runAsUser: 10001
- Deployment 设置 runAsGroup: 10001

这不是镜像拉取失败。排查时先看 Events 中是否出现 Pulled。

## 13. 常见问题

### ImagePullBackOff

~~~bash
kubectl -n sre-lab describe pod <pod-name>
kubectl -n sre-lab get events --sort-by=.lastTimestamp
~~~

可能原因：标签不存在、GHCR 包私有、没有 imagePullSecret、网络或 DNS 不通、镜像架构不匹配。

### CrashLoopBackOff

~~~bash
kubectl -n sre-lab logs <pod-name> --previous
kubectl -n sre-lab describe pod <pod-name>
~~~

### Pending

~~~bash
kubectl -n sre-lab describe pod <pod-name>
kubectl get nodes
kubectl describe node <node-name>
~~~

### GitHub Actions 构建失败

检查 Dockerfile 是否在仓库根目录、app/requirements.txt 和 app/app.py 路径是否正确、workflow 是否有 packages: write、GHCR 包名是否合法、Actions 日志中的具体报错。

### push 被拒绝

检查部署密钥是否勾选 write access、公钥是否添加到正确仓库、git remote -v 是否指向正确地址、是否误用了 force push。

## 14. 清理实验资源

~~~bash
kubectl delete -f k8s/app.yaml
kubectl delete -f k8s/namespace.yaml
kubectl get ns sre-lab
kubectl get pods -A | grep sre-lab
~~~

## 15. 面试表达

可以这样描述：

> 我独立完成了一个两节点 Kubernetes 实验项目。代码提交到 GitHub 后，GitHub Actions 自动执行单元测试并构建镜像，推送到 GHCR；Kubernetes Deployment 使用 commit SHA 作为镜像标签，从 GHCR 拉取并滚动发布。我配置了 readiness/liveness 探针、资源限制和非 root 安全上下文，并用端口转发验证了健康检查和 Prometheus metrics 端点。
>
> 过程中遇到过一次 CreateContainerConfigError，事件显示镜像已经成功拉取，根因是 Dockerfile 使用了非数字 USER app，导致 Kubernetes 无法验证非 root 身份。我改为数字 UID 10001:10001，同时在 Deployment 设置 runAsUser 和 runAsGroup，重新构建并验证 2/2 Pod Running。

常见追问：

- 为什么用 Deployment 而不是裸 Pod
- readiness 和 liveness 的区别
- 为什么使用 commit SHA 标签
- Service 如何找到 Pod
- 滚动更新如何工作
- GitHub Actions 如何登录 GHCR
- ImagePullBackOff 和 CreateContainerConfigError 的区别
- 如何回滚

## 16. 完成清单

- [ ] master 和 node 都是 Ready
- [ ] 本地项目文件创建完成
- [ ] Dockerfile 在仓库根目录
- [ ] Python 语法检查通过
- [ ] Kubernetes YAML dry-run 通过
- [ ] GitHub 空仓库创建完成
- [ ] 部署密钥添加并勾选 write access
- [ ] git push -u origin main 成功
- [ ] GitHub Actions validate 成功
- [ ] GitHub Actions image 成功
- [ ] GHCR 镜像可见
- [ ] Deployment 2/2 Running
- [ ] healthz 和 readyz 返回 200
- [ ] metrics 可访问
- [ ] 完成一次回滚演练
- [ ] 文档记录完整
