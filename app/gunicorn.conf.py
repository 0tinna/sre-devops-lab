import os

# prometheus_client 的 multiprocess 模式要求父子进程共享同一个目录。
# gunicorn 的 worker 是 fork 出来的，没有这个配置时每个 worker 各有一份独立计数器，
# /metrics 只会返回命中的那个 worker 的值，Prometheus 侧表现为计数器反复回退（伪 reset），
# rate()/increase() 结果被放大或归零，基于比率的告警永远不会按预期触发。
bind = '0.0.0.0:' + os.getenv('PORT', '8080')
workers = int(os.getenv('GUNICORN_WORKERS', '2'))
threads = int(os.getenv('GUNICORN_THREADS', '2'))
accesslog = '-'
errorlog = '-'
timeout = 30
graceful_timeout = 30


def child_exit(server, worker):
    """worker 退出时清理自己的 mmap 文件，否则残留文件会导致指标重复计数。"""
    if os.getenv('PROMETHEUS_MULTIPROC_DIR'):
        from prometheus_client import multiprocess

        multiprocess.mark_process_dead(worker.pid)
