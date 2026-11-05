FROM python:3.12-slim AS builder

WORKDIR /build
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt


FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

WORKDIR /app
RUN groupadd --gid 10001 app && useradd --uid 10001 --gid app --no-create-home --shell /usr/sbin/nologin app

COPY --from=builder /install /usr/local
COPY app/app.py app/gunicorn.conf.py ./

# prometheus_client multiprocess 目录：多 worker 共享计数器的前提
RUN mkdir -p /tmp/prometheus-multiproc && chown 10001:10001 /tmp/prometheus-multiproc
ENV PROMETHEUS_MULTIPROC_DIR=/tmp/prometheus-multiproc

USER 10001:10001
EXPOSE 8080

# 启动前清空 multiprocess 目录：容器重启后 emptyDir 里的旧 mmap 文件会被重复统计
CMD ["sh", "-c", "rm -rf \"$PROMETHEUS_MULTIPROC_DIR\"/* 2>/dev/null; exec gunicorn -c gunicorn.conf.py app:app"]
