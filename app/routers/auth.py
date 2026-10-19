from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.schemas.auth_schema import (
    AccountLinkRequest,
    AccountSession,
    AccountStatus,
    AccountStatusRequest,
    BiometricLogin,
    UserCreate,
)
from app.services.user_service import (
    account_status,
    link_existing_account,
    login_user,
    register_user,
)
from app.services.google_auth_service import verify_google_identity

router = APIRouter(
    prefix="/auth",
    tags=["Authentication"]
)


@router.post("/register", response_model=AccountSession, status_code=201)
def register(user: UserCreate, db: Session = Depends(get_db)):
    """Create a brand new account.

    Returns 409 EMAIL_EXISTS when the email is already registered so the app
    can load that account instead of creating a duplicate.
    """
    identity = verify_google_identity(user.google_id_token)
    return register_user(user, db, verified_email=identity["email"])


@router.post("/account/status", response_model=AccountStatus)
def account_exists(
    payload: AccountStatusRequest,
    db: Session = Depends(get_db),
):
    """Report whether this email already has a My Eyes account."""
    identity = verify_google_identity(payload.google_id_token)
    return account_status(identity["email"], db)


@router.post("/account/link", response_model=AccountSession)
def link_account(
    payload: AccountLinkRequest,
    db: Session = Depends(get_db),
):
    """Load an existing account onto this device after a biometric check."""
    identity = verify_google_identity(payload.google_id_token)
    return link_existing_account(payload, db, verified_email=identity["email"])


@router.post("/biometric/login", response_model=AccountSession)
def biometric_login(login: BiometricLogin, db: Session = Depends(get_db)):
    return login_user(login, db)
