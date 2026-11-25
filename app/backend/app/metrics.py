from prometheus_client import Counter, Histogram

HTTP_REQUESTS = Counter("http_requests_total", "Requêtes HTTP", ["method", "path", "status"])
HTTP_LATENCY = Histogram(
    "http_request_duration_seconds",
    "Latence des requêtes HTTP",
    ["method", "path"],
    buckets=(0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5),
)
EVENTS_PUBLISHED = Counter("events_published_total", "Événements publiés dans la file", ["event", "result"])
