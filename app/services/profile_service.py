from fastapi import HTTPException
from sqlalchemy.orm import Session

from app.models.user import User
from app.schemas.profile_schema import (
    CompanionUpdate,
    UpdateProfile,
    ChangePassword,
)
from app.security import hash_password, verify_password
from app.services.user_service import update_user_companion


# ---------------- Get Profile ---------------- #

def get_profile(current_user: User):
    return current_user


# ---------------- Change Companion ---------------- #

def change_companion(
    companion: CompanionUpdate,
    current_user: User,
    db: Session,
):
    """Persist the new companion and hand back the whole profile.

    The client reads the *server's* answer instead of assuming the switch
    worked, so a silent normalisation (unknown id -> default) still ends up
    with the app and the server agreeing on one companion.
    """
    return update_user_companion(companion.companion, db, current_user)


# ---------------- Update Profile ---------------- #

def update_profile(
    profile: UpdateProfile,
    current_user: User,
    db: Session
):
    if profile.full_name is not None:
        current_user.full_name = profile.full_name

    if profile.phone_number is not None:
        current_user.phone_number = profile.phone_number

    # The companion chosen during onboarding is part of the profile so it is
    # restored on the next login and every future message uses the same voice.
    if profile.companion is not None:
        update_user_companion(profile.companion, db, current_user)

    db.commit()
    db.refresh(current_user)

    return current_user


# ---------------- Change Password ---------------- #

def change_password(
    password_data: ChangePassword,
    current_user: User,
    db: Session
):
    if not verify_password(password_data.current_password, current_user.password):
        raise HTTPException(
            status_code=400,
            detail="Current password is incorrect"
        )

    current_user.password = hash_password(password_data.new_password)

    db.commit()

    return {
        "message": "Password changed successfully"
    }