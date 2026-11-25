import logging
import time
import uuid
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, File, HTTPException, Request, Response, UploadFile, status
from fastapi.responses import StreamingResponse
from prometheus_client import CONTENT_TYPE_LATEST, generate_latest
from sqlalchemy import select, text
from sqlalchemy.orm import Session

from . import models, schemas
from .config import get_settings
from .db import get_db, init_db
from .logging_conf import security_event, setup_logging
from .metrics import HTTP_LATENCY, HTTP_REQUESTS
from .queue import Publisher, get_publisher
from .security import agent_only, create_token, current_user, hash_password, verify_password
from .storage import S3Storage, get_storage

log = logging.getLogger("api")


@asynccontextmanager
async def lifespan(app: FastAPI):
    setup_logging()
    init_db()
    try:
        get_storage().ensure_bucket()
    except Exception as exc:  # noqa: BLE001 — /readyz signalera le problème
        log.error("Bucket non initialisé: %s", exc)
    yield


app = FastAPI(title="Helpdesk API", version="1.0.0", lifespan=lifespan)


@app.middleware("http")
async def observe(request: Request, call_next):
    start = time.perf_counter()
    status_code = 500
    try:
        response = await call_next(request)
        status_code = response.status_code
        return response
    finally:
        route = request.scope.get("route")
        path = route.path if route else "unmatched"
        elapsed = time.perf_counter() - start
        if path not in ("/metrics", "/healthz", "/readyz"):
            HTTP_REQUESTS.labels(request.method, path, str(status_code)).inc()
            HTTP_LATENCY.labels(request.method, path).observe(elapsed)
            log.info(
                "request",
                extra={"fields": {"method": request.method, "path": path, "status": status_code,
                                  "duration_ms": round(elapsed * 1000, 1)}},
            )


# ---------- Santé / métriques ----------
@app.get("/healthz", include_in_schema=False)
def healthz():
    return {"status": "ok"}


@app.get("/readyz", include_in_schema=False)
def readyz(db: Session = Depends(get_db), storage: S3Storage = Depends(get_storage)):
    try:
        db.execute(text("SELECT 1"))
        storage.ping()
    except Exception as exc:  # noqa: BLE001
        raise HTTPException(503, f"not ready: {exc}") from None
    return {"status": "ready"}


@app.get("/metrics", include_in_schema=False)
def metrics():
    return Response(generate_latest(), media_type=CONTENT_TYPE_LATEST)


# ---------- Authentification ----------
@app.post("/auth/register", response_model=schemas.UserOut, status_code=201)
def register(body: schemas.Credentials, db: Session = Depends(get_db)):
    if db.scalar(select(models.User).where(models.User.email == body.email)):
        raise HTTPException(409, "Email déjà utilisé")
    first = db.scalar(select(models.User.id).limit(1)) is None
    user = models.User(email=body.email, password_hash=hash_password(body.password), is_agent=first)
    db.add(user)
    db.commit()
    security_event("user_registered", user_id=user.id, is_agent=first)
    return user


@app.post("/auth/login", response_model=schemas.TokenOut)
def login(body: schemas.Credentials, request: Request, db: Session = Depends(get_db)):
    user = db.scalar(select(models.User).where(models.User.email == body.email))
    if not user or not verify_password(body.password, user.password_hash):
        security_event("login_failed", email=body.email, ip=request.client.host if request.client else None)
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Identifiants invalides")
    security_event("login_success", user_id=user.id)
    return schemas.TokenOut(access_token=create_token(user))


@app.get("/me", response_model=schemas.UserOut)
def me(user: models.User = Depends(current_user)):
    return user


# ---------- Tickets ----------
def _get_ticket(db: Session, user: models.User, ticket_id: int) -> models.Ticket:
    t = db.get(models.Ticket, ticket_id)
    if t is None or (not user.is_agent and t.requester_id != user.id):
        raise HTTPException(404, "Ticket introuvable")
    return t


@app.post("/tickets", response_model=schemas.TicketOut, status_code=201)
def create_ticket(
    body: schemas.TicketCreate,
    user: models.User = Depends(current_user),
    db: Session = Depends(get_db),
    pub: Publisher = Depends(get_publisher),
):
    t = models.Ticket(title=body.title, description=body.description, requester_id=user.id)
    db.add(t)
    db.commit()
    pub.publish("ticket.created", {"ticket_id": t.id, "title": t.title, "requester_email": user.email})
    return t


@app.get("/tickets", response_model=list[schemas.TicketOut])
def list_tickets(user: models.User = Depends(current_user), db: Session = Depends(get_db)):
    q = select(models.Ticket).order_by(models.Ticket.id.desc()).limit(200)
    if not user.is_agent:
        q = q.where(models.Ticket.requester_id == user.id)
    return db.scalars(q).all()


@app.get("/tickets/{ticket_id}", response_model=schemas.TicketDetail)
def get_ticket(ticket_id: int, user: models.User = Depends(current_user), db: Session = Depends(get_db)):
    return _get_ticket(db, user, ticket_id)


@app.patch("/tickets/{ticket_id}", response_model=schemas.TicketOut)
def update_ticket(
    ticket_id: int,
    body: schemas.TicketUpdate,
    user: models.User = Depends(agent_only),
    db: Session = Depends(get_db),
):
    t = _get_ticket(db, user, ticket_id)
    if body.status is not None:
        t.status = body.status
    if body.assignee_id is not None:
        t.assignee_id = body.assignee_id
    db.commit()
    return t


@app.post("/tickets/{ticket_id}/comments", response_model=schemas.CommentOut, status_code=201)
def add_comment(
    ticket_id: int,
    body: schemas.CommentCreate,
    user: models.User = Depends(current_user),
    db: Session = Depends(get_db),
):
    t = _get_ticket(db, user, ticket_id)
    c = models.Comment(ticket_id=t.id, author_id=user.id, body=body.body)
    db.add(c)
    db.commit()
    return c


# ---------- Pièces jointes (stockage objet) ----------
@app.post("/tickets/{ticket_id}/attachment", response_model=schemas.TicketOut)
async def upload_attachment(
    ticket_id: int,
    file: UploadFile = File(...),
    user: models.User = Depends(current_user),
    db: Session = Depends(get_db),
    storage: S3Storage = Depends(get_storage),
):
    t = _get_ticket(db, user, ticket_id)
    data = await file.read()
    if len(data) > get_settings().max_upload_bytes:
        raise HTTPException(413, "Fichier trop volumineux")
    key = f"attachments/{t.id}/{uuid.uuid4().hex}"
    storage.put(key, data, file.content_type or "application/octet-stream")
    t.attachment_key, t.attachment_name = key, (file.filename or "fichier")[:255]
    db.commit()
    return t


@app.get("/tickets/{ticket_id}/attachment")
def download_attachment(
    ticket_id: int,
    user: models.User = Depends(current_user),
    db: Session = Depends(get_db),
    storage: S3Storage = Depends(get_storage),
):
    t = _get_ticket(db, user, ticket_id)
    if not t.attachment_key:
        raise HTTPException(404, "Aucune pièce jointe")
    return StreamingResponse(
        storage.stream(t.attachment_key),
        media_type="application/octet-stream",
        headers={"Content-Disposition": f'attachment; filename="{t.attachment_name}"'},
    )


# ---------- Exports CSV (tâche de fond traitée par le worker) ----------
@app.post("/exports", status_code=202)
def request_export(user: models.User = Depends(agent_only), pub: Publisher = Depends(get_publisher)):
    export_id = uuid.uuid4().hex
    ok = pub.publish("export.requested", {"export_id": export_id, "requested_by": user.id})
    if not ok:
        raise HTTPException(503, "File de messages indisponible")
    return {"export_id": export_id, "status": "pending"}


@app.get("/exports/{export_id}")
def get_export(
    export_id: str, user: models.User = Depends(agent_only), storage: S3Storage = Depends(get_storage)
):
    if not export_id.isalnum():
        raise HTTPException(400, "Identifiant invalide")
    key = f"exports/{export_id}.csv"
    if not storage.exists(key):
        raise HTTPException(404, "Export en cours ou inexistant")
    return StreamingResponse(
        storage.stream(key), media_type="text/csv",
        headers={"Content-Disposition": f'attachment; filename="tickets-{export_id}.csv"'},
    )
