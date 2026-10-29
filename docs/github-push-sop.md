# GitHub 推送 SOP

仓库地址：https://github.com/0tinna/sre-devops-lab

master 工作目录：`/opt/sre-devops-lab`

部署密钥私钥路径：`/root/.ssh/github_sre_lab_ed25519`

私钥只保留在 master 节点。下面的公钥可以安全地粘贴到 GitHub。

## 当前执行进度

| 步骤 | 状态 | 执行者 | 说明 |
| --- | --- | --- | --- |
| 项目文件生成 | [x] | Codex | 已生成应用、Dockerfile、K8s 清单、CI、测试和文档 |
| 项目传输到 master | [x] | Codex | 已解压到 `/opt/sre-devops-lab` |
| Git 初始化与提交 | [x] | Codex | 当前 HEAD 为 `03bea91` |
| Git remote 配置 | [x] | Codex | 指向 `git@github.com:0tinna/sre-devops-lab.git` |
| 部署密钥生成 | [x] | Codex | 私钥在 master，公钥在第 1 节 |
| GitHub 添加部署密钥 | [x] | 用户 | 已完成，Allow write access 已勾选 |
| 首次 push | [x] | 用户 | origin/main = `03bea91` |
| GitHub Actions | [x] | GitHub | run 40799208887，结论 success |
| GHCR 镜像 | [x] | GitHub Actions | 已生成并已被节点拉取 |
| Kubernetes 部署 | [x] | 用户 | 资源已创建，但 Pod 处于 CreateContainerConfigError |
| 镜像数字 UID 修复 | [ ] | Codex | 待提交新 Dockerfile 和 K8s 配置 |
| Prometheus / Grafana | [ ] | Codex | 后续阶段 |

## 1. 添加具有写权限的部署密钥

1. 打开 https://github.com/0tinna/sre-devops-lab/settings/keys
2. 点击 `Add deploy key`。
3. Title 填写：`sre-lab-master`
4. Key 填入：

```text
ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAINGBoz2mz3enY7/WJwWQ5WdQs3ZwlLQJD2yWdWRKBbXk sre-lab-master
```

5. 勾选 `Allow write access`。
6. 点击 `Add key`。

如果没有勾选写权限，`git push` 会失败，常见报错是 `Permission denied (publickey)` 或只读权限错误。

## 2. 在 master 上验证认证

在 master 执行：

```bash
ssh -i /root/.ssh/github_sre_lab_ed25519 -o IdentitiesOnly=yes -T git@github.com
```

预期输出类似：

```text
Hi 0tinna/sre-devops-lab! You've successfully authenticated, but GitHub does not provide shell access.
```

常见失败：

- `Permission denied (publickey)`：公钥没有添加、添加了错误的公钥，或者没有勾选写权限。
- `Repository not found`：检查仓库地址，以及部署密钥是否添加到了正确仓库。

## 3. 推送第一个提交

master 上已经完成仓库初始化、提交和远程配置：

```bash
cd /opt/sre-devops-lab
git status
git push -u origin main  # 这是push推送命令，首次需要-u永久指定分支main
```

预期结果：

```text
branch 'main' set up to track 'origin/main'
```

如果远程已经有提交，不要直接使用 `git push --force`。先检查：

```bash
git ls-remote origin
git log --oneline --decorate -3
```

如果远程有 README 等初始提交，应使用普通 merge 或 rebase，而不是强制推送。

## 4. 检查 GitHub Actions

1. 打开 https://github.com/0tinna/sre-devops-lab/actions
2. 打开 `ci` workflow。
3. 确认 `validate` job 通过。
4. 确认推送到 `main` 后 `image` job 通过。
5. 在 GitHub Packages 中确认镜像已生成。

流水线会发布：

```text
ghcr.io/0tinna/sre-devops-lab:latest
ghcr.io/0tinna/sre-devops-lab:<commit-sha>
```

Pull Request 不会执行镜像发布 job，这是有意设计的。

## 5. 让集群可以拉取镜像

实验环境最简单的方式是把 GHCR 包设为公开：

1. 打开包页面。
2. 进入 `Package settings`。
3. 将可见性改为 `Public`。

如果必须使用私有包，则创建 imagePullSecret：

```bash
kubectl -n sre-lab create secret docker-registry ghcr-secret \
  --docker-server=ghcr.io \
  --docker-username=0tinna \
  --docker-password=<具有 read:packages 权限的 PAT>
```

然后在 Deployment 的 Pod 模板中加入：

```yaml
imagePullSecrets:
  - name: ghcr-secret
```

不要把 PAT 提交到 Git。

## 6. 镜像生成后部署

在 master 执行：

```bash
cd /opt/sre-devops-lab
kubectl apply -f k8s/namespace.yaml
kubectl apply -f k8s/app.yaml
kubectl -n sre-lab set image deployment/demo-api \
  demo-api=ghcr.io/0tinna/sre-devops-lab:03bea9199c5c9674684af0ee5cbb1f694ed2ece6
# rollout status deployment/demo-api 检查deployment这个有状态负载是否正常更新滚动
kubectl -n sre-lab rollout status deployment/demo-api --timeout=120s
kubectl -n sre-lab get pods -o wide
```

验证服务：

```bash
kubectl -n sre-lab port-forward svc/demo-api 8080:80
curl -i http://127.0.0.1:8080/healthz
curl -i http://127.0.0.1:8080/readyz
curl -s http://127.0.0.1:8080/metrics | head
```

## 7. 排查清单

### ImagePullBackOff

```bash
kubectl -n sre-lab get pods
kubectl -n sre-lab describe pod <pod-name>
kubectl -n sre-lab get events --sort-by=.lastTimestamp
```

检查镜像名、标签、包可见性、仓库认证、DNS 和网络。

### 发布后一直不 Ready

```bash
kubectl -n sre-lab get deploy demo-api -o yaml
kubectl -n sre-lab get rs
kubectl -n sre-lab describe pod <pod-name>
kubectl -n sre-lab logs deploy/demo-api --tail=100
```

检查 readiness 探针、资源限制和应用启动日志。

### 回滚

```bash
kubectl -n sre-lab rollout undo deployment/demo-api
kubectl -n sre-lab rollout status deployment/demo-api --timeout=120s
```

## 8. 面试表述

我使用仓库级 SSH 部署密钥，而不是个人账号密码。私钥只保留在 master 节点，公钥添加为 GitHub 仓库的写权限部署密钥。首次推送会触发 GitHub Actions，完成代码校验和单元测试，并把 commit SHA 作为镜像标签发布到 GHCR。Kubernetes Deployment 引用该 commit SHA，部署后我检查 rollout 状态、Pod 健康和 metrics 端点。
