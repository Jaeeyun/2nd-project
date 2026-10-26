import json
import threading
import time

import jwt
import requests
import urllib3
from fastapi import Depends, HTTPException, Request
from jwt.algorithms import RSAAlgorithm
from sqlalchemy.orm import Session

import config
import models
from audit import record_db_access
from database import get_db

urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

_jwks_keys: dict[str, object] = {}
_jwks_fetched_at = 0.0
_jwks_lock = threading.Lock()
_JWKS_TTL_SECONDS = 300

def _get_signing_key(kid: str):
    global _jwks_fetched_at
    now = time.time()
    with _jwks_lock:
        if not _jwks_keys or now - _jwks_fetched_at > _JWKS_TTL_SECONDS:

            resp = requests.get(config.KEYCLOAK_JWKS_URL, verify=False, timeout=5)
            resp.raise_for_status()
            keys = {}
            for jwk in resp.json().get("keys", []):
                if jwk.get("kty") != "RSA":
                    continue
                keys[jwk["kid"]] = RSAAlgorithm.from_jwk(json.dumps(jwk))
            _jwks_keys.clear()
            _jwks_keys.update(keys)
            _jwks_fetched_at = now
    return _jwks_keys.get(kid)

def get_current_email(request: Request) -> str:

    access_token = request.headers.get("x-auth-request-access-token")
    if not access_token:
        raise HTTPException(
            status_code=401,
            detail="인증 정보가 없습니다. oauth2-proxy를 통한 로그인이 필요합니다.",
        )
    try:
        kid = jwt.get_unverified_header(access_token).get("kid")
        key = _get_signing_key(kid)
        if key is None:
            raise HTTPException(status_code=401, detail="서명 검증 키를 찾을 수 없습니다.")
        payload = jwt.decode(access_token, key=key, algorithms=["RS256"], options={"verify_aud": False})
    except jwt.PyJWTError as exc:
        raise HTTPException(status_code=401, detail=f"JWT 검증 실패: {exc}") from exc
    email = payload.get("email")
    if not email:
        raise HTTPException(status_code=401, detail="JWT에 email 클레임이 없습니다.")
    return email.strip().lower()

def _client_ip(request: Request) -> str:

    xff = request.headers.get("x-forwarded-for")
    if xff:
        return xff.split(",")[0].strip()
    return request.client.host if request.client else "unknown"

def get_current_hr_user(
    request: Request, email: str = Depends(get_current_email), db: Session = Depends(get_db)
) -> models.Employee:

    record_db_access(
        account=email,
        action=request.method,
        subject=f"path:{request.url.path}",
        access_ip=_client_ip(request),
    )
    user = db.query(models.Employee).filter(models.Employee.email == email).first()
    if not user:
        raise HTTPException(
            status_code=404, detail=f"'{email}' 계정에 해당하는 직원 정보가 없습니다."
        )
    if not user.is_hr:
        raise HTTPException(status_code=403, detail="인사팀 권한이 있는 계정만 접근할 수 있습니다.")
    return user
