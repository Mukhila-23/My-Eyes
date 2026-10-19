from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.profile_schema import (
    UserResponse,
    UpdateProfile,
    CompanionUpdate,
    ChangePassword
)
from app.services.profile_service import (
    change_companion,
    get_profile,
    update_profile,
    change_password
)

router = APIRouter(
    prefix="/profile",
    tags=["Profile"]
)


# ---------------- Get Profile ---------------- #

@router.get("/me", response_model=UserResponse)
def read_profile(
    current_user: User = Depends(get_current_user)
):
    return get_profile(current_user)


# ---------------- Change Companion ---------------- #

@router.put("/companion", response_model=UserResponse)
def edit_companion(
    companion: CompanionUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    """Switch Alex <-> Maya.

    Only the companion column is written: nothing else on the profile, the SOS
    configuration or any module history is touched, so switching can never log
    the user out or reset their safety settings.
    """
    return change_companion(companion, current_user, db)


# ---------------- Update Profile ---------------- #

@router.put("/update", response_model=UserResponse)
def edit_profile(
    profile: UpdateProfile,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return update_profile(profile, current_user, db)


# ---------------- Change Password ---------------- #

@router.put("/change-password")
def update_password(
    password_data: ChangePassword,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return change_password(password_data, current_user, db)