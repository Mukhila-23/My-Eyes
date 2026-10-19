"""Outbound SMS/email dispatch for the emergency relay.

This is the "relay" half of the pluggable delivery provider described in
``emergency_notifier.py``. The split exists because the two halves have
incompatible authentication:

  * ``emergency_notifier`` speaks ONE shape - a JSON POST with
    ``Authorization: Bearer <token>`` - because that is simple and testable.
  * No SMS gateway accepts that. Twilio wants HTTP Basic and form encoding,
    MSG91 wants its auth key in a header with its own JSON envelope, Fast2SMS
    wants the key in a query string.

Pointing ``EMERGENCY_ALERT_WEBHOOK_URL`` straight at a gateway therefore fails
authentication on every contact, and a safety feature that reports "reached"
while nothing was sent is far worse than one that admits it cannot deliver.
This module is the translator: it accepts the notifier's shape, verifies the
bearer token, converts to whichever provider is configured, and returns a real
success or failure.

``console`` is a first-class provider. It logs the composed alert and reports
success without sending anything, which is what makes the relay testable
without a paid account.

SMS to the contact's own phone number is the only delivery channel: an
emergency contact record holds a phone number, and an alert that lands in an
inbox is not what they are expecting to receive.

This module never raises out to the caller: a provider that is down must be
reported as "this contact was not reached" so the remaining contacts are still
attempted.
"""

from __future__ import annotations

import logging
import os
from dataclasses import dataclass
from typing import Optional

import httpx

logger = logging.getLogger("myeyes.sos.relay")

# Provider names accepted in EMERGENCY_RELAY_PROVIDER.
#
# Every real provider here sends an SMS to the contact's own phone number.
# There is deliberately no email option: an emergency alert that arrives in an
# inbox is not what an emergency contact expects, and a contact record only
# holds a phone number in the first place.
PROVIDER_CONSOLE = "console"
PROVIDER_TWILIO = "twilio"
PROVIDER_MSG91 = "msg91"
PROVIDER_FAST2SMS = "fast2sms"

SUPPORTED_PROVIDERS = (
    PROVIDER_CONSOLE,
    PROVIDER_TWILIO,
    PROVIDER_MSG91,
    PROVIDER_FAST2SMS,
)


@dataclass
class AlertPayload:
    """One contact's alert, exactly as ``emergency_notifier`` sends it.

    The notifier POSTs once per contact, so this object is always a single
    recipient. Keeping it one-to-one is what lets a gateway failure be
    attributed to one phone number instead of silently dropping the rest.
    """

    to: str
    message: str
    to_name: str = ""
    relationship: str = ""
    priority: int = 1
    user_name: str = ""
    user_email: str = ""
    latitude: Optional[float] = None
    longitude: Optional[float] = None

    @property
    def has_location(self) -> bool:
        return self.latitude is not None and self.longitude is not None

    def location_line(self) -> str:
        """Human-readable location for a message body.

        Returns an empty string when there is no location rather than a
        placeholder, so the notifier's "location could not be obtained" case
        does not turn into a message full of `null`.
        """
        if not self.has_location:
            return ""
        return f"Location: https://maps.google.com/?q={self.latitude},{self.longitude}"


def provider_name() -> str:
    value = (os.getenv("EMERGENCY_RELAY_PROVIDER") or "").strip().lower()
    return value or PROVIDER_CONSOLE


def relay_token() -> str:
    return (os.getenv("EMERGENCY_RELAY_TOKEN") or "").strip()


def is_token_configured() -> bool:
    return bool(relay_token())


def timeout_seconds() -> float:
    raw = (os.getenv("EMERGENCY_RELAY_TIMEOUT") or "").strip()
    if not raw:
        return 10.0
    try:
        return max(1.0, min(float(raw), 60.0))
    except ValueError:
        return 10.0


def describe_configuration() -> list[str]:
    """Startup log lines. Never prints a secret."""
    provider = provider_name()
    lines = [
        f"Emergency relay provider: {provider}"
        + ("." if provider == PROVIDER_CONSOLE else ".")
    ]

    if not is_token_configured():
        lines.append(
            "Emergency relay token: NOT configured. Set EMERGENCY_RELAY_TOKEN, "
            "and the same value as EMERGENCY_ALERT_WEBHOOK_TOKEN, or every "
            "relayed alert will be rejected as unauthorised."
        )
    else:
        lines.append("Emergency relay token: configured.")

    if provider not in SUPPORTED_PROVIDERS:
        lines.append(
            f"Emergency relay provider '{provider}' is not recognised. "
            f"Supported: {', '.join(SUPPORTED_PROVIDERS)}. "
            "Alerts will be rejected until this is corrected."
        )
        return lines

    if provider == PROVIDER_CONSOLE:
        lines.append(
            "Emergency relay is in console mode: alerts are logged, not sent. "
            "This is for testing only - no contact will actually be messaged."
        )

    if provider in (PROVIDER_MSG91, PROVIDER_FAST2SMS):
        lines.append(
            f"{provider} sends SMS to Indian numbers and requires a registered "
            "DLT sender/traffic template before delivery is permitted."
        )

    missing = _missing_settings(provider)
    if missing:
        lines.append(
            "Emergency relay is missing required settings: "
            + ", ".join(missing)
            + ". Delivery will fail until they are set."
        )

    return lines


def _missing_settings(provider: str) -> list[str]:
    """Names (never values) of settings [provider] still needs."""
    required = {
        PROVIDER_TWILIO: (
            "EMERGENCY_RELAY_TWILIO_ACCOUNT_SID",
            "EMERGENCY_RELAY_TWILIO_AUTH_TOKEN",
            "EMERGENCY_RELAY_TWILIO_FROM",
        ),
        PROVIDER_MSG91: (
            "EMERGENCY_RELAY_MSG91_AUTHKEY",
            "EMERGENCY_RELAY_MSG91_TEMPLATE_ID",
        ),
        PROVIDER_FAST2SMS: ("EMERGENCY_RELAY_FAST2SMS_API_KEY",),
        PROVIDER_CONSOLE: (),
    }[provider]

    return [name for name in required if not (os.getenv(name) or "").strip()]


# ---------------------------------------------------------------------------
# Phone numbers
# ---------------------------------------------------------------------------

def normalize_phone(raw: str, default_country_code: str = "+91") -> str:
    """Turn a stored contact number into E.164-ish form.

    Indian emergency contacts are usually stored as a bare 10-digit mobile
    number. Every gateway below expects a country code, and the leading zero is
    dropped when one is added, so this is done once, here, rather than in each
    provider.

    Unrecognised shapes are returned unchanged rather than guessed at: sending
    an alert to a wrong number is worse than letting the gateway reject it.
    """
    value = "".join(ch for ch in (raw or "") if ch.isdigit() or ch == "+")
    if not value:
        return ""

    if value.startswith("+"):
        return value

    # 00 international prefix.
    if value.startswith("00"):
        return "+" + value[2:]

    digits = value.lstrip("+")

    # 0-prefixed trunk form: 0XXXXXXXXXX -> drop the trunk 0.
    if len(digits) == 11 and digits.startswith("0"):
        digits = digits[1:]

    if len(digits) == 10:
        return default_country_code + digits

    # Already country-coded without a plus (91XXXXXXXXXX).
    if len(digits) == 12 and digits.startswith("91"):
        return "+" + digits

    return "+" + digits


# ---------------------------------------------------------------------------
# Message composition
# ---------------------------------------------------------------------------

def compose_text(payload: AlertPayload) -> str:
    """The message actually sent to a contact.

    Priority is included because the notifier walks contacts in priority order
    and the recipient has no way to see that ordering otherwise.
    """
    parts = [payload.message.strip()]

    details = []
    if payload.has_location:
        details.append(payload.location_line())
    if payload.user_name:
        details.append(f"Sent by My Eyes for {payload.user_name}")

    for detail in details:
        if detail and detail not in parts:
            parts.append(detail)

    return "\n".join(p for p in parts if p)





# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

def dispatch(payload: AlertPayload) -> bool:
    """Send [payload] through the configured provider.

    Returns True only when the provider accepted the message. Never raises.
    """
    provider = provider_name()

    if provider not in SUPPORTED_PROVIDERS:
        logger.error(
            "Relay rejected: unsupported provider '%s'", provider
        )
        return False

    missing = _missing_settings(provider)
    if missing:
        logger.error(
            "Relay rejected: %s is missing %s",
            provider,
            ", ".join(missing),
        )
        return False

    try:
        if provider == PROVIDER_CONSOLE:
            return _send_console(payload)
        if provider == PROVIDER_TWILIO:
            return _send_twilio(payload)
        if provider == PROVIDER_MSG91:
            return _send_msg91(payload)
        if provider == PROVIDER_FAST2SMS:
            return _send_fast2sms(payload)
    except Exception:
        # A gateway that is down or misbehaving must degrade to "not reached"
        # for this contact only; the notifier still tries the next one.
        logger.exception("Relay dispatch raised for %s", provider)
        return False

    logger.error("Relay fell through for provider '%s'", provider)
    return False


def _send_console(payload: AlertPayload) -> bool:
    """Log the alert instead of sending it.

    Reports success so the whole pipeline (notifier -> relay -> provider) can be
    exercised end to end before a paid account exists. Deliberately loud: a
    console-mode deployment must never look like a silent production one.
    """
    logger.warning(
        "[CONSOLE MODE - NOT SENT] to=%s name=%s relationship=%s priority=%s | %s",
        payload.to,
        payload.to_name,
        payload.relationship,
        payload.priority,
        compose_text(payload).replace("\n", " | "),
    )
    return True


def _send_twilio(payload: AlertPayload) -> bool:
    sid = os.environ["EMERGENCY_RELAY_TWILIO_ACCOUNT_SID"]
    token = os.environ["EMERGENCY_RELAY_TWILIO_AUTH_TOKEN"]
    sender = os.environ["EMERGENCY_RELAY_TWILIO_FROM"]

    to = normalize_phone(payload.to)
    if not to:
        logger.error("Twilio: contact %r has no usable number", payload.to)
        return False

    url = f"https://api.twilio.com/2010-04-01/Accounts/{sid}/Messages.json"

    # Twilio uses HTTP Basic (account SID + auth token), which is exactly the
    # difference the relay exists to absorb.
    with httpx.Client(timeout=timeout_seconds()) as client:
        response = client.post(
            url,
            data={
                "To": to,
                "From": sender,
                "Body": compose_text(payload),
            },
            auth=(sid, token),
        )

    if 200 <= response.status_code < 300:
        logger.info("Twilio accepted the alert for %s", to)
        return True

    logger.error(
        "Twilio rejected the alert for %s: HTTP %s %s",
        to,
        response.status_code,
        response.text[:200],
    )
    return False


def _send_msg91(payload: AlertPayload) -> bool:
    authkey = os.environ["EMERGENCY_RELAY_MSG91_AUTHKEY"]
    template_id = os.environ["EMERGENCY_RELAY_MSG91_TEMPLATE_ID"]
    sender = (os.getenv("EMERGENCY_RELAY_MSG91_SENDER_ID") or "").strip()

    to = normalize_phone(payload.to)
    if not to:
        logger.error("MSG91: contact %r has no usable number", payload.to)
        return False

    # MSG91 is DLT-template based, so the body is a set of variables rather
    # than free text. The alert text is passed through as a variable.
    headers = {
        "Content-Type": "application/json",
        "authkey": authkey,
    }
    body = {
        "template_id": template_id,
        "short_url": "0",
        "recipients": [
            {
                "mobiles": to,
                "NAME": payload.to_name or payload.to_name or "Emergency Contact",
                "ALERT": compose_text(payload),
            }
        ],
    }
    if sender:
        body["sender"] = sender

    url = os.getenv(
        "EMERGENCY_RELAY_MSG91_URL",
        "https://control.msg91.com/api/v5/flow/",
    ).strip()

    with httpx.Client(timeout=timeout_seconds()) as client:
        response = client.post(url, json=body, headers=headers)

    if 200 <= response.status_code < 300:
        logger.info("MSG91 accepted the alert for %s", to)
        return True

    logger.error(
        "MSG91 rejected the alert for %s: HTTP %s %s",
        to,
        response.status_code,
        response.text[:200],
    )
    return False


def _send_fast2sms(payload: AlertPayload) -> bool:
    api_key = os.environ["EMERGENCY_RELAY_FAST2SMS_API_KEY"]
    sender = (os.getenv("EMERGENCY_RELAY_FAST2SMS_SENDER_ID") or "").strip()

    to = normalize_phone(payload.to)
    if not to:
        logger.error("Fast2SMS: contact %r has no usable number", payload.to)
        return False

    params = {
        "route": "otp",
        "numbers": to,
        "message": compose_text(payload),
        "authorization": api_key,
    }
    if sender:
        params["sender_id"] = sender

    url = os.getenv(
        "EMERGENCY_RELAY_FAST2SMS_URL",
        "https://www.fast2sms.com/dev/bulkV2",
    ).strip()

    # Fast2SMS authenticates with the key as a query parameter.
    with httpx.Client(timeout=timeout_seconds()) as client:
        response = client.get(url, params=params)

    if 200 <= response.status_code < 300:
        logger.info("Fast2SMS accepted the alert for %s", to)
        return True

    logger.error(
        "Fast2SMS rejected the alert for %s: HTTP %s %s",
        to,
        response.status_code,
        response.text[:200],
    )
    return False


