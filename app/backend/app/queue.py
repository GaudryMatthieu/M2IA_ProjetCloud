"""Publication d'événements dans RabbitMQ (traitement asynchrone, consommé par le worker)."""
import json
import logging

import pika

from .config import get_settings
from .metrics import EVENTS_PUBLISHED

log = logging.getLogger("queue")

DLQ_SUFFIX = ".dlq"


def declare_queues(channel, name: str) -> None:
    channel.queue_declare(queue=name + DLQ_SUFFIX, durable=True)
    channel.queue_declare(
        queue=name,
        durable=True,
        arguments={"x-dead-letter-exchange": "", "x-dead-letter-routing-key": name + DLQ_SUFFIX},
    )


class Publisher:
    def publish(self, event: str, payload: dict) -> bool:
        s = get_settings()
        body = json.dumps({"event": event, **payload})
        try:
            params = pika.ConnectionParameters(
                host=s.rabbit_host,
                port=s.rabbit_port,
                credentials=pika.PlainCredentials(s.rabbit_user, s.rabbit_password),
                socket_timeout=3,
                blocked_connection_timeout=3,
            )
            conn = pika.BlockingConnection(params)
            try:
                ch = conn.channel()
                declare_queues(ch, s.queue_name)
                ch.basic_publish(
                    exchange="",
                    routing_key=s.queue_name,
                    body=body,
                    properties=pika.BasicProperties(delivery_mode=2, content_type="application/json"),
                )
            finally:
                conn.close()
            EVENTS_PUBLISHED.labels(event, "ok").inc()
            return True
        except Exception as exc:  # noqa: BLE001 — la création de ticket ne doit pas échouer si la file est KO
            EVENTS_PUBLISHED.labels(event, "error").inc()
            log.error("Publication impossible (%s): %s", event, exc)
            return False


def get_publisher() -> Publisher:
    return Publisher()
