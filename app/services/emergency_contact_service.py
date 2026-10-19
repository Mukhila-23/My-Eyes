from fastapi import HTTPException
from sqlalchemy.orm import Session

from app.models.emergency_contact import EmergencyContact
from app.models.user import User
from app.schemas.emergency_schema import (
    EmergencyContactCreate,
    EmergencyContactUpdate,
)

# Maximum number of emergency contacts a single user can store.
MAX_CONTACTS = 5


# ---------------- List Contacts ---------------- #

def get_contacts(current_user: User, db: Session):
    return (
        db.query(EmergencyContact)
        .filter(EmergencyContact.user_id == current_user.id)
        .order_by(EmergencyContact.priority.asc(), EmergencyContact.id.asc())
        .all()
    )


# ---------------- Get Single Contact ---------------- #

def get_contact(contact_id: int, current_user: User, db: Session):
    contact = _owned_contact(contact_id, current_user, db)

    # Without this guard an unknown (or another user's) id returned None, and
    # the response model then failed to validate it into a 500 instead of a
    # truthful 404.
    if contact is None:
        raise HTTPException(
            status_code=404,
            detail="Emergency contact not found"
        )

    return contact


# ---------------- Add Contact ---------------- #

def add_contact(
    contact: EmergencyContactCreate,
    current_user: User,
    db: Session
):
    count = (
        db.query(EmergencyContact)
        .filter(EmergencyContact.user_id == current_user.id)
        .count()
    )

    if count >= MAX_CONTACTS:
        raise HTTPException(
            status_code=400,
            detail=f"You can have at most {MAX_CONTACTS} emergency contacts"
        )

    # Storing the same number twice would page the same person twice in one
    # SOS and make the priority list ambiguous. Reject it with a message the
    # voice layer can read out instead of letting the unique index raise a
    # 500 out of the driver.
    if _phone_taken(current_user, contact.phone_number, db):
        raise HTTPException(
            status_code=409,
            detail={
                "code": "DUPLICATE_CONTACT",
                "message": "That phone number is already in your emergency contacts.",
            },
        )

    new_contact = EmergencyContact(
        user_id=current_user.id,
        name=contact.name,
        phone_number=contact.phone_number,
        relation=contact.relationship,
        priority=contact.priority,
    )

    # Ensure only one primary (priority == 1) contact exists.
    if new_contact.priority == 1:
        _clear_default_contacts(current_user, db)

    db.add(new_contact)
    db.commit()
    db.refresh(new_contact)

    return new_contact


# ---------------- Update Contact ---------------- #

def update_contact(
    contact_id: int,
    contact: EmergencyContactUpdate,
    current_user: User,
    db: Session
):
    existing = _owned_contact(contact_id, current_user, db)

    if existing is None:
        raise HTTPException(
            status_code=404,
            detail="Emergency contact not found"
        )

    data = contact.model_dump(exclude_unset=True)

    if "phone_number" in data and _phone_taken(
        current_user,
        data["phone_number"],
        db,
        exclude_contact_id=contact_id,
    ):
        raise HTTPException(
            status_code=409,
            detail={
                "code": "DUPLICATE_CONTACT",
                "message": "That phone number is already in your emergency contacts.",
            },
        )

    # Re-validate trimmed values that Pydantic already normalised.
    if "name" in data:
        existing.name = data["name"].strip()
    if "phone_number" in data:
        existing.phone_number = data["phone_number"].strip()
    if "relationship" in data:
        existing.relation = data["relationship"].strip()
    if "priority" in data:
        # Ensure only one primary contact.
        if data["priority"] == 1 and existing.priority != 1:
            _clear_default_contacts(current_user, db)
        existing.priority = data["priority"]

    db.commit()
    db.refresh(existing)

    return existing


# ---------------- Delete Contact ---------------- #

def delete_contact(contact_id: int, current_user: User, db: Session):
    existing = _owned_contact(contact_id, current_user, db)

    if existing is None:
        raise HTTPException(
            status_code=404,
            detail="Emergency contact not found"
        )

    db.delete(existing)
    db.commit()

    return {"message": "Emergency contact deleted successfully"}


# ---------------- Set Primary ---------------- #

def set_primary(contact_id: int, current_user: User, db: Session):
    existing = _owned_contact(contact_id, current_user, db)

    if existing is None:
        raise HTTPException(
            status_code=404,
            detail="Emergency contact not found"
        )

    _clear_default_contacts(current_user, db)

    existing.priority = 1
    db.commit()
    db.refresh(existing)

    return existing


# ---------------- Helpers ---------------- #

def _owned_contact(contact_id: int, current_user: User, db: Session):
    return (
        db.query(EmergencyContact)
        .filter(
            EmergencyContact.id == contact_id,
            EmergencyContact.user_id == current_user.id
        )
        .first()
    )


def _phone_taken(
    current_user: User,
    phone_number: str,
    db: Session,
    exclude_contact_id: int = None,
) -> bool:
    """True when this user already stores ``phone_number`` on another row."""
    normalized = (phone_number or "").strip()
    if not normalized:
        return False

    query = db.query(EmergencyContact.id).filter(
        EmergencyContact.user_id == current_user.id,
        EmergencyContact.phone_number == normalized,
    )
    if exclude_contact_id is not None:
        query = query.filter(EmergencyContact.id != exclude_contact_id)

    return query.first() is not None


def _clear_default_contacts(current_user: User, db: Session):
    for contact in (
        db.query(EmergencyContact)
        .filter(
            EmergencyContact.user_id == current_user.id,
            EmergencyContact.priority == 1
        )
        .all()
    ):
        contact.priority = 2
    db.flush()
