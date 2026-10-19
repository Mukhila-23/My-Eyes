from typing import List

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.emergency_schema import (
    EmergencyContactCreate,
    EmergencyContactUpdate,
    EmergencyContactResponse,
)
from app.services.emergency_contact_service import (
    get_contacts,
    get_contact,
    add_contact,
    update_contact,
    delete_contact,
    set_primary,
)

router = APIRouter(
    prefix="/emergency-contacts",
    tags=["Emergency Contacts"]
)


# ---------------- List ---------------- #

@router.get("", response_model=List[EmergencyContactResponse])
def read_contacts(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return get_contacts(current_user, db)


# ---------------- Create ---------------- #

@router.post("", response_model=EmergencyContactResponse, status_code=201)
def create_contact(
    contact: EmergencyContactCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return add_contact(contact, current_user, db)


# ---------------- Get by ID ---------------- #

@router.get("/{contact_id}", response_model=EmergencyContactResponse)
def read_contact(
    contact_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return get_contact(contact_id, current_user, db)


# ---------------- Update ---------------- #

@router.put("/{contact_id}", response_model=EmergencyContactResponse)
def update_contact_endpoint(
    contact_id: int,
    contact: EmergencyContactUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return update_contact(contact_id, contact, current_user, db)


# ---------------- Delete ---------------- #

@router.delete("/{contact_id}")
def delete_contact_endpoint(
    contact_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return delete_contact(contact_id, current_user, db)


# ---------------- Set Primary ---------------- #

@router.put("/{contact_id}/primary", response_model=EmergencyContactResponse)
def set_primary_endpoint(
    contact_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return set_primary(contact_id, current_user, db)
