# 文档导航

按**使用场景**选择入口。如果你是第一次接手这个项目，从「第一天」那份开始读。

## 学习路径（推荐顺序）

| 顺序 | 文档 | 用途 | 阅读时间 |
| --- | --- | --- | --- |
| 1 | [从 0 到 1 实践手册](manual-from-zero-to-one.md) | 这个项目是怎么从零搭起来的，含每一步的命令和判断 | 40 分钟 |
| 2 | [故障排查 SOP · 学习路径版](troubleshooting-sop.md) | **9 节课**，把踩过的坑变成可复用流程 | 60 分钟 |
| 3 | [监控与故障演练手册](monitoring-runbook.md) | 监控怎么访问、10 条告警、D1–D8 演练步骤 | 30 分钟 |
| 4 | [下一阶段计划](next-phase-plan.md) | 还没做完的部分，含优先级和验收标准 | 15 分钟 |
| 5 | [集群盘点](cluster-inventory.md) | 硬件、网络、已装组件的事实基线 | 10 分钟 |
| 6 | [操作审计](operation-log.md) | 每个动作的时间线和执行者，用于复核 | 按需查阅 |

## 按角色

**准备面试** → [从 0 到 1](manual-from-zero-to-one.md) 建立叙事 →
[SOP 第 6、7 课](troubleshooting-sop.md#第-6-课--指标正确性) 准备"最有含金量的故障故事" →
[操作审计](operation-log.md) 确认时间线能对得上。

**接手运维** → [集群盘点](cluster-inventory.md) 摸清环境 →
[监控手册](monitoring-runbook.md) 拿到访问方式和告警清单 →
[推送 SOP](github-push-sop.md) 配好凭证。

**排查故障** → [SOP 附录 B 速查索引](troubleshooting-sop.md#附录-b--问题速查索引)
按症状关键词找到对应课，再跳进去看诊断命令。

**继续开发** → [下一阶段计划](next-phase-plan.md) 拿任务清单 →
[监控手册](monitoring-runbook.md) 的演练部分拿验证方法。

## SOP 九课速查

| 课 | 主题 | 能解决什么 |
| --- | --- | --- |
| 1 | 打通作业通道 | 跨跳板机传文件、命令太长、权限拒绝 |
| 2 | 镜像供应链 | `ImagePullBackOff` 四类根因 |
| 3 | 容器启动与安全上下文 | `CreateContainerConfigError`、非数字 UID |
| 4 | 调度与容量规划 | `Pending`、taint、监控栈放哪 |
| 5 | 探针与就绪语义 | `Running` 但永远 `NotReady` |
| 6 | 指标正确性 | 告警永不触发、`rate()` 失真 |
| 7 | 告警表达式设计 | 错误率被探针稀释 |
| 8 | 告警生命周期 | 告警长时间不消解 |
| 9 | 变更校验流程 | dry-run 级别选错 |

## 文档维护约定

- 每个问题的结论都要**写回代码注释**，不只写在文档里。
  例：`k8s/monitoring/30-exporters.yaml` 里记录了探针端点分布。
- 新问题先追加到 [操作审计](operation-log.md)，稳定后提炼进 [SOP](troubleshooting-sop.md)。
- 所有数字（容量、耗时、阈值）必须是**实测值**，不写"大约"。
- 文档里的命令都要能直接复制执行，不写伪代码。
