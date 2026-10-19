from fastapi import APIRouter, Depends, UploadFile, File
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.product_reader_schema import ProductReaderResponse
from app.services.product_reader_service import process_product

router = APIRouter(
    prefix="/product",
    tags=["Smart Product Reader"]
)


@router.post(
    "/scan",
    response_model=ProductReaderResponse
)
def scan_product(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):

    return process_product(
        file=file,
        current_user=current_user,
        db=db
    )