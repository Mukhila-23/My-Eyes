from fastapi import APIRouter, Depends, UploadFile, File
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.ocr_schema import OCRResponse
from app.services.ocr_service import process_ocr

router = APIRouter(
    prefix="/ocr",
    tags=["OCR"]
)


@router.post("/scan", response_model=OCRResponse)
def scan_document(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return process_ocr(
        file=file,
        current_user=current_user,
        db=db
    )