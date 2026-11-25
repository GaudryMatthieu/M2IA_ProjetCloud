import pytest
from sqlalchemy import create_engine, text

import worker


class FakeS3:
    def __init__(self):
        self.objs = {}

    def put_object(self, Bucket, Key, Body, ContentType=""):  # noqa: N803
        self.objs[(Bucket, Key)] = Body


@pytest.fixture()
def engine(tmp_path):
    e = create_engine(f"sqlite:///{tmp_path}/w.db")
    with e.begin() as c:
        c.execute(text("CREATE TABLE tickets (id INTEGER PRIMARY KEY, title TEXT, status TEXT, "
                       "requester_id INTEGER, notified BOOLEAN DEFAULT 0, created_at TEXT)"))
        c.execute(text("INSERT INTO tickets (id,title,status,requester_id,created_at) "
                       "VALUES (1,'Imprimante','open',1,'2025-01-01')"))
    return e


def test_ticket_created_marks_notified(engine):
    worker.handle_event({"event": "ticket.created", "ticket_id": 1, "title": "x", "requester_email": "a@b.c"},
                        engine, FakeS3(), "helpdesk")
    with engine.connect() as c:
        assert c.execute(text("SELECT notified FROM tickets WHERE id=1")).scalar() == 1


def test_export_uploads_csv(engine):
    s3 = FakeS3()
    worker.handle_event({"event": "export.requested", "export_id": "abc"}, engine, s3, "helpdesk")
    body = s3.objs[("helpdesk", "exports/abc.csv")].decode()
    assert body.startswith("id,title,status") and "Imprimante" in body


def test_unknown_event_raises(engine):
    with pytest.raises(ValueError):
        worker.handle_event({"event": "nope"}, engine, FakeS3(), "helpdesk")
