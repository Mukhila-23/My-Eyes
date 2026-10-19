from fastapi import HTTPException
from sqlalchemy.orm import Session
from datetime import datetime
from app.models.user import User
from app.models.device_credential import DeviceCredential
from app.schemas.auth_schema import (
    AccountLinkRequest,
    AccountSession,
    AccountStatus,
    BiometricLogin,
    UserCreate,
)
from app.security import (
    hash_password,
    verify_password,
    create_access_token
)

VALID_COMPANIONS = ("alex", "maya")
DEFAULT_COMPANION = "alex"


def _normalize_companion(value) -> str:
    """Validate the companion so a bad value can never reach the TTS engine."""
    companion = (value or "").strip().lower()
    if not companion:
        return DEFAULT_COMPANION
    if companion not in VALID_COMPANIONS:
        raise HTTPException(
            status_code=422,
            detail={
                "code": "INVALID_COMPANION",
                "message": "Please choose either Alex or Maya.",
            },
        )
    return companion


def _derive_name_from_email(email: str) -> str:
    """Build a display name from the email local part.

    The app never asks a blind user to spell or type their name, so a sensible
    default is derived instead of storing a blank required column.
    """
    local = (email or "").split("@")[0]
    cleaned = "".join(ch for ch in local if ch.isalnum() or ch in "._-")
    cleaned = cleaned.replace(".", " ").replace("_", " ").replace("-", " ")
    words = [w for w in cleaned.split() if w]
    if not words:
        return "My Eyes User"
    name = " ".join(words)
    return name[:1].upper() + name[1:]


def register_user(user: UserCreate, db: Session, *, verified_email: str):
    if not user.terms_accepted:
        raise HTTPException(
            status_code=400,
            detail={
                "code": "TERMS_NOT_ACCEPTED",
                "message": (
                    "The terms must be accepted before an account is created."
                ),
            },
        )

    email = verified_email.lower()
    companion = _normalize_companion(user.companion)

    # Check whether email already exists
    existing_user = db.query(User).filter(User.email == email).first()

    if existing_user:
        raise HTTPException(
            status_code=409,
            detail={
                "code": "EMAIL_EXISTS",
                # Kept verbatim so existing clients that match on the old
                # string keep working.
                "message": "Email already registered",
            },
        )

    full_name = (user.full_name or "").strip() or _derive_name_from_email(email)

    # The server receives a random device secret, never fingerprint data.
    new_user = User(
        full_name=full_name,
        email=email,
        password=None,
        companion=companion,
    )

    db.add(new_user)
    db.commit()
    db.refresh(new_user)

    db.add(DeviceCredential(
        user_id=new_user.id,
        device_id=user.device_id,
        secret_hash=hash_password(user.device_secret),
    ))
    db.commit()

    return _session_for(new_user, created=True)


def account_status(email: str, db: Session):
    """Report whether this email already has an account.

    Only the display name and companion come back; no secret material.
    """
    db_user = db.query(User).filter(User.email == email.lower()).first()
    if db_user is None:
        return AccountStatus(
            exists=False,
            email=email.lower(),
            full_name=None,
            companion=None,
        )

    return AccountStatus(
        exists=True,
        email=db_user.email,
        full_name=db_user.full_name,
        companion=db_user.companion,
    )


def link_existing_account(
    link: AccountLinkRequest,
    db: Session,
    *,
    verified_email: str,
):
    """Load an existing account onto this device instead of duplicating it.

    The app only calls this after the device owner passed a biometric check on
    the phone. To stop a known email address from being used to take over an
    account that is already paired to a *different* phone, linking is refused
    in that case; re-enrolling the same device stays idempotent.
    """
    email = verified_email.lower()
    db_user = db.query(User).filter(User.email == email).first()

    if db_user is None:
        raise HTTPException(
            status_code=404,
            detail={
                "code": "ACCOUNT_NOT_FOUND",
                "message": "No My Eyes account uses that email address.",
            },
        )

    existing = db.query(DeviceCredential).filter(
        DeviceCredential.user_id == db_user.id,
    ).all()

    already_paired_elsewhere = [
        credential for credential in existing
        if credential.device_id != link.device_id
    ]

    if already_paired_elsewhere:
        raise HTTPException(
            status_code=409,
            detail={
                "code": "ACCOUNT_LINKED_ELSEWHERE",
                "message": (
                    "This account is already connected to another device. "
                    "Please use that device, or ask for it to be unlinked."
                ),
            },
        )

    credential = next(
        (
            c for c in existing if c.device_id == link.device_id
        ),
        None,
    )

    if credential is None:
        credential = DeviceCredential(
            user_id=db_user.id,
            device_id=link.device_id,
            secret_hash=hash_password(link.device_secret),
        )
        db.add(credential)
    elif not verify_password(link.device_secret, credential.secret_hash):
        credential.secret_hash = hash_password(link.device_secret)

    credential.last_used_at = datetime.utcnow()
    db.commit()
    db.refresh(db_user)

    return _session_for(db_user, created=False)


def update_user_companion(
    companion: str,
    db: Session,
    user: User,
) -> User:
    """Persist the companion chosen during onboarding."""
    user.companion = _normalize_companion(companion)
    db.commit()
    db.refresh(user)
    return user


def login_user(login: BiometricLogin, db: Session):
    db_user = db.query(User).filter(User.email == login.email.lower()).first()

    if db_user is None:
        raise HTTPException(
            status_code=401,
            detail="Biometric login is not set up on this device"
        )

    credential = db.query(DeviceCredential).filter(
        DeviceCredential.user_id == db_user.id,
        DeviceCredential.device_id == login.device_id,
    ).first()

    if credential is None or not verify_password(
        login.device_secret, credential.secret_hash
    ):
        raise HTTPException(
            status_code=401,
            detail="Biometric login is not set up on this device"
        )

    credential.last_used_at = datetime.utcnow()
    db.commit()
    return _session_for(db_user, created=False)


def _token_for(user: User):
    access_token = create_access_token(data={
        "sub": str(user.id),
        "email": user.email,
    })
    return {
        "access_token": access_token,
        "token_type": "bearer"
    }


def _session_for(user: User, *, created: bool) -> AccountSession:
    token = _token_for(user)
    return AccountSession(
        access_token=token["access_token"],
        token_type=token["token_type"],
        created=created,
        full_name=user.full_name,
        email=user.email,
        companion=user.companion or DEFAULT_COMPANION,
    )
