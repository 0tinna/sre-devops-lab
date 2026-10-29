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
