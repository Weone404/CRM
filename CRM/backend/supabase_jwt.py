"""Accept Supabase Auth sessions on the Render API (used by FlightBridge routes while the CRM frontend runs with
VITE_BACKEND=supabase). Verifies the access token's ES256/RS256 signature against the project's published JWKS
(https://<ref>.supabase.co/auth/v1/.well-known/jwks.json), its audience ("authenticated"), issuer and expiry, then
maps `sub` to public.employee.auth_user_id (migration 042). HS256 tokens are accepted only if SUPABASE_JWT_SECRET is set.
"""
import os
import re
import threading
import time

import requests
from jose import jwt
from jose.exceptions import JWTError

_cache = {"keys": {}, "at": 0.0}
_lock = threading.Lock()
JWKS_TTL = 3600


def supabase_url() -> str | None:
    url = os.environ.get("SUPABASE_URL")
    if url:
        return url.rstrip("/")
    m = re.search(r"//postgres\.([a-z0-9]{20}):", os.environ.get("DATABASE_URL", ""))   # pooler username carries the ref
    return f"https://{m.group(1)}.supabase.co" if m else None


def _keys(force: bool = False) -> dict:
    base = supabase_url()
    if not base:
        return {}
    with _lock:
        if force or not _cache["keys"] or time.time() - _cache["at"] > JWKS_TTL:
            r = requests.get(f"{base}/auth/v1/.well-known/jwks.json", timeout=10)
            r.raise_for_status()
            _cache["keys"] = {k["kid"]: k for k in r.json().get("keys", []) if k.get("kid")}
            _cache["at"] = time.time()
        return _cache["keys"]


def verify(token: str) -> dict:
    """Return the verified claims or raise JWTError."""
    header = jwt.get_unverified_header(token)
    base = supabase_url()
    if not base:
        raise JWTError("Supabase URL unknown")
    opts = {"audience": "authenticated", "issuer": f"{base}/auth/v1"}
    alg = header.get("alg")
    if alg == "HS256":
        secret = os.environ.get("SUPABASE_JWT_SECRET")
        if not secret:
            raise JWTError("HS256 Supabase token but SUPABASE_JWT_SECRET is not set")
        return jwt.decode(token, secret, algorithms=["HS256"], **opts)
    if alg not in ("ES256", "RS256"):
        raise JWTError(f"unsupported alg {alg}")
    kid = header.get("kid")
    keys = _keys()
    if kid not in keys:
        keys = _keys(force=True)            # key rotation
    if kid not in keys:
        raise JWTError("unknown signing key")
    return jwt.decode(token, keys[kid], algorithms=[alg], **opts)
