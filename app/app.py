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
