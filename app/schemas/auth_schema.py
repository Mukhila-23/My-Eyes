from typing import Optional
from pydantic import BaseModel, EmailStr, Field
from datetime import datetime


# ---------------- Register ---------------- #

class GoogleVerifiedRequest(BaseModel):
    google_id_token: str = Field(min_length=20)


class UserCreate(GoogleVerifiedRequest):
    """Account creation payload.

    Deliberately minimal: the voice-first app never asks a blind user to type a
    password or even a name. `full_name` is optional and derived from the email
    when the client does not send one.
    """

    email: EmailStr
    device_id: str
    device_secret: str
    full_name: Optional[str] = Field(default=None, max_length=100)
    companion: Optional[str] = Field(default=None, max_length=20)
    terms_accepted: bool = True


# ---------------- Login ---------------- #

class BiometricLogin(BaseModel):
    email: EmailStr
    device_id: str
    device_secret: str


# ---------------- Existing account ---------------- #

class AccountStatusRequest(GoogleVerifiedRequest):
    email: EmailStr


class AccountLinkRequest(GoogleVerifiedRequest):
    """Links this device to an account that already exists.

    Only sent by the app *after* the device owner passed a biometric check, so
    an existing account is loaded rather than duplicated.
    """

    email: EmailStr
    device_id: str
    device_secret: str


# ---------------- Response ---------------- #

class UserResponse(BaseModel):
    id: int
    full_name: str
    email: EmailStr
    companion: Optional[str] = None
    created_at: datetime

    class Config:
        from_attributes = True


class AccountStatus(BaseModel):
    """Tells the app whether this email already has a My Eyes account."""

    exists: bool
    email: EmailStr
    full_name: Optional[str] = None
    companion: Optional[str] = None


# ---------------- Token Response ---------------- #

class Token(BaseModel):
    access_token: str
    token_type: str


class AccountSession(Token):
    """Token plus the account facts the app needs to skip re-asking.

    `created` is false when an existing account was loaded instead of a new
    one being created, which the app reports so the user is never told a new
    account exists when it did not.
    """

    created: bool = True
    full_name: str
    email: EmailStr
    companion: Optional[str] = None
