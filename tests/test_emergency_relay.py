"""End-to-end check of the emergency relay.

Runs the real FastAPI app in-process with TestClient and fires an alert through
the genuine path: notifier payload -> HTTP -> token check -> provider.

Run from PSG-capstone:
    .venv/Scripts/python.exe -m tests.test_emergency_relay
"""

import os
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

TOKEN = "test-token-abc123"

failures = []


def check(label, ok, detail=""):
    if ok:
        print(f"PASS  {label}")
    else:
        failures.append(label)
        print(f"FAIL  {label}  ->  {detail}")


def configure(provider="console", token=TOKEN):
    os.environ["EMERGENCY_RELAY_PROVIDER"] = provider
    os.environ["EMERGENCY_RELAY_TOKEN"] = token
    os.environ["EMERGENCY_ALERT_WEBHOOK_URL"] = (
        "http://127.0.0.1:8000/emergency-relay/sos"
    )
    os.environ["EMERGENCY_ALERT_WEBHOOK_TOKEN"] = token
    os.environ["EMERGENCY_ALERT_TIMEOUT"] = "10"


from app.services.emergency_relay_service import (  # noqa: E402
    AlertPayload,
    compose_text,
    describe_configuration,
    normalize_phone,
)


def main():
    configure()

    # ---- pure helpers ------------------------------------------------
    check(
        "10-digit Indian number gets +91",
        normalize_phone("9876543210") == "+919876543210",
        normalize_phone("9876543210"),
    )
    check(
        "trunk 0 is dropped",
        normalize_phone("09876543210") == "+919876543210",
        normalize_phone("09876543210"),
    )
    check(
        "already international is untouched",
        normalize_phone("+14155552671") == "+14155552671",
        normalize_phone("+14155552671"),
    )
    check(
        "00 prefix becomes +",
        normalize_phone("00919876543210") == "+919876543210",
        normalize_phone("00919876543210"),
    )
    check("empty number stays empty", normalize_phone("") == "")

    payload = AlertPayload(
        to="9876543210",
        message="Emergency. Ram is in trouble.",
        to_name="Mother",
        relationship="mother",
        priority=1,
        user_name="Ram",
        latitude=12.9716,
        longitude=77.5946,
    )
    body = compose_text(payload)
    check("message is included", "Emergency" in body)
    check("location is included", "maps.google.com" in body, body)
    check(
        "missing location is omitted, not None",
        "None" not in compose_text(
            AlertPayload(to="9876543210", message="Hi")
        ),
    )

    # ---- the HTTP endpoint -------------------------------------------
    from fastapi.testclient import TestClient

    from app.main import app

    client = TestClient(app)
    alert = {
        "to": "9876543210",
        "message": "Emergency. Ram is in trouble.",
        "to_name": "Mother",
        "relationship": "mother",
        "priority": 1,
        "user_name": "Ram",
        "user_email": "ram@example.com",
        "location": {"latitude": 12.9716, "longitude": 77.5946},
        "source": "my-eyes-sos",
    }

    status = client.get("/emergency-relay/status")
    check("status endpoint responds", status.status_code == 200, status.text)
    check(
        "status reports the provider",
        status.json()["provider"] == "console",
        status.text,
    )
    check(
        "status never leaks the token",
        TOKEN not in status.text,
        "token value appeared in the status response",
    )

    good = client.post(
        "/emergency-relay/sos",
        json=alert,
        headers={"Authorization": f"Bearer {TOKEN}"},
    )
    check("valid token is accepted", good.status_code == 200, good.text)
    check("provider accepted", good.json()["accepted"] is True, good.text)

    no_auth = client.post("/emergency-relay/sos", json=alert)
    check(
        "missing token is rejected 401",
        no_auth.status_code == 401,
        no_auth.text,
    )

    bad_auth = client.post(
        "/emergency-relay/sos",
        json=alert,
        headers={"Authorization": "Bearer wrong-token"},
    )
    check(
        "wrong token is rejected 401",
        bad_auth.status_code == 401,
        bad_auth.text,
    )

    malformed = client.post(
        "/emergency-relay/sos",
        json={"to": "9876543210"},  # no message
        headers={"Authorization": f"Bearer {TOKEN}"},
    )
    check(
        "a body missing 'message' is rejected, not forwarded",
        malformed.status_code == 422,
        malformed.text,
    )

    # ---- the notifier talking to the relay for real ------------------
    import httpx

    from app.services.emergency_notifier import (
        EmergencyRecipient,
        dispatch_alert,
    )

    captured = {}

    class _Handler(httpx.BaseTransport):
        def handle_request(self, request):
            captured["url"] = str(request.url)
            captured["auth"] = request.headers.get("authorization")
            captured["body"] = request.content
            return httpx.Response(200, json={"accepted": True})

    real_client = httpx.Client
    try:
        httpx.Client = lambda *a, **k: real_client(
            *a, transport=_Handler(), **k
        )
        outcome = dispatch_alert(
            message="Emergency. Ram is in trouble.",
            recipients=[
                EmergencyRecipient(
                    contact_id=1,
                    name="Mother",
                    phone_number="9876543210",
                    relationship="mother",
                    priority=1,
                ),
                EmergencyRecipient(
                    contact_id=2,
                    name="Brother",
                    phone_number="9123456780",
                    relationship="brother",
                    priority=2,
                ),
            ],
            user_name="Ram",
            user_email="ram@example.com",
            latitude=12.9716,
            longitude=77.5946,
        )
    finally:
        httpx.Client = real_client

    check(
        "notifier uses the configured URL",
        captured.get("url") == "http://127.0.0.1:8000/emergency-relay/sos",
        captured.get("url"),
    )
    check(
        "notifier sends the Bearer token",
        captured.get("auth") == f"Bearer {TOKEN}",
        captured.get("auth"),
    )
    check("method is server", outcome.method == "server", outcome.method)
    check("both contacts reached", len(outcome.notified) == 2, outcome.detail)

    # ---- a failing provider must not be reported as success ----------
    class _FailingHandler(httpx.BaseTransport):
        def handle_request(self, request):
            return httpx.Response(500, text="gateway down")

    try:
        httpx.Client = lambda *a, **k: real_client(
            *a, transport=_FailingHandler(), **k
        )
        failed = dispatch_alert(
            message="Emergency.",
            recipients=[
                EmergencyRecipient(
                    contact_id=1,
                    name="Mother",
                    phone_number="9876543210",
                    relationship="mother",
                    priority=1,
                )
            ],
            user_name="Ram",
            user_email="ram@example.com",
        )
    finally:
        httpx.Client = real_client

    check(
        "a failing provider is NOT reported as reached",
        len(failed.notified) == 0 and len(failed.failed) == 1,
        f"notified={failed.notified} failed={failed.failed}",
    )

    # ---- missing credentials are reported, not guessed ---------------
    os.environ["EMERGENCY_RELAY_PROVIDER"] = "twilio"
    for key in (
        "EMERGENCY_RELAY_TWILIO_ACCOUNT_SID",
        "EMERGENCY_RELAY_TWILIO_AUTH_TOKEN",
        "EMERGENCY_RELAY_TWILIO_FROM",
    ):
        os.environ.pop(key, None)

    from app.services.emergency_relay_service import dispatch

    check(
        "twilio without credentials refuses to send",
        dispatch(payload) is False,
        "dispatch claimed success with no credentials",
    )
    check(
        "the missing settings are named in the startup report",
        any(
            "EMERGENCY_RELAY_TWILIO_AUTH_TOKEN" in line
            for line in describe_configuration()
        ),
        str(describe_configuration()),
    )

    os.environ["EMERGENCY_RELAY_PROVIDER"] = "not-a-provider"
    check(
        "an unknown provider refuses to send",
        dispatch(payload) is False,
    )

    # ---- SMS only: there must be no email provider left ---------------
    from app.services.emergency_relay_service import SUPPORTED_PROVIDERS

    check(
        "no SMTP/email provider is offered",
        not any("smtp" in p for p in SUPPORTED_PROVIDERS),
        str(SUPPORTED_PROVIDERS),
    )
    check(
        "the remaining providers are the three SMS gateways plus console",
        set(SUPPORTED_PROVIDERS) == {"console", "twilio", "msg91", "fast2sms"},
        str(SUPPORTED_PROVIDERS),
    )

    import app.services.emergency_relay_service as relay_module

    check(
        "no SMTP sending function survives",
        not hasattr(relay_module, "_send_smtp")
        and not hasattr(relay_module, "PROVIDER_SMTP"),
        "an SMTP path is still reachable",
    )

    # A contact record holds a phone number, so delivery must target that
    # number. Verify the relay hands the provider an E.164 number, not the raw
    # stored value.
    sent = {}
    os.environ["EMERGENCY_RELAY_PROVIDER"] = "fast2sms"
    os.environ["EMERGENCY_RELAY_FAST2SMS_API_KEY"] = "dummy"

    class _CaptureHandler(httpx.BaseTransport):
        def handle_request(self, request):
            sent["url"] = str(request.url)
            return httpx.Response(200, json={"status": "success"})

    try:
        httpx.Client = lambda *a, **k: real_client(
            *a, transport=_CaptureHandler(), **k
        )
        ok = dispatch(payload)
    finally:
        httpx.Client = real_client

    check("fast2sms dispatch succeeds with a key", ok is True)
    check(
        "the SMS goes to the contact's number in E.164 form",
        "numbers=%2B919876543210" in sent.get("url", "").replace("%3A", ":"),
        sent.get("url"),
    )

    print()
    if failures:
        print(f"{len(failures)} RELAY CHECK(S) FAILED")
        return 1
    print("ALL RELAY CHECKS PASSED")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())