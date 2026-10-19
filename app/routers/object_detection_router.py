from fastapi import APIRouter, Depends, UploadFile, File
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.object_detection_schema import ObjectDetectionResponse
from app.services.object_detection_service import process_object_detection

router = APIRouter(
    prefix="/objects",
    tags=["Object Detection"]
)


@router.post(
    "/detect",
    response_model=ObjectDetectionResponse
)
def detect(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return process_object_detection(
        file=file,
        current_user=current_user,
        db=db
    )