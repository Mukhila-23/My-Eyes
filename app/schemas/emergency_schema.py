from pydantic import BaseModel, Field, field_validator, model_validator
from datetime import datetime
from typing import Any, List, Mapping, Optional


# ---------------- Contact Input ---------------- #

def _validate_name(value: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError("Contact name is required")
    return value


def _validate_phone(value: str) -> str:
    # Allow digits, spaces, +, -, and parenthesis (common in phone numbers).
    value = value.strip()
    if len(value) < 7 or len(value) > 20:
        raise ValueError("Phone number must be between 7 and 20 characters")
    if not all(ch.isdigit() or ch in " +-()" for ch in value):
        raise ValueError("Phone number contains invalid characters")
    return value


def _validate_relationship(value: str) -> str:
    value = value.strip()
    if not value:
        raise ValueError("Relationship is required")
    return value


class EmergencyContactCreate(BaseModel):
    name: str
    phone_number: str
    relationship: str
    # 1 = primary, 2 = secondary (higher = lower priority)
    priority: int = Field(default=2, ge=1, le=5)

    _name = field_validator("name")(_validate_name)
    _phone = field_validator("phone_number")(_validate_phone)
    _relationship = field_validator("relationship")(_validate_relationship)


class EmergencyContactUpdate(BaseModel):
    name: Optional[str] = Field(default=None)
    phone_number: Optional[str] = Field(default=None)
    relationship: Optional[str] = Field(default=None)
    priority: Optional[int] = Field(default=None, ge=1, le=5)

    _name = field_validator("name")(_validate_name)
    _phone = field_validator("phone_number")(_validate_phone)
    _relationship = field_validator("relationship")(_validate_relationship)


class EmergencyContactResponse(BaseModel):
    id: int
    user_id: int
    name: str
    phone_number: str
    relationship: str
    priority: int
    created_at: datetime
    updated_at: Optional[datetime] = None

    class Config:
        from_attributes = True

    @model_validator(mode="before")
    @classmethod
    def _map_relation_column(cls, data: Any) -> Any:
        """Expose the DB's `relation` column as the API's `relationship`.

        This has to be a *before* validator. A custom `model_validate` class
        method does the same job in principle, but Pydantic v2's
        `from_attributes` path never calls it - it reads attributes straight
        off the object - so every endpoint returning this model raised a
        ResponseValidationError (HTTP 500) instead of the contact list.
        """
        if data is None:
            return data

        if isinstance(data, Mapping):
            if "relationship" not in data and "relation" in data:
                return {**data, "relationship": data["relation"]}
            return data

        relation = getattr(data, "relation", None)
        if relation is None:
            return data

        return {
            "id": getattr(data, "id", None),
            "user_id": getattr(data, "user_id", None),
            "name": getattr(data, "name", None),
            "phone_number": getattr(data, "phone_number", None),
            "relationship": relation,
            "priority": getattr(data, "priority", None),
            "created_at": getattr(data, "created_at", None),
            "updated_at": getattr(data, "updated_at", None),
        }


# ---------------- SOS ---------------- #

class SOSEventCreate(BaseModel):
    latitude: Optional[float] = Field(default=None)
    longitude: Optional[float] = Field(default=None)
    status: str = Field(default="TRIGGERED")
    contact_count: int = Field(default=0, ge=0)

    @field_validator("status")
    @classmethod
    def _validate_status(cls, value: str) -> str:
        allowed = {
            "TRIGGERED",
            "CONFIRMED",
            "CANCELLED",
            "SENT",
            "PARTIALLY_SENT",
            "FAILED",
        }
        value = value.strip().upper()
        if value not in allowed:
            raise ValueError("Invalid SOS status")
        return value


class SOSEventResponse(BaseModel):
    id: int
    user_id: int
    triggered_at: datetime
    latitude: Optional[float]
    longitude: Optional[float]
    location_status: str = "UNAVAILABLE"
    status: str
    contact_count: int
    notified_count: int = 0

    class Config:
        from_attributes = True


# ---------------- SOS Configuration / Status ---------------- #

class SOSConfigurationResponse(BaseModel):
    """What the client needs after login to decide whether to run setup.

    `configured` is the single source of truth for "this user has a usable
    SOS". It is deliberately derived from the contacts table rather than a
    separate boolean column so the two can never drift apart.
    """

    configured: bool
    contact_count: int
    primary_contact: Optional[str] = None
    # Every contact the SOS workflow will notify, ordered by priority.
    contacts: list[EmergencyContactResponse] = Field(default_factory=list)
    # True when the app is allowed to start the emergency alarm (5 minutes).
    alarm_enabled: bool = True
    alarm_duration_seconds: int = 300


class SOSTriggerRequest(BaseModel):
    """Payload the Flutter client posts when SOS is confirmed.

    Latitude/longitude are optional on purpose: when GPS is disabled,
    permission is denied or the fix times out the alert must still be sent,
    it just has to say that the location is unknown.
    """

    latitude: Optional[float] = Field(default=None, ge=-90, le=90)
    longitude: Optional[float] = Field(default=None, ge=-180, le=180)

    # Reported by the client so the event log distinguishes "we never asked"
    # from "we asked and GPS said no".
    location_status: str = Field(default="UNAVAILABLE")

    # Optional client-side note; ignored when blank. Bounded so a client
    # cannot push an unbounded blob into the audit column.
    notes: Optional[str] = Field(default=None, max_length=280)

    @field_validator("location_status")
    @classmethod
    def _validate_location_status(cls, value: str) -> str:
        allowed = {
            "OK",
            "PERMISSION_DENIED",
            "SERVICE_DISABLED",
            "TIMEOUT",
            "UNAVAILABLE",
        }
        value = (value or "").strip().upper()
        return value if value in allowed else "UNAVAILABLE"


class SOSTriggerResponse(BaseModel):
    """Outcome of one SOS trigger.

    `delivery_method` is honest about who actually sent the message:
      * "server"  - the backend dispatched it through its configured provider
      * "client"  - no provider is configured, so the Flutter app must hand the
                    message to the messaging/dialer apps
      * "none"    - nothing was sent (no contacts configured)
    """

    success: bool
    event_id: int
    status: str
    message: str
    location_included: bool
    location_status: str
    contact_count: int
    notified_count: int
    failed_count: int
    delivery_method: str
    contacts_notified: list[str] = Field(default_factory=list)
    map_link: Optional[str] = None
