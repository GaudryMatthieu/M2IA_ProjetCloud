import logging
import time

from sqlalchemy import create_engine
from sqlalchemy.orm import DeclarativeBase, sessionmaker

from .config import get_settings

log = logging.getLogger("db")


class Base(DeclarativeBase):
    pass


_settings = get_settings()
_kwargs = {"pool_pre_ping": True}
if _settings.database_url.startswith("sqlite"):
    _kwargs["connect_args"] = {"check_same_thread": False}
engine = create_engine(_settings.database_url, **_kwargs)
SessionLocal = sessionmaker(bind=engine, autoflush=False, expire_on_commit=False)


def get_db():
    db = SessionLocal()
    try:
        yield db
    finally:
        db.close()


def init_db(retries: int = 30) -> None:
    """Crée le schéma (avec attente de la base : plusieurs réplicas peuvent démarrer en même temps)."""
    for attempt in range(1, retries + 1):
        try:
            Base.metadata.create_all(engine)
            return
        except Exception as exc:  # noqa: BLE001
            log.warning("DB pas prête (%s/%s): %s", attempt, retries, exc)
            time.sleep(2)
    raise RuntimeError("Base de données inaccessible")
