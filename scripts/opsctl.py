#!/usr/bin/env python3
import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def kubectl(*args, check=True):
    result = subprocess.run(
        ['kubectl', *args],
        text=True,
        capture_output=True,
        check=False,
    )
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or result.stdout.strip())
    return result


def print_section(title, result):
    print(f'## {title}')
    output = (result.stdout or result.stderr).strip()
    print(output if output else '(empty)')
    print()


def inventory(args):
    print('# Cluster inventory')
    print(f'Generated: {datetime.now(timezone.utc).isoformat()}')
    print()
    commands = [
        ('Nodes', ('get', 'nodes', '-o', 'wide')),
        ('Namespaces', ('get', 'namespaces')),
        ('Pods', ('get', 'pods', '-A', '-o', 'wide')),
        ('Workloads', ('get', 'deploy,sts,ds', '-A')),
        ('Services', ('get', 'svc,ingress', '-A')),
        ('Recent events', ('get', 'events', '-A', '--sort-by=.lastTimestamp')),
    ]
    for title, cmd in commands:
        print_section(title, kubectl(*cmd, check=False))


def health(args):
    issues = []
    nodes = json.loads(kubectl('get', 'nodes', '-o', 'json').stdout)
    for node in nodes.get('items', []):
        name = node['metadata']['name']
        ready = next((c for c in node['status'].get('conditions', []) if c['type'] == 'Ready'), None)
        if not ready or ready['status'] != 'True':
            issues.append(f'node {name} is not Ready')

    pods = json.loads(kubectl('get', 'pods', '-A', '-o', 'json').stdout)
    for pod in pods.get('items', []):
        name = pod['metadata']['name']
        namespace = pod['metadata']['namespace']
        # 正在删除的 Pod 不计入判定：滚动更新、回滚、缩容期间它们必然处于
        # Terminating 且 phase 可能是 Pending/Unknown，报出来只是噪音。
        # 判定依据是 deletionTimestamp，而不是 phase。
        if pod['metadata'].get('deletionTimestamp'):
            continue
        phase = pod['status'].get('phase')
        if phase not in ('Running', 'Succeeded'):
            issues.append(f'pod {namespace}/{name} is {phase}')
        restarts = sum(cs.get('restartCount', 0) for cs in pod['status'].get('containerStatuses', []))
        if restarts >= 3:
            issues.append(f'pod {namespace}/{name} restarted {restarts} times')

    deployments = json.loads(kubectl('get', 'deploy', '-A', '-o', 'json').stdout)
    for dep in deployments.get('items', []):
        name = dep['metadata']['name']
        namespace = dep['metadata']['namespace']
        desired = dep['spec'].get('replicas', 0)
        available = dep['status'].get('availableReplicas', 0)
        if available < desired:
            issues.append(f'deployment {namespace}/{name} has {available}/{desired} replicas')
    if issues:
        print('NOT OK')
        for issue in issues:
            print(f'- {issue}')
        return 1
    print('OK: all nodes Ready, pods running, deployments available')
    return 0


def collect_logs(args):
    stamp = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%SZ')
    outdir = Path(args.output_dir) / f'{stamp}-{args.pod}'
    outdir.mkdir(parents=True, exist_ok=True)
    commands = {
        'describe.txt': ('describe', 'pod', args.pod, '-n', args.namespace),
        'logs.txt': ('logs', args.pod, '-n', args.namespace, '--all-containers=true', '--tail', str(args.tail)),
        'events.txt': ('get', 'events', '-n', args.namespace, '--sort-by=.lastTimestamp'),
        'pod.json': ('get', 'pod', args.pod, '-n', args.namespace, '-o', 'json'),
    }
    for filename, cmd in commands.items():
        result = kubectl(*cmd, check=False)
        (outdir / filename).write_text(result.stdout + result.stderr, encoding='utf-8')
    print(f'Collected logs in {outdir}')
    return 0


def deploy(args):
    kubectl('set', 'image', f'deployment/{args.deployment}', f'{args.deployment}={args.image}', '-n', args.namespace)
    result = kubectl('rollout', 'status', f'deployment/{args.deployment}', '-n', args.namespace, '--timeout', args.timeout, check=False)
    print(result.stdout.strip())
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
    return result.returncode


def rollback(args):
    kubectl('rollout', 'undo', f'deployment/{args.deployment}', '-n', args.namespace)
    result = kubectl('rollout', 'status', f'deployment/{args.deployment}', '-n', args.namespace, '--timeout', args.timeout, check=False)
    print(result.stdout.strip())
    if result.returncode != 0:
        print(result.stderr.strip(), file=sys.stderr)
    return result.returncode


def monitoring(args):
    """检查监控栈自身健康度与当前告警。

    刻意不走 Prometheus HTTP API：那需要 port-forward 或额外网络暴露。
    这里直接读 Kubernetes 对象与 Pod 日志里的规则状态，够用且不依赖额外端口。
    需要看具体指标时用 `monitoring --query '<PromQL>'`，它会临时起一个 port-forward。
    """
    issues = []

    pods = json.loads(
        kubectl('get', 'pods', '-n', args.monitoring_namespace, '-l',
                'app.kubernetes.io/part-of=sre-devops-lab', '-o', 'json').stdout
    )
    ready = 0
    for pod in pods.get('items', []):
        name = pod['metadata']['name']
        conditions = pod['status'].get('conditions', [])
        is_ready = next((c for c in conditions if c['type'] == 'Ready'), None)
        if not is_ready or is_ready['status'] != 'True':
            issues.append(f'monitoring pod {name} is not Ready')
        else:
            ready += 1
    print(f'## Monitoring pods: {ready}/{len(pods.get("items", []))} Ready')

    if args.query:
        result = kubectl(
            'get', '--raw',
            f'/api/v1/namespaces/{args.monitoring_namespace}/services/{args.service}:{args.port}/proxy/api/v1/query?query={args.query}',
            check=False,
        )
        print(f'## Query: {args.query}')
        if result.returncode == 0:
            print(result.stdout.strip()[:4000])
        else:
            issues.append(f'query failed: {(result.stderr or result.stdout).strip()[:300]}')
            print(result.stderr.strip()[:1000])
        print()

    if issues:
        print('NOT OK')
        for issue in issues:
            print(f'- {issue}')
        return 1
    print('OK: monitoring stack Ready')
    return 0


def main():
    parser = argparse.ArgumentParser(description='Small SRE operations CLI for the demo cluster')
    sub = parser.add_subparsers(dest='command', required=True)

    p = sub.add_parser('inventory', help='print a cluster inventory')
    p.set_defaults(func=inventory)

    p = sub.add_parser('health', help='check nodes, pods and deployments')
    p.set_defaults(func=health)

    p = sub.add_parser('logs', help='collect pod diagnostics')
    p.add_argument('pod')
    p.add_argument('--namespace', default='sre-lab')
    p.add_argument('--tail', type=int, default=200)
    p.add_argument('--output-dir', default='logs')
    p.set_defaults(func=collect_logs)

    p = sub.add_parser('deploy', help='set a new image and wait for rollout')
    p.add_argument('image')
    p.add_argument('--namespace', default='sre-lab')
    p.add_argument('--deployment', default='demo-api')
    p.add_argument('--timeout', default='120s')
    p.set_defaults(func=deploy)

    p = sub.add_parser('rollback', help='rollback the last deployment')
    p.add_argument('--namespace', default='sre-lab')
    p.add_argument('--deployment', default='demo-api')
    p.add_argument('--timeout', default='120s')
    p.set_defaults(func=rollback)

    p = sub.add_parser('monitoring', help='check the monitoring stack and optionally run a PromQL query')
    p.add_argument('--monitoring-namespace', default='monitoring')
    p.add_argument('--service', default='prometheus')
    p.add_argument('--port', default='9090')
    p.add_argument('--query', help="PromQL, executed through the apiserver service proxy")
    p.set_defaults(func=monitoring)

    args = parser.parse_args()
    try:
        return args.func(args)
    except RuntimeError as exc:
        print(f'ERROR: {exc}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
