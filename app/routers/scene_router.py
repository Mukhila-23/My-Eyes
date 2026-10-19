from fastapi import APIRouter, Depends, UploadFile, File
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.scene_schema import SceneResponse
from app.services.scene_service import process_scene

router = APIRouter(
    prefix="/scene",
    tags=["Scene Description"]
)


@router.post(
    "/describe",
    response_model=SceneResponse
)
def describe_scene(
    file: UploadFile = File(...),
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user)
):
    return process_scene(
        file=file,
        current_user=current_user,
        db=db
    )