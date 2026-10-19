from fastapi import APIRouter, Depends, UploadFile, File
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.medicine_schema import MedicineResponse
from app.services.medicine_service import process_medicine

router = APIRouter(
    prefix="/medicine",
    tags=["Medicine Reader"]
)


@router.post("/scan", response_model=MedicineResponse)
def scan_medicine(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return process_medicine(
        file=file,
        current_user=current_user,
        db=db
    )