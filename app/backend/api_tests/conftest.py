import os
import tempfile

_tmp = tempfile.mkdtemp()
os.environ["DATABASE_URL"] = f"sqlite:///{_tmp}/test.db"
os.environ["JWT_SECRET"] = "test-secret-not-for-prod-0123456789"

import pytest  # noqa: E402
from fastapi.testclient import TestClient  # noqa: E402

from app import main  # noqa: E402
from app.db import Base, engine  # noqa: E402
from app.queue import get_publisher  # noqa: E402
from app.storage import get_storage  # noqa: E402


class FakeStorage:
    def __init__(self):
        self.objs = {}

    def ensure_bucket(self): ...
    def ping(self): ...
    def put(self, key, data, content_type="x"): self.objs[key] = data
    def exists(self, key): return key in self.objs
    def stream(self, key): yield self.objs[key]


class FakePublisher:
    def __init__(self):
        self.events = []

    def publish(self, event, payload):
        self.events.append((event, payload))
        return True


@pytest.fixture()
def env():
    Base.metadata.drop_all(engine)
    Base.metadata.create_all(engine)
    storage, pub = FakeStorage(), FakePublisher()
    main.app.dependency_overrides[get_storage] = lambda: storage
    main.app.dependency_overrides[get_publisher] = lambda: pub
    client = TestClient(main.app)  # sans "with" : pas de lifespan (pas de vraie base/S3)
    yield client, storage, pub
    main.app.dependency_overrides.clear()


def auth(client, email, password="password123"):
    client.post("/auth/register", json={"email": email, "password": password})
    tok = client.post("/auth/login", json={"email": email, "password": password}).json()["access_token"]
    return {"Authorization": f"Bearer {tok}"}
