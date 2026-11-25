"""Worker asynchrone : consomme la file RabbitMQ.

 - ticket.created   -> "envoie" une notification (simulée par un log JSON) puis marque le ticket notifié
 - export.requested -> génère un CSV des tickets et le dépose dans le stockage objet
"""
import csv
import io
import json
import logging
import os
import sys
import time

import boto3
import pika
from botocore.client import Config
from prometheus_client import Counter, Histogram, start_http_server
from sqlalchemy import create_engine, text

JOBS = Counter("worker_jobs_total", "Jobs traités", ["event", "result"])
JOB_TIME = Histogram("worker_job_duration_seconds", "Durée des jobs", ["event"])
log = logging.getLogger("worker")


class JsonFormatter(logging.Formatter):
    def format(self, record):
        d = {"ts": time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(record.created)),
             "level": record.levelname, "logger": record.name, "msg": record.getMessage()}
        d.update(getattr(record, "fields", {}) or {})
        return json.dumps(d, ensure_ascii=False)


def env(name, default=""):
    return os.environ.get(name, default)


def database_url():
    return env("DATABASE_URL") or (
        f"postgresql+psycopg2://{env('POSTGRES_USER', 'helpdesk')}:{env('POSTGRES_PASSWORD')}"
        f"@{env('POSTGRES_HOST', 'postgres')}:{env('POSTGRES_PORT', '5432')}/{env('POSTGRES_DB', 'helpdesk')}"
    )


def make_s3():
    return boto3.client(
        "s3", endpoint_url=env("S3_ENDPOINT", "http://minio:9000"),
        aws_access_key_id=env("S3_ACCESS_KEY"), aws_secret_access_key=env("S3_SECRET_KEY"),
        region_name="us-east-1", config=Config(signature_version="s3v4", s3={"addressing_style": "path"}),
    )


def handle_event(event: dict, engine, s3, bucket: str) -> None:
    kind = event.get("event")
    if kind == "ticket.created":
        log.info("notification envoyée", extra={"fields": {
            "to": event.get("requester_email"), "ticket_id": event["ticket_id"], "title": event.get("title")}})
        with engine.begin() as conn:
            conn.execute(text("UPDATE tickets SET notified = :n WHERE id = :i"), {"n": True, "i": event["ticket_id"]})
    elif kind == "export.requested":
        with engine.connect() as conn:
            rows = conn.execute(text(
                "SELECT id, title, status, requester_id, created_at FROM tickets ORDER BY id")).all()
        buf = io.StringIO()
        w = csv.writer(buf)
        w.writerow(["id", "title", "status", "requester_id", "created_at"])
        w.writerows(rows)
        key = f"exports/{event['export_id']}.csv"
        s3.put_object(Bucket=bucket, Key=key, Body=buf.getvalue().encode(), ContentType="text/csv")
        log.info("export généré", extra={"fields": {"key": key, "rows": len(rows)}})
    else:
        raise ValueError(f"événement inconnu: {kind}")


def declare(channel, name):
    channel.queue_declare(queue=name + ".dlq", durable=True)
    channel.queue_declare(queue=name, durable=True, arguments={
        "x-dead-letter-exchange": "", "x-dead-letter-routing-key": name + ".dlq"})


def connect_rabbit():
    params = pika.ConnectionParameters(
        host=env("RABBITMQ_HOST", "rabbitmq"), port=int(env("RABBITMQ_PORT", "5672")),
        credentials=pika.PlainCredentials(env("RABBITMQ_USER", "helpdesk"), env("RABBITMQ_PASSWORD")),
        heartbeat=30)
    while True:
        try:
            return pika.BlockingConnection(params)
        except Exception as exc:  # noqa: BLE001
            log.warning("RabbitMQ indisponible, nouvel essai: %s", exc)
            time.sleep(3)


def main():
    h = logging.StreamHandler(sys.stdout)
    h.setFormatter(JsonFormatter())
    logging.basicConfig(level=logging.INFO, handlers=[h])
    start_http_server(int(env("METRICS_PORT", "9100")))
    engine = create_engine(database_url(), pool_pre_ping=True)
    s3, bucket, queue = make_s3(), env("S3_BUCKET", "helpdesk"), env("QUEUE_NAME", "tickets.events")

    while True:  # boucle de reconnexion : le pod ne crashe pas si RabbitMQ redémarre
        conn = connect_rabbit()
        ch = conn.channel()
        declare(ch, queue)
        ch.basic_qos(prefetch_count=1)

        def on_message(channel, method, _props, body):
            kind = "unknown"
            try:
                event = json.loads(body)
                kind = event.get("event", "unknown")
                with JOB_TIME.labels(kind).time():
                    handle_event(event, engine, s3, bucket)
                JOBS.labels(kind, "ok").inc()
                channel.basic_ack(method.delivery_tag)
            except Exception as exc:  # noqa: BLE001
                JOBS.labels(kind, "error").inc()
                log.error("échec job -> DLQ: %s", exc)
                channel.basic_nack(method.delivery_tag, requeue=False)

        ch.basic_consume(queue=queue, on_message_callback=on_message)
        log.info("worker prêt", extra={"fields": {"queue": queue}})
        try:
            ch.start_consuming()
        except Exception as exc:  # noqa: BLE001
            log.warning("connexion perdue: %s", exc)
            time.sleep(3)


if __name__ == "__main__":
    main()
