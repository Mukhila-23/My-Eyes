"""Outbound emergency alert delivery.

My Eyes cannot pretend that a Python process can silently send an SMS: on
Android that requires a paid SMS gateway or a server-side provider account.
Rather than hard-code a dependency the project does not have, this module is a
*pluggable* delivery provider:

  * When ``EMERGENCY_ALERT_WEBHOOK_URL`` is configured, the backend really does
    dispatch the alert (an SMS gateway, Twilio, a Firebase topic, an FCM
    push-to-contact device -- whatever the operator wired up) and reports what
    it reached.
  * When it is not configured, delivery is reported as ``client``, which tells
    the Flutter app to hand the message to the device's messaging/dialer apps.

Both paths are safe: every failure is caught and downgraded to a delivery
failure for that contact only. Nothing in here can raise out to the caller and
therefore can never abort an SOS that is already in progress.
"""

import logging
import os
from dataclasses import dataclass, field
from typing import Iterable, List, Optional

import httpx

logger = logging.getLogger("myeyes.sos")

# Long enough for a slow gateway, short enough that SOS never appears hung.
WEBHOOK_TIMEOUT_SECONDS = float(os.getenv("EMERGENCY_ALERT_TIMEOUT", "10"))


@dataclass
class EmergencyRecipient:
    """One contact to alert, in the shape a gateway needs."""

    contact_id: int
    name: str
    phone_number: str
    relationship: str
    priority: int


@dataclass
class NotificationOutcome:
    """Per-contact delivery report."""

    method: str = "none"
    notified: List[str] = field(default_factory=list)
    failed: List[str] = field(default_factory=list)
    detail: str = ""

    @property
    def delivered(self) -> int:
        return len(self.notified)


def _webhook_url() -> Optional[str]:
    url = (os.getenv("EMERGENCY_ALERT_WEBHOOK_URL") or "").strip()
    return url or None


def _webhook_token() -> Optional[str]:
    token = (os.getenv("EMERGENCY_ALERT_WEBHOOK_TOKEN") or "").strip()
    return token or None


def is_configured() -> bool:
    """True when the backend has a real delivery provider to hand alerts to."""
    return _webhook_url() is not None


def describe_configuration() -> List[str]:
    """Startup log lines. Never prints the token itself."""
    if is_configured():
        return [
            "Emergency delivery provider: configured (webhook). "
            "SOS alerts are dispatched by the backend."
        ]
    return [
        "Emergency delivery provider: NOT configured. "
        "Set EMERGENCY_ALERT_WEBHOOK_URL to let the backend dispatch SOS "
        "alerts; until then the phone hands the message to the messaging app."
    ]


def dispatch_alert(
    *,
    message: str,
    recipients: Iterable[EmergencyRecipient],
    user_name: str,
    user_email: str,
    latitude: Optional[float] = None,
    longitude: Optional[float] = None,
) -> NotificationOutcome:
    """Send ``message`` to every recipient.

    Returns a per-contact report. Never raises.
    """
    targets = [r for r in recipients if r.phone_number]
    if not targets:
        return NotificationOutcome(
            method="none",
            detail="No emergency contacts were configured.",
        )

    url = _webhook_url()
    if not url:
        # No provider: the phone is the delivery channel. Report every contact
        # as "needs client delivery" rather than silently pretending success.
        return NotificationOutcome(
            method="client",
            detail=(
                "No server-side delivery provider is configured, so the phone "
                "delivers the alert through the messaging and dialer apps."
            ),
        )

    notified: List[str] = []
    failed: List[str] = []
    headers = {"Content-Type": "application/json"}
    token = _webhook_token()
    if token:
        headers["Authorization"] = f"Bearer {token}"

    for recipient in targets:
        payload = {
            "to": recipient.phone_number,
            "to_name": recipient.name,
            "relationship": recipient.relationship,
            "priority": recipient.priority,
            "message": message,
            "user_name": user_name,
            "user_email": user_email,
            "location": (
                {"latitude": latitude, "longitude": longitude}
                if latitude is not None and longitude is not None
                else None
            ),
            "source": "my-eyes-sos",
        }
        try:
            with httpx.Client(timeout=WEBHOOK_TIMEOUT_SECONDS) as client:
                response = client.post(url, json=payload, headers=headers)
            if 200 <= response.status_code < 300:
                notified.append(recipient.phone_number)
            else:
                failed.append(recipient.phone_number)
                logger.warning(
                    "SOS delivery to %s returned HTTP %s",
                    recipient.phone_number,
                    response.status_code,
                )
        except Exception:
            # A gateway that is down or unreachable must degrade to "this one
            # contact was not reached" and let the remaining ones through.
            failed.append(recipient.phone_number)
            logger.exception(
                "SOS delivery to %s raised; continuing with the rest",
                recipient.phone_number,
            )

    return NotificationOutcome(
        method="server" if notified else "client",
        notified=notified,
        failed=failed,
        detail=f"{len(notified)} of {len(targets)} contacts reached the provider.",
    )
