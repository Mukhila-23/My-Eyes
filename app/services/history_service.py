from fastapi import HTTPException
from sqlalchemy import func
from sqlalchemy.orm import Session

from app.models.history import ScanHistory
from app.models.user import User
from app.schemas.history_schema import ScanCreate, ScanTypeSummary


# Cap on a single module-history page. A blind user listens to the newest
# entries; returning thousands of rows would make the screen unusable and slow
# without adding anything they would reach.
MAX_MODULE_HISTORY = 200


# ---------------- Save Scan ---------------- #

def save_scan(
    scan: ScanCreate,
    current_user: User,
    db: Session
):
    new_scan = ScanHistory(
        user_id=current_user.id,
        scan_type=scan.scan_type,
        input_image=scan.input_image,
        result=scan.result
    )

    db.add(new_scan)
    db.commit()
    db.refresh(new_scan)

    return new_scan


# ---------------- Get All Scans ---------------- #

def get_all_scans(
    current_user: User,
    db: Session
):
    return (
        db.query(ScanHistory)
        .filter(ScanHistory.user_id == current_user.id)
        .order_by(ScanHistory.created_at.desc())
        .all()
    )


# ---------------- Module History ---------------- #

def get_scans_by_type(
    scan_type: str,
    current_user: User,
    db: Session,
    limit: int = MAX_MODULE_HISTORY,
) -> list[ScanHistory]:
    """History for ONE module, newest first.

    This is what every module's History button opens. Scoping by both
    ``user_id`` and ``scan_type`` is what keeps one user's module history from
    ever appearing inside another user's module.
    """
    normalized = (scan_type or "").strip().upper()
    if not normalized:
        raise HTTPException(
            status_code=422,
            detail={
                "code": "VALIDATION_ERROR",
                "message": "A module type is required.",
            },
        )

    bounded = max(1, min(int(limit or MAX_MODULE_HISTORY), MAX_MODULE_HISTORY))

    return (
        db.query(ScanHistory)
        .filter(
            ScanHistory.user_id == current_user.id,
            func.upper(ScanHistory.scan_type) == normalized,
        )
        .order_by(ScanHistory.created_at.desc(), ScanHistory.id.desc())
        .limit(bounded)
        .all()
    )


def get_scan_type_summaries(current_user: User, db: Session) -> list[ScanTypeSummary]:
    """Per-module counts for the dashboard-level history list."""
    rows = (
        db.query(
            ScanHistory.scan_type,
            func.count(ScanHistory.id),
            func.max(ScanHistory.created_at),
        )
        .filter(ScanHistory.user_id == current_user.id)
        .group_by(ScanHistory.scan_type)
        .order_by(func.max(ScanHistory.created_at).desc())
        .all()
    )

    return [
        ScanTypeSummary(
            scan_type=row[0],
            count=int(row[1] or 0),
            latest_at=row[2],
        )
        for row in rows
        if row[0]
    ]


# ---------------- Get Scan By ID ---------------- #

def get_scan(
    scan_id: int,
    current_user: User,
    db: Session
):
    scan = (
        db.query(ScanHistory)
        .filter(
            ScanHistory.id == scan_id,
            ScanHistory.user_id == current_user.id
        )
        .first()
    )

    if not scan:
        raise HTTPException(
            status_code=404,
            detail="Scan not found"
        )

    return scan


# ---------------- Delete Scan ---------------- #

def delete_scan(
    scan_id: int,
    current_user: User,
    db: Session
):
    scan = (
        db.query(ScanHistory)
        .filter(
            ScanHistory.id == scan_id,
            ScanHistory.user_id == current_user.id
        )
        .first()
    )

    if not scan:
        raise HTTPException(
            status_code=404,
            detail="Scan not found"
        )

    db.delete(scan)
    db.commit()

    return {
        "message": "Scan deleted successfully"
    }


# ---------------- Clear History ---------------- #

def clear_history(
    current_user: User,
    db: Session
):
    (
        db.query(ScanHistory)
        .filter(ScanHistory.user_id == current_user.id)
        .delete()
    )

    db.commit()

    return {
        "message": "All scan history cleared successfully"
    }