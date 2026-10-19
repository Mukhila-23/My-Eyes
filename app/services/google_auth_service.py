"""Verification of Google ID tokens received from the Android app."""

import os

from fastapi import HTTPException
from google.auth.transport import requests
from google.oauth2 import id_token


def verify_google_identity(token: str) -> dict:
    client_id = os.getenv("GOOGLE_OAUTH_WEB_CLIENT_ID", "").strip()
    if not client_id:
        raise HTTPException(503, detail={
            "code": "GOOGLE_OAUTH_NOT_CONFIGURED",
            "message": "Google sign-in has not been configured on the server.",
        })
    try:
        identity = id_token.verify_oauth2_token(token, requests.Request(), client_id)
    except (ValueError, TypeError) as error:
        raise HTTPException(401, detail={
            "code": "INVALID_GOOGLE_TOKEN",
            "message": "Google could not verify this sign-in.",
        }) from error

    email = str(identity.get("email") or "").strip().lower()
    if not email or identity.get("email_verified") is not True:
        raise HTTPException(401, detail={
            "code": "UNVERIFIED_GOOGLE_EMAIL",
            "message": "Google did not provide a verified email address.",
        })
    return identity
