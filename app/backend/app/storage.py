"""Stockage objet via l'API S3 (MinIO en local ; un vrai bucket cloud S3 en changeant 4 variables)."""
import logging
from typing import Iterator

import boto3
from botocore.client import Config
from botocore.exceptions import ClientError

from .config import get_settings

log = logging.getLogger("storage")


class S3Storage:
    def __init__(self) -> None:
        s = get_settings()
        self.bucket = s.s3_bucket
        self.client = boto3.client(
            "s3",
            endpoint_url=s.s3_endpoint,
            aws_access_key_id=s.s3_access_key,
            aws_secret_access_key=s.s3_secret_key,
            region_name="us-east-1",
            config=Config(signature_version="s3v4", s3={"addressing_style": "path"}, retries={"max_attempts": 3}),
        )

    def ensure_bucket(self) -> None:
        try:
            self.client.head_bucket(Bucket=self.bucket)
        except ClientError:
            self.client.create_bucket(Bucket=self.bucket)
        try:  # chiffrement au repos (SSE-S3) — A.8.24 ; non bloquant si KMS non configuré
            self.client.put_bucket_encryption(
                Bucket=self.bucket,
                ServerSideEncryptionConfiguration={
                    "Rules": [{"ApplyServerSideEncryptionByDefault": {"SSEAlgorithm": "AES256"}}]
                },
            )
        except ClientError as exc:
            log.warning("Chiffrement du bucket non activé: %s", exc)

    def put(self, key: str, data: bytes, content_type: str = "application/octet-stream") -> None:
        self.client.put_object(Bucket=self.bucket, Key=key, Body=data, ContentType=content_type)

    def exists(self, key: str) -> bool:
        try:
            self.client.head_object(Bucket=self.bucket, Key=key)
            return True
        except ClientError:
            return False

    def stream(self, key: str) -> Iterator[bytes]:
        obj = self.client.get_object(Bucket=self.bucket, Key=key)
        return obj["Body"].iter_chunks(64 * 1024)

    def ping(self) -> None:
        self.client.head_bucket(Bucket=self.bucket)


_storage: S3Storage | None = None


def get_storage() -> S3Storage:
    global _storage
    if _storage is None:
        _storage = S3Storage()
    return _storage
