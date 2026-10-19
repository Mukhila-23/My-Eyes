"""HTTP face of the emergency relay.

``emergency_notifier`` POSTs one JSON alert per contact to
``EMERGENCY_ALERT_WEBHOOK_URL``. This router is that endpoint. It lives in the
same FastAPI app so the relay can be run as a single command for a demo, but it
is a genuinely separate hop: the notifier reaches it over HTTP, with the same
contract any external relay would honour.
"""

from __future__ import annotations

import hmac
import logging
from typing import Optional

from fastapi import APIRouter, Header, HTTPException
from pydantic import BaseModel, Field

from app.services.emergency_relay_service import (
    AlertPayload,
    describe_configuration,
    dispatch,
    is_token_configured,
    provider_name,
    relay_token,
    SUPPORTED_PROVIDERS,
    timeout_seconds,
)

router = APIRouter(
    prefix="/emergency-relay",
    tags=["Emergency Relay"],
)

logger = logging.getLogger("myeyes.sos.relay")


class RelayLocation(BaseModel):
    latitude: float
    longitude: float


class RelayAlert(BaseModel):
    """The body ``emergency_notifier.dispatch_alert`` sends.

    Mirrors that payload exactly. Every field is optional except ``to`` and
    ``message`` because the notifier is the only caller and it always sends
    them, but a relay that rejects a slightly different body would silently
    drop a real alert - so unknown fields are ignored and nothing else is
    demanded.
    """

    to: str = Field(..., description="Contact phone number")
    message: str = Field(..., description="Alert text")
    to_name: str = ""
    relationship: str = ""
    priority: int = 1
    user_name: str = ""
    user_email: str = ""
    location: Optional[RelayLocation] = None
    source: str = ""


class RelayResult(BaseModel):
    accepted: bool
    provider: str
    detail: str


def _verify_bearer(authorization: Optional[str]) -> None:
    """Reject anything without a matching bearer token.

    This endpoint is unauthenticated FastAPI-wise and reachable by anyone who
    can reach the port, so the shared token is the only thing standing between
    an outsider and an SMS gateway paid for by the project owner. Compared in
    constant time so the token cannot be recovered by timing.

    Not being configured at all is a hard error: an open relay would let anyone
    send messages through the project's gateway account.
    """
    expected = relay_token()
    if not expected:
        logger.error(
            "Relay refused a request: EMERGENCY_RELAY_TOKEN is not set"
        )
        raise HTTPException(
            status_code=503,
            detail="Emergency relay token is not configured on the server.",
        )

    if not authorization or not authorization.startswith("Bearer "):
        raise HTTPException(
            status_code=401,
            detail="Missing bearer token.",
        )

    presented = authorization[len("Bearer "):].strip()
    if not hmac.compare_digest(presented, expected):
        logger.warning("Relay refused a request: bad bearer token")
        raise HTTPException(status_code=401, detail="Invalid bearer token.")


@router.get("/status")
def relay_status():
    """Is the relay able to deliver, and through what?

    Never exposes a secret: it reports whether the token is present, not its
    value, and lists any provider settings that are still missing.
    """
    return {
        "provider": provider_name(),
        "supported_providers": list(SUPPORTED_PROVIDERS),
        "token_configured": is_token_configured(),
        "timeout_seconds": timeout_seconds(),
        "notes": describe_configuration(),
    }


@router.post("/sos", response_model=RelayResult)
def relay_alert(alert: RelayAlert, authorization: Optional[str] = Header(None)):
    """Accept one alert and forward it to the configured provider.

    Returns 200 with ``accepted: false`` when the provider refused, rather than
    a 5xx: a gateway rejection is a *delivery* result, not a broken relay, and
    the notifier needs the difference to decide whether to count the contact as
    reached. A 401/503 means the relay itself could not be trusted, which the
    notifier also records as not-reached.
    """
    _verify_bearer(authorization)

    payload = AlertPayload(
        to=alert.to,
        message=alert.message,
        to_name=alert.to_name,
        relationship=alert.relationship,
        priority=alert.priority,
        user_name=alert.user_name,
        user_email=alert.user_email,
        latitude=alert.location.latitude if alert.location else None,
        longitude=alert.location.longitude if alert.location else None,
    )

    accepted = dispatch(payload)

    return RelayResult(
        accepted=accepted,
        provider=provider_name(),
        detail=(
            "Alert accepted by the provider."
            if accepted
            else "The provider did not accept this alert."
        ),
    )