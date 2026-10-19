from fastapi import APIRouter, Depends, UploadFile, File
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.currency_schema import CurrencyResponse
from app.services.currency_service import process_currency

router = APIRouter(
    prefix="/currency",
    tags=["Currency Detection"]
)


@router.post("/scan", response_model=CurrencyResponse)
def scan_currency(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return process_currency(
        file=file,
        current_user=current_user,
        db=db
    )