# 操作审计记录

记录日期：2026-10-29

执行者：Codex（在用户授权下执行）

## 结论先行

已经执行的操作：

- 通过跳板机只读盘点 master、node 和 Kubernetes 集群。
- 在本地创建项目文件、文档和测试。
- 将项目传输到 master 的 `/opt/sre-devops-lab`。
- 在 master 初始化 Git 仓库并完成多次本地提交。
- 在 master 生成专用 GitHub 部署密钥。
- 配置 Git remote 为 `git@github.com:0tinna/sre-devops-lab.git`。
- 将全部 Markdown 文档改为中文。

尚未执行的操作：

- 没有在 GitHub 添加部署密钥。
- 没有执行 `git push`。
- 没有触发 GitHub Actions。
- 没有生成 GHCR 镜像。
- 没有创建或修改任何 Kubernetes 业务资源。
- 没有安装 Helm、Prometheus、Grafana 或 Alertmanager。
- 没有修改 kube-system、CNI、CoreDNS 或节点配置。

重要说明：本记录中的集群查询均为只读操作。到目前为止，集群业务状态没有被我改变。

## 状态图例

- `[x]`：已经由 Codex 执行。
- `[ ]`：等待用户操作，或等待后续阶段执行。
- `只读`：只查询信息，不改变集群状态。
- `写操作`：创建文件、提交 Git、生成密钥或修改配置。

## 1. 连接与只读盘点

| 序号 | 位置 | 操作 | 结果 | 状态 |
| --- | --- | --- | --- | --- |
| 1 | 本地 Windows | 检查 `ssh` 和 `~/.ssh/id_ed25519` 是否存在 | 密钥存在，SSH 由沙箱包装 | 只读 |
| 2 | 跳板机 1.95.123.118 | 执行 `hostname、whoami、uname -a` | 主机为 `ecs-guizhou-9month-2mbit` | 只读 |
| 3 | 跳板机到 master | 通过跳板机 SSH 到 172.31.6.211 | 主机名为 `master` | 只读 |
| 4 | master | `kubectl get nodes -o wide` | master、node 均为 Ready | 只读 |
| 5 | master | `kubectl get pods -A -o wide` | CoreDNS、etcd、apiserver、controller-manager、scheduler、kube-proxy、Flannel | 只读 |
| 6 | master | `kubectl get deploy,sts,ds,svc,ingress -A` | 只有系统组件，没有业务工作负载 | 只读 |
| 7 | master | `kubectl get pv,pvc -A` 和 `kubectl get sc` | 无存储资源 | 只读 |
| 8 | master | `kubectl get --raw='/readyz?verbose'` | 输出 `readyz check passed` | 只读 |
| 9 | node | 检查 kubelet、containerd、时间同步、内存和磁盘 | kubelet 与 containerd 正常，时间同步正常 | 只读 |

## 2. 资源与网络检查

| 序号 | 位置 | 操作 | 结果 | 状态 |
| --- | --- | --- | --- | --- |
| 10 | master | `nproc、free -h、df -h` | 4 vCPU、15 GiB 内存、178 GiB 磁盘 | 只读 |
| 11 | master | 检查 `kubectl、kubeadm、helm、git、docker、curl` | Helm 未安装，其余工具存在 | 只读 |
| 12 | master | 访问 Docker Hub | 连接超时 | 只读 |
| 13 | master | 访问华为云 SWR 端点 | 端点有响应 | 只读 |
| 14 | master | 使用 `crictl pull` 测试华为云公共镜像路径 | 返回 401 Unauthorized | 只读，未修改集群资源 |
| 15 | master | 检查已存在镜像 | 已有 Flannel、CoreDNS、etcd 和 Kubernetes 系统镜像 | 只读 |

网络结论：Docker Hub 不可达，GHCR 可用，因此项目镜像选择 GHCR。

## 3. 本地项目创建与校验

| 序号 | 位置 | 操作 | 结果 | 状态 |
| --- | --- | --- | --- | --- |
| 16 | 本地 | 创建 `C:\Users\qitin\Documents\sre-devops-lab` | 项目目录存在 | 写操作 |
| 17 | 本地 | 创建 Flask 应用、Dockerfile、K8s 清单、CI、测试和文档 | 文件已生成 | 写操作 |
| 18 | master | 将 Python 文件送到 `/tmp` 并执行 `py_compile` | 语法检查通过 | 写操作，临时文件已删除 |
| 19 | master | 对 K8s YAML 执行 `kubectl apply --dry-run=client` | namespace、deployment、service 均为 dry run 成功 | 只读校验，没有创建资源 |
| 20 | master | 执行 `python3 scripts/opsctl.py --help` | 命令入口正常 | 只读校验 |

## 4. 项目传输与 Git 操作

| 序号 | 位置 | 操作 | 结果 | 状态 |
| --- | --- | --- | --- | --- |
| 21 | 本地到跳板机 | 通过 `scp` 传输项目归档 | 传输成功 | 写操作 |
| 22 | 跳板机到 master | 通过 `scp` 传输项目归档 | 传输成功 | 写操作 |
| 23 | master | 解压到 `/opt/sre-devops-lab` | 项目文件就位 | 写操作 |
| 24 | master | `git init -b main` | 创建 main 分支 | 写操作 |
| 25 | master | 配置 `user.name=0tinna`、`user.email=0tinna@users.noreply.github.com` | 仅作用于当前仓库 | 写操作 |
| 26 | master | 提交 `b7f3cef Initial SRE DevOps lab` | 第一次提交 | 写操作 |
| 27 | master | 添加 remote `git@github.com:0tinna/sre-devops-lab.git` | remote 配置成功 | 写操作 |
| 28 | master | 添加 GitHub 推送 SOP 并提交 `3008335` | 第二次提交 | 写操作 |
| 29 | master | 将文档改为中文并提交 `fe6440f` | 第三次提交，当前 HEAD | 写操作 |

## 5. GitHub 与部署密钥

| 序号 | 位置 | 操作 | 结果 | 状态 |
| --- | --- | --- | --- | --- |
| 30 | master | 执行 `git ls-remote https://github.com/0tinna/sre-devops-lab.git` | 成功，仓库为空 | 只读 |
| 31 | master | 执行 `ssh -T git@github.com` | Permission denied，说明还没有可用 GitHub SSH 权限 | 只读 |
| 32 | master | 生成 `/root/.ssh/github_sre_lab_ed25519` | 私钥和公钥已生成 | 写操作 |
| 33 | GitHub 网页 | 添加 Deploy Key 并勾选 Allow write access | 尚未执行 | 待用户操作 |
| 34 | master | `git push -u origin main` | 尚未执行 | 待执行 |

## 6. 尚未开始的部分

| 项目 | 当前状态 | 说明 |
| --- | --- | --- |
| GitHub Actions 运行 | 待执行 | 需要先完成 push |
| GHCR 镜像 | 未生成 | 依赖 GitHub Actions |
| Kubernetes 业务部署 | 未执行 | 没有创建 `sre-lab` 资源 |
| Prometheus / Grafana | 未安装 | 下一阶段 |
| 告警规则 | 未配置 | 下一阶段 |
| 故障演练 | 未执行 | 下一阶段 |
| 面试项目最终演示 | 未完成 | 需要镜像和监控 |

## 7. 失败与回退记录

| 尝试 | 结果 | 处理方式 |
| --- | --- | --- |
| 本地 SSH 直连 master | master 不信任本地公钥 | 改为通过跳板机转发 |
| 使用 ProxyJump 直连 master | Permission denied | 改为跳板机内执行 SSH |
| 华为云 SWR 公共镜像路径 | 401 Unauthorized | 放弃该路径，改用 GHCR |
| 一次 `opsctl.py` 校验 | 被用户中断 | 后续重新执行并成功 |
| 本地 PowerShell 拼接长命令 | 引号解析失败 | 改用 Base64 脚本或短命令 |
| 本地根目录创建项目 | ACL 拒绝 | 改到 `Documents\sre-devops-lab` |

## 8. 如何复核

在 master 执行：

```bash
cd /opt/sre-devops-lab
git status
git log --oneline --decorate -5
git remote -v
find . -maxdepth 2 -type f | sort
```

查看集群是否仍然只有系统组件：

```bash
kubectl get pods -A
kubectl get deploy -A
kubectl get svc -A
```

确认没有创建业务资源：

```bash
kubectl get namespace sre-lab
```

如果返回 `NotFound`，说明业务命名空间还没有创建，符合当前记录。

## 9. 后续操作约定

从现在开始，SOP 中会明确区分：

- `[x]` 我已经执行的步骤。
- `[ ]` 需要你执行的步骤。
- `只读` 不会改变集群。
- `写操作` 会改变本地文件、Git 仓库或集群状态。

任何会创建 Kubernetes 资源、安装组件、修改权限或推送代码的操作，都会在 SOP 中单独标注，并说明预期结果和回滚方式。
