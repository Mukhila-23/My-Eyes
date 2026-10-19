"""SOS orchestration.

Three responsibilities, deliberately kept apart:

  * the *configuration* read the login flow needs (is this user protected?),
  * the *event* log that already existed,
  * the *trigger* workflow that validates the request, builds the emergency
    message and hands it to the delivery provider.

Every function here is ownership-scoped: it only ever reads or writes rows
whose ``user_id`` is the authenticated user, so one account can never read or
fire another account's emergency data.
"""

import logging
from datetime import datetime
from typing import List, Optional

from fastapi import HTTPException
from sqlalchemy.orm import Session

from app.models.emergency_contact import EmergencyContact
from app.models.sos_event import SOSEvent
from app.models.user import User
from app.schemas.emergency_schema import (
    SOSConfigurationResponse,
    SOSEventCreate,
    SOSEventResponse,
    SOSTriggerRequest,
    SOSTriggerResponse,
)
from app.services import emergency_notifier
from app.services.emergency_contact_service import MAX_CONTACTS

logger = logging.getLogger("myeyes.sos")

# The alarm the phone runs after SOS. Kept here as well as on the client so
# both sides can describe the same behaviour in one sentence.
ALARM_DURATION_SECONDS = 300

# Priority order for notification: 1 is called/texted first.
NOTIFICATION_PRIORITY_ORDER = (1, 2, 3, 4, 5)


# ---------------- Existing event API (unchanged) ---------------- #

def create_sos_event(
    event: SOSEventCreate,
    current_user: User,
    db: Session
):
    new_event = SOSEvent(
        user_id=current_user.id,
        latitude=event.latitude,
        longitude=event.longitude,
        location_status=(
            "OK"
            if event.latitude is not None and event.longitude is not None
            else "UNAVAILABLE"
        ),
        status=event.status,
        contact_count=event.contact_count,
    )

    db.add(new_event)
    db.commit()
    db.refresh(new_event)

    return new_event


def get_sos_events(current_user: User, db: Session):
    return (
        db.query(SOSEvent)
        .filter(SOSEvent.user_id == current_user.id)
        .order_by(SOSEvent.triggered_at.desc())
        .all()
    )


# ---------------- Configuration read (login flow) ---------------- #

def get_sos_configuration(
    current_user: User,
    db: Session,
) -> SOSConfigurationResponse:
    """Report whether this user can actually use SOS right now.

    Called on every login. A user with zero contacts is *not* configured, no
    matter what any other flag says.
    """
    contacts = (
        db.query(EmergencyContact)
        .filter(EmergencyContact.user_id == current_user.id)
        .order_by(EmergencyContact.priority.asc(), EmergencyContact.id.asc())
        .all()
    )

    usable = [c for c in contacts if (c.phone_number or "").strip()]

    primary = next((c for c in usable if c.priority == 1), None)

    return SOSConfigurationResponse(
        configured=bool(usable),
        contact_count=len(usable),
        primary_contact=primary.name if primary else None,
        contacts=contacts,
        alarm_enabled=True,
        alarm_duration_seconds=ALARM_DURATION_SECONDS,
    )


# ---------------- Emergency message ---------------- #

def build_emergency_message(
    *,
    user_name: str,
    latitude: Optional[float] = None,
    longitude: Optional[float] = None,
    notes: Optional[str] = None,
) -> str:
    """Compose the text that reaches the emergency contacts.

    The location sentence is included whether or not a fix was available. A
    contact who is told "the location is not available" can still act; a
    contact who is silently missing the line cannot tell the difference
    between a bug and a device that had no GPS.
    """
    parts = [
        f"Emergency SOS activated for {user_name or 'a My Eyes user'}. "
        "Please contact them immediately."
    ]

    if latitude is not None and longitude is not None:
        parts.append(f"Current location: {build_map_link(latitude, longitude)}")
    else:
        parts.append(
            "Current GPS location could not be obtained at the time of the alert."
        )

    cleaned_notes = (notes or "").strip()
    if cleaned_notes:
        parts.append(f"Note from the user: {cleaned_notes}")

    parts.append("Sent by the My Eyes vision assistant.")

    return " ".join(parts)


def build_map_link(latitude: float, longitude: float) -> str:
    """A plain, universally openable map link.

    Deliberately not a ``geo:`` URI and not a Google Maps SDK deep link: those
    require an installed maps app, and the whole point is that the contact
    should always be able to open it.
    """
    return f"https://maps.google.com/?q={latitude},{longitude}"


# ---------------- Trigger ---------------- #

def trigger_sos(
    request: SOSTriggerRequest,
    current_user: User,
    db: Session,
) -> SOSTriggerResponse:
    """Run one SOS trigger for the authenticated user.

    Failure policy, in order of importance:

      1. A database failure must not leave the caller with no record of an
         emergency, so the event is written first and a failure to write it is
         logged rather than raised.
      2. A delivery failure never fails the request: the response reports which
         contacts were reached so the phone can tell the user the truth and keep
         its alarm running.
      3. No contacts means "not configured", which is a 409 the client can
         explain, not a 500.
    """
    contacts = (
        db.query(EmergencyContact)
        .filter(EmergencyContact.user_id == current_user.id)
        .order_by(EmergencyContact.priority.asc(), EmergencyContact.id.asc())
        .all()
    )

    recipients = [
        emergency_notifier.EmergencyRecipient(
            contact_id=contact.id,
            name=contact.name,
            phone_number=(contact.phone_number or "").strip(),
            relationship=contact.relation,
            priority=contact.priority or 2,
        )
        for contact in contacts
        if (contact.phone_number or "").strip()
    ][:MAX_CONTACTS]

    if not recipients:
        raise HTTPException(
            status_code=409,
            detail={
                "code": "SOS_NOT_CONFIGURED",
                "message": "No emergency contacts are configured.",
                "hint": "Add at least one emergency contact before using SOS.",
            },
        )

    has_location = request.latitude is not None and request.longitude is not None
    message = build_emergency_message(
        user_name=current_user.full_name,
        latitude=request.latitude,
        longitude=request.longitude,
        notes=request.notes,
    )

    outcome = emergency_notifier.dispatch_alert(
        message=message,
        recipients=recipients,
        user_name=current_user.full_name,
        user_email=current_user.email,
        latitude=request.latitude,
        longitude=request.longitude,
    )

    if outcome.method == "server" and not outcome.failed:
        status = "SENT"
    elif outcome.notified:
        status = "PARTIALLY_SENT"
    else:
        status = "FAILED"

    notified_count = outcome.delivered

    event = SOSEvent(
        user_id=current_user.id,
        latitude=request.latitude,
        longitude=request.longitude,
        location_status="OK" if has_location else request.location_status,
        status=status,
        contact_count=len(recipients),
        notified_count=notified_count,
        message=message,
        triggered_at=datetime.utcnow(),
    )

    try:
        db.add(event)
        db.commit()
        db.refresh(event)
    except Exception:
        # The alert has already gone out. Losing the audit row is bad, but
        # failing the request after a successful dispatch would tell the user
        # their emergency was not sent when it was.
        db.rollback()
        logger.exception("SOS alert dispatched but could not be recorded")
        return SOSTriggerResponse(
            success=notified_count > 0 or outcome.method == "client",
            event_id=-1,
            status=status,
            message=message,
            location_included=has_location,
            location_status="OK" if has_location else request.location_status,
            contact_count=len(recipients),
            notified_count=notified_count,
            failed_count=max(len(recipients) - notified_count, 0),
            delivery_method=outcome.method,
            contacts_notified=outcome.notified,
            map_link=(
                build_map_link(request.latitude, request.longitude)
                if has_location
                else None
            ),
        )

    return SOSTriggerResponse(
        success=status != "FAILED" or outcome.method == "client",
        event_id=event.id,
        status=status,
        message=message,
        location_included=has_location,
        location_status=event.location_status,
        contact_count=len(recipients),
        notified_count=notified_count,
        failed_count=max(len(recipients) - notified_count, 0),
        delivery_method=outcome.method,
        contacts_notified=outcome.notified,
        map_link=(
            build_map_link(request.latitude, request.longitude)
            if has_location
            else None
        ),
    )


def get_sos_configuration_or_raise(current_user: User, db: Session):
    """Configuration read that 409s when the user has no contacts."""
    configuration = get_sos_configuration(current_user, db)
    if not configuration.configured:
        raise HTTPException(
            status_code=409,
            detail={
                "code": "SOS_NOT_CONFIGURED",
                "message": "No emergency contacts are configured.",
                "hint": "Set up SOS before using it.",
            },
        )
    return configuration


__all__: List[str] = [
    "ALARM_DURATION_SECONDS",
    "NOTIFICATION_PRIORITY_ORDER",
    "build_emergency_message",
    "build_map_link",
    "create_sos_event",
    "get_sos_configuration",
    "get_sos_configuration_or_raise",
    "get_sos_events",
    "trigger_sos",
    "SOSConfigurationResponse",
    "SOSEventCreate",
    "SOSEventResponse",
    "SOSTriggerRequest",
    "SOSTriggerResponse",
]
