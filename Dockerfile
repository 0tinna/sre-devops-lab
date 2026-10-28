FROM python:3.12-slim AS builder

WORKDIR /build
COPY app/requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim

ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1

WORKDIR /app
RUN groupadd --system app && useradd --system --gid app app

COPY --from=builder /install /usr/local
COPY app/app.py .

USER app
EXPOSE 8080

CMD gunicorn --bind 0.0.0.0:8080 --workers 2 --threads 2 --access-logfile - app:app
