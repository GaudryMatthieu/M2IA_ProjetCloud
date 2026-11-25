"""Authentification : mots de passe hachés (bcrypt) + JWT signé. A.8.5, A.8.24."""
from datetime import datetime, timedelta, timezone

import bcrypt
import jwt
from fastapi import Depends, HTTPException, status
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from sqlalchemy.orm import Session

from .config import get_settings
from .db import get_db
from .logging_conf import security_event
from .models import User

bearer = HTTPBearer(auto_error=False)
ALGO = "HS256"


def hash_password(password: str) -> str:
    return bcrypt.hashpw(password.encode(), bcrypt.gensalt()).decode()


def verify_password(password: str, hashed: str) -> bool:
    return bcrypt.checkpw(password.encode(), hashed.encode())


def create_token(user: User) -> str:
    s = get_settings()
    exp = datetime.now(timezone.utc) + timedelta(minutes=s.jwt_exp_minutes)
    return jwt.encode({"sub": str(user.id), "exp": exp}, s.jwt_secret, algorithm=ALGO)


def current_user(
    creds: HTTPAuthorizationCredentials | None = Depends(bearer), db: Session = Depends(get_db)
) -> User:
    if creds is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Authentification requise")
    try:
        data = jwt.decode(creds.credentials, get_settings().jwt_secret, algorithms=[ALGO])
        user = db.get(User, int(data["sub"]))
    except Exception:  # noqa: BLE001
        security_event("invalid_token")
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Jeton invalide") from None
    if user is None:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Utilisateur inconnu")
    return user


def agent_only(user: User = Depends(current_user)) -> User:
    if not user.is_agent:
        security_event("forbidden", user_id=user.id)
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Réservé aux agents")
    return user
