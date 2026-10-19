from typing import List

from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.emergency_schema import (
    SOSConfigurationResponse,
    SOSEventCreate,
    SOSEventResponse,
    SOSTriggerRequest,
    SOSTriggerResponse,
)
from app.services.sos_service import (
    create_sos_event,
    get_sos_configuration,
    get_sos_events,
    trigger_sos,
)

router = APIRouter(
    prefix="/sos-events",
    tags=["SOS Events"]
)


# ---------------- SOS Configuration ---------------- #
# Declared before the parameterised routes so "status" can never be mistaken
# for a path parameter if this router grows one later.

@router.get("/status", response_model=SOSConfigurationResponse)
def read_sos_status(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    """Is this user protected? Called on every login to decide on setup."""
    return get_sos_configuration(current_user, db)


# ---------------- Trigger SOS ---------------- #

@router.post("/trigger", response_model=SOSTriggerResponse)
def trigger_sos_event(
    request: SOSTriggerRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    """Validate, build and dispatch the emergency alert for this user."""
    return trigger_sos(request, current_user, db)


# ---------------- Create SOS Event ---------------- #

@router.post("", response_model=SOSEventResponse, status_code=201)
def create_event(
    event: SOSEventCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return create_sos_event(event, current_user, db)


# ---------------- List SOS Events ---------------- #

@router.get("", response_model=List[SOSEventResponse])
def read_events(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return get_sos_events(current_user, db)
