from typing import List, Optional

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.history_schema import (
    ScanCreate,
    ScanResponse,
    ScanTypeSummaryList,
)
from app.services.history_service import (
    MAX_MODULE_HISTORY,
    clear_history,
    delete_scan,
    get_all_scans,
    get_scan,
    get_scan_type_summaries,
    get_scans_by_type,
    save_scan,
)

router = APIRouter(
    prefix="/history",
    tags=["History"]
)


# ---------------- Save Scan ---------------- #

@router.post("/save", response_model=ScanResponse)
def save_scan_history(
    scan: ScanCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return save_scan(scan, current_user, db)


# ---------------- Get All Scans ---------------- #

@router.get("/all", response_model=List[ScanResponse])
def read_all_scans(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return get_all_scans(current_user, db)


# ---------------- Module History ---------------- #
# Declared before "/{scan_id}" so "types" and "module/..." are never parsed as
# an integer id.

@router.get("/types", response_model=ScanTypeSummaryList)
def read_scan_types(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    """Per-module counts, so the client can name the modules it has data for."""
    return ScanTypeSummaryList(
        summaries=get_scan_type_summaries(current_user, db)
    )


@router.get("/module/{scan_type}", response_model=List[ScanResponse])
def read_module_scans(
    scan_type: str,
    limit: int = Query(
        default=MAX_MODULE_HISTORY,
        ge=1,
        le=MAX_MODULE_HISTORY,
    ),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    """History for one module only (e.g. every CURRENCY scan for this user)."""
    return get_scans_by_type(scan_type, current_user, db, limit)


# ---------------- Get Scan By ID ---------------- #

@router.get("/{scan_id}", response_model=ScanResponse)
def read_scan(
    scan_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return get_scan(scan_id, current_user, db)


# ---------------- Delete Scan ---------------- #

@router.delete("/{scan_id}")
def remove_scan(
    scan_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return delete_scan(scan_id, current_user, db)


# ---------------- Clear History ---------------- #

@router.delete("/clear/all")
def remove_all_scans(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return clear_history(current_user, db)