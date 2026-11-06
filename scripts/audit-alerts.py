#!/usr/bin/env python3
"""审计 Prometheus 告警规则引用的指标是否真实存在。

为什么需要（真实事故，见 docs/6-operation-log.md 19.x）：
    kube-state-metrics 的 --resources 是白名单，排除了 horizontalpodautoscalers
    和 poddisruptionbudgets。于是 HPAMaxedOut / HPAUnableToScale 两条告警
    引用了根本不存在的指标——
        · 规则语法合法
        · /api/v1/rules 里 health=ok
        · 但永远不会触发，因为表达式结果恒为空
    这类"死告警"比没有告警更危险：你以为有人在看着。

用法：
    python3 scripts/audit-alerts.py                      # 用 port-forward 到 prometheus
    python3 scripts/audit-alerts.py --url http://x:9090

退出码：0 全部指标存在；1 存在缺失指标；2 无法连接。
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import urllib.error
import urllib.request

# PromQL 关键字、聚合算子、函数名：不是指标名
PROMQL_WORDS = {
    'and', 'or', 'unless', 'on', 'ignoring', 'group_left', 'group_right',
    'by', 'without', 'bool', 'offset', 'unless',
    'sum', 'min', 'max', 'avg', 'count', 'stddev', 'stdvar', 'topk', 'bottomk',
    'quantile', 'count_values', 'group',
    'rate', 'irate', 'increase', 'delta', 'idelta', 'deriv', 'predict_linear',
    'histogram_quantile', 'histogram_avg', 'histogram_count', 'histogram_sum',
    'abs', 'ceil', 'floor', 'round', 'clamp', 'clamp_min', 'clamp_max',
    'sqrt', 'ln', 'log2', 'log10', 'exp', 'sgn', 'scalar', 'vector',
    'avg_over_time', 'sum_over_time', 'count_over_time', 'min_over_time',
    'max_over_time', 'last_over_time', 'present_over_time', 'stddev_over_time',
    'stdvar_over_time', 'quantile_over_time', 'absent', 'absent_over_time',
    'changes', 'resets', 'time', 'timestamp', 'sort', 'sort_desc', 'sort_by_label',
    'label_replace', 'label_join', 'days_in_month', 'day_of_month', 'day_of_week',
    'hour', 'minute', 'month', 'year', 'pi', 'hour_of_day',
    'nan', 'inf', 'infinity',
}

# 常见标签名：出现在 { } 里的不是指标
COMMON_LABELS = {
    'alertname', 'alertstate', 'severity', 'namespace', 'pod', 'container',
    'node', 'instance', 'job', 'le', 'quantile', 'reason', 'condition',
    'phase', 'resource', 'unit', 'endpoint', 'service', 'daemonset',
    'deployment', 'horizontalpodautoscaler', 'poddisruptionbudget', 'mountpoint',
    'device', 'fstype', 'mode', 'cpu', 'interface', 'code', 'method', 'path',
    'status', 'status_code', 'verb', 'type', 'name', 'owner_name', 'uid',
    'pod_template_hash', 'scheduled', 'image', 'version',
}

# 这些指标只在"事件发生过"时才存在，当前没有对应事件时为空是正常的。
# 不能因为它们缺席就判定告警是死的 —— 但也不能假定它们一定可用，
# 所以单独标注，提示"该告警尚未被实际事件验证过"。
CONDITIONAL_METRICS = {
    'kube_pod_container_status_last_terminated_reason',
    'kube_pod_container_status_terminated_reason',
    'kube_pod_container_status_waiting_reason',
    'kube_pod_status_reason',
    'kube_pod_container_status_last_terminated_exitcode',
}

IDENT = re.compile(r'[a-zA-Z_][a-zA-Z0-9_]*')


def fetch(url: str, path: str) -> dict:
    with urllib.request.urlopen(url.rstrip('/') + path, timeout=30) as resp:
        return json.load(resp)


def strip_strings(expr: str) -> str:
    """把双引号字符串内容挖掉，避免把 label 值当成指标名。"""
    return re.sub(r'"(?:[^"\\]|\\.)*"', '""', expr)


def extract_identifiers(expr: str) -> set[str]:
    """从表达式里提取可能的指标名。

    策略：去掉字符串字面量后，找出紧邻 '{' 的标识符（确定是指标），
    以及所有裸标识符（可能是指标，也可能是关键字）。
    只返回"看起来像指标"的：含下划线，或长度 > 3。
    """
    cleaned = strip_strings(expr)
    found: set[str] = set()

    # 明确形式：metric{...}
    for m in re.finditer(r'([a-zA-Z_][a-zA-Z0-9_]*)\s*\{', cleaned):
        found.add(m.group(1))

    # 裸标识符：包含下划线的更可能是指标名
    for m in IDENT.finditer(cleaned):
        token = m.group(0)
        if token in PROMQL_WORDS or token in COMMON_LABELS:
            continue
        if '_' in token or len(token) > 3:
            found.add(token)

    return found


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument('--url', default='http://127.0.0.1:19090',
                    help='Prometheus base URL (default: port-forward 19090)')
    args = ap.parse_args()

    try:
        rules = fetch(args.url, '/api/v1/rules')
        names = fetch(args.url, '/api/v1/label/__name__/values')
    except (urllib.error.URLError, TimeoutError, OSError) as exc:
        print(f'无法连接 {args.url}: {exc}', file=sys.stderr)
        print('提示：先 kubectl -n monitoring port-forward svc/prometheus 19090:9090', file=sys.stderr)
        return 2

    known = set(names['data'])
    groups = rules['data']['groups']

    print(f'=== 告警指标审计 ===')
    print(f'Prometheus 中可用指标: {len(known)} 个')
    print(f'规则组: {len(groups)} 个，规则: {sum(len(g["rules"]) for g in groups)} 条')
    print()

    total_missing = 0
    total_conditional = 0
    total_alerts = 0

    for g in groups:
        print(f'[{g["name"]}]')
        for r in g['rules']:
            if r.get('type') != 'alerting':
                continue
            total_alerts += 1
            expr = r.get('query', '')
            idents = extract_identifiers(expr)

            # 只关心"确实是指标但不存在"的：优先看 metric{ 形式
            explicit = {m.group(1) for m in re.finditer(r'([a-zA-Z_][a-zA-Z0-9_]*)\s*\{', strip_strings(expr))}
            missing = sorted(x for x in explicit if x not in known)
            conditional = [x for x in missing if x in CONDITIONAL_METRICS]
            real_missing = [x for x in missing if x not in CONDITIONAL_METRICS]

            # 裸标识符里的缺失项，作为"疑似"提示（可能有函数/变量误报）
            suspicious = sorted(
                x for x in idents
                if x not in explicit and x not in known
                and x not in PROMQL_WORDS and x not in COMMON_LABELS
                and '_' in x
            )

            health = r.get('health', '?')
            if real_missing:
                total_missing += 1
                print(f'  ✗ {r["name"]:<28} health={health}  缺失指标: {", ".join(real_missing)}')
            elif conditional:
                total_conditional += 1
                print(f'  ~ {r["name"]:<28} health={health}  条件性指标当前无事件: {", ".join(conditional)}')
            else:
                print(f'  ✓ {r["name"]:<28} health={health}')
            if suspicious:
                print(f'      疑似未知标识符: {", ".join(suspicious[:5])}')

        print()

    print('=' * 60)
    if total_missing:
        print(f'结果: {total_missing}/{total_alerts} 条告警引用了不存在的指标 —— 这些告警永远不会触发')
        return 1
    if total_conditional:
        print(f'结果: {total_alerts} 条告警语法与指标均正常；'
              f'其中 {total_conditional} 条依赖条件性指标，尚未被真实事件验证')
        return 0
    print(f'结果: {total_alerts} 条告警引用的指标全部存在且非条件性')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())