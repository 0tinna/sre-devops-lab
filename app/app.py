import logging
import os
import random
import time

from flask import Flask, Response, g, jsonify, request
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    REGISTRY,
    CollectorRegistry,
    Counter,
    Histogram,
    generate_latest,
    multiprocess,
)


# 日志必须打到 stdout，容器运行时才能被 Fluent Bit 从 /var/log/containers 采到。
logging.basicConfig(
    level=os.getenv('LOG_LEVEL', 'INFO').upper(),
    format='%(asctime)s %(levelname)s %(name)s %(message)s',
    stream=__import__('sys').stdout,
)
logger = logging.getLogger('demo-api')


app = Flask(__name__)

# multiprocess 模式：gunicorn 多 worker 时必须启用，否则各 worker 的计数器互相覆盖。
# 由 Deployment 提供 PROMETHEUS_MULTIPROC_DIR 与一个可写的 emptyDir。
_MULTIPROC_DIR = os.getenv('PROMETHEUS_MULTIPROC_DIR')


def _metrics_registry():
    if not _MULTIPROC_DIR:
        return REGISTRY
    registry = CollectorRegistry()
    multiprocess.MultiProcessCollector(registry)
    return registry


METRICS_REGISTRY = _metrics_registry()

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


FAULT_ENDPOINTS_ENABLED = os.getenv('ENABLE_FAULT_ENDPOINTS', '0') == '1'


def _fault_disabled():
    return jsonify(error='fault endpoints disabled', hint='set ENABLE_FAULT_ENDPOINTS=1'), 404


@app.get('/simulate/error')
def simulate_error():
    if not FAULT_ENDPOINTS_ENABLED:
        return _fault_disabled()
    return jsonify(error='simulated failure'), 500


@app.get('/simulate/slow')
def simulate_slow():
    if not FAULT_ENDPOINTS_ENABLED:
        return _fault_disabled()
    time.sleep(2)
    return jsonify(status='slow response')


@app.get('/simulate/memory')
def simulate_memory():
    """受控内存分配，用于演练 OOMKilled 与 container_memory 告警。

    默认关闭：只有显式设置 ENABLE_FAULT_ENDPOINTS=1 才可用，避免误触发生产式故障。
    参数：mib=每次分配总量，hold=保持秒数。
    """
    if not FAULT_ENDPOINTS_ENABLED:
        return _fault_disabled()
    mib = int(request.args.get('mib', '64'))
    hold = int(request.args.get('hold', '30'))
    block = b'x' * (1024 * 1024)
    chunks = [block for _ in range(max(mib, 0))]
    time.sleep(max(hold, 0))
    return jsonify(allocated_mib=len(chunks), held_seconds=max(hold, 0))


@app.get('/simulate/degraded')
def simulate_degraded():
    """受控"静默降级"：依赖失败被捕获，仍返回 HTTP 200，但日志里有 ERROR。

    这是最容易被监控漏掉的一类故障：
      - HTTP 状态码 200，指标全绿
      - 告警不会触发
      - 只有日志能看出"其实是降级返回的"
    """
    if not FAULT_ENDPOINTS_ENABLED:
        return _fault_disabled()
    upstream = request.args.get('upstream', 'inventory-service')
    latency = random.uniform(2.0, 3.5)
    try:
        # 模拟下游依赖超时
        raise TimeoutError(f'{upstream} did not respond within {latency:.1f}s')
    except TimeoutError as exc:
        logger.error('downstream call failed, serving stale cache: %s', exc)
    return jsonify(
        status='degraded',
        source='stale-cache',
        upstream=upstream,
        note='response served from cache because upstream is unavailable',
    )


@app.get('/metrics')
def metrics():
    return Response(generate_latest(METRICS_REGISTRY), mimetype=CONTENT_TYPE_LATEST)


if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int(os.getenv('PORT', '8080')))
