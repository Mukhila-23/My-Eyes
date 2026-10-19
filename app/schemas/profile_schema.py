from typing import Optional
from pydantic import BaseModel, EmailStr, Field
from datetime import datetime


# ---------------- Response ---------------- #

class UserResponse(BaseModel):
    id: int
    full_name: str
    email: EmailStr
    phone_number: Optional[str] = None
    companion: Optional[str] = None
    created_at: datetime

    class Config:
        from_attributes = True


# ---------------- Update Profile ---------------- #

class UpdateProfile(BaseModel):
    full_name: Optional[str] = None
    phone_number: Optional[str] = None
    companion: Optional[str] = None


# ---------------- Change Companion ---------------- #

class CompanionUpdate(BaseModel):
    """Companion switch.

    A dedicated, single-field endpoint rather than reusing ``/profile/update``:
    the voice layer only ever changes the companion, and a partial profile
    update must never be able to blank a name or a phone number by accident.
    Validation of the value itself (alex/maya) lives in
    ``user_service._normalize_companion`` so there is exactly one rule.
    """

    companion: str = Field(min_length=1, max_length=20)


# ---------------- Change Password ---------------- #

class ChangePassword(BaseModel):
    current_password: str
    new_password: str