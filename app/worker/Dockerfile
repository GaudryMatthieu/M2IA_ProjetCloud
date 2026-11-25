FROM python:3.12-slim AS builder
WORKDIR /w
COPY requirements.txt .
RUN pip install --no-cache-dir --prefix=/install -r requirements.txt

FROM python:3.12-slim
ENV PYTHONUNBUFFERED=1 PYTHONDONTWRITEBYTECODE=1
RUN useradd --system --uid 10001 --no-create-home app
COPY --from=builder /install /usr/local
WORKDIR /srv
COPY worker.py .
USER 10001
EXPOSE 9100
CMD ["python", "worker.py"]
