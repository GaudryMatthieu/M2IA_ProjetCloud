from api_tests.conftest import auth


def test_health_and_ready(env):
    client, *_ = env
    assert client.get("/healthz").status_code == 200
    assert client.get("/readyz").status_code == 200


def test_register_login_and_bad_password(env):
    client, *_ = env
    h = auth(client, "agent@example.com")
    assert client.get("/me", headers=h).json()["is_agent"] is True  # 1er utilisateur = agent
    bad = client.post("/auth/login", json={"email": "agent@example.com", "password": "wrong-password"})
    assert bad.status_code == 401
    short = client.post("/auth/register", json={"email": "x@example.com", "password": "short"})
    assert short.status_code == 422


def test_auth_required(env):
    client, *_ = env
    assert client.get("/tickets").status_code == 401
    assert client.get("/tickets", headers={"Authorization": "Bearer nope"}).status_code == 401


def test_ticket_lifecycle_and_event(env):
    client, _, pub = env
    agent = auth(client, "agent@example.com")
    user = auth(client, "user@example.com")
    r = client.post("/tickets", json={"title": "Imprimante HS", "description": "Plus de papier"}, headers=user)
    assert r.status_code == 201
    tid = r.json()["id"]
    assert pub.events[0][0] == "ticket.created" and pub.events[0][1]["ticket_id"] == tid
    # l'utilisateur ne peut pas changer le statut, l'agent oui
    assert client.patch(f"/tickets/{tid}", json={"status": "closed"}, headers=user).status_code == 403
    assert client.patch(f"/tickets/{tid}", json={"status": "in_progress"}, headers=agent).json()["status"] == "in_progress"
    assert client.post(f"/tickets/{tid}/comments", json={"body": "On regarde"}, headers=agent).status_code == 201
    detail = client.get(f"/tickets/{tid}", headers=user).json()
    assert len(detail["comments"]) == 1


def test_isolation_between_users(env):
    client, *_ = env
    auth(client, "agent@example.com")
    a = auth(client, "a@example.com")
    b = auth(client, "b@example.com")
    tid = client.post("/tickets", json={"title": "Ticket de A"}, headers=a).json()["id"]
    assert client.get(f"/tickets/{tid}", headers=b).status_code == 404
    assert client.get("/tickets", headers=b).json() == []


def test_attachment_roundtrip(env):
    client, storage, _ = env
    auth(client, "agent@example.com")
    u = auth(client, "u@example.com")
    tid = client.post("/tickets", json={"title": "Avec fichier"}, headers=u).json()["id"]
    up = client.post(f"/tickets/{tid}/attachment", files={"file": ("note.txt", b"bonjour", "text/plain")}, headers=u)
    assert up.status_code == 200 and up.json()["attachment_name"] == "note.txt"
    assert len(storage.objs) == 1
    assert client.get(f"/tickets/{tid}/attachment", headers=u).content == b"bonjour"


def test_export_flow(env):
    client, storage, pub = env
    agent = auth(client, "agent@example.com")
    user = auth(client, "u@example.com")
    assert client.post("/exports", headers=user).status_code == 403
    r = client.post("/exports", headers=agent)
    assert r.status_code == 202
    eid = r.json()["export_id"]
    assert pub.events[-1][0] == "export.requested"
    assert client.get(f"/exports/{eid}", headers=agent).status_code == 404  # pas encore produit par le worker
    storage.objs[f"exports/{eid}.csv"] = b"id,title\n1,x\n"
    assert client.get(f"/exports/{eid}", headers=agent).content.startswith(b"id,title")


def test_metrics_exposed(env):
    client, *_ = env
    auth(client, "agent@example.com")
    body = client.get("/metrics").text
    assert "http_requests_total" in body and "http_request_duration_seconds_bucket" in body
