"""Configuration 12-factor : tout vient des variables d'environnement (aucun secret en dur)."""
import os


def _env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


class Settings:
    def __init__(self) -> None:
        self.database_url = _env("DATABASE_URL") or (
            "postgresql+psycopg2://"
            f"{_env('POSTGRES_USER', 'helpdesk')}:{_env('POSTGRES_PASSWORD')}"
            f"@{_env('POSTGRES_HOST', 'postgres')}:{_env('POSTGRES_PORT', '5432')}"
            f"/{_env('POSTGRES_DB', 'helpdesk')}"
        )
        self.jwt_secret = _env("JWT_SECRET")
        self.jwt_exp_minutes = int(_env("JWT_EXP_MINUTES", "60"))
        self.s3_endpoint = _env("S3_ENDPOINT", "http://minio:9000")
        self.s3_access_key = _env("S3_ACCESS_KEY")
        self.s3_secret_key = _env("S3_SECRET_KEY")
        self.s3_bucket = _env("S3_BUCKET", "helpdesk")
        self.rabbit_host = _env("RABBITMQ_HOST", "rabbitmq")
        self.rabbit_port = int(_env("RABBITMQ_PORT", "5672"))
        self.rabbit_user = _env("RABBITMQ_USER", "helpdesk")
        self.rabbit_password = _env("RABBITMQ_PASSWORD")
        self.queue_name = _env("QUEUE_NAME", "tickets.events")
        self.max_upload_bytes = int(_env("MAX_UPLOAD_BYTES", str(5 * 1024 * 1024)))


def get_settings() -> Settings:
    return Settings()
