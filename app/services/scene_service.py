import os
import shutil
import uuid

from fastapi import UploadFile
from sqlalchemy.orm import Session

from app.ai.object_detection_engine import detect_objects
from app.ai.scene_engine import generate_scene_description
from app.ai.tts_engine import generate_speech
from app.models.history import ScanHistory
from app.models.user import User

UPLOAD_FOLDER = "app/uploads"


def process_scene(
    file: UploadFile,
    current_user: User,
    db: Session
):
    os.makedirs(UPLOAD_FOLDER, exist_ok=True)

    extension = os.path.splitext(file.filename)[1]

    unique_filename = f"{uuid.uuid4()}{extension}"

    image_path = os.path.join(
        UPLOAD_FOLDER,
        unique_filename
    )

    with open(image_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)

    objects = detect_objects(image_path)

    description = generate_scene_description(objects)

    audio_url = generate_speech(description)

    history = ScanHistory(
        user_id=current_user.id,
        scan_type="SCENE",
        input_image=f"/uploads/{unique_filename}",
        result=description
    )

    db.add(history)
    db.commit()

    return {
        "description": description,
        "audio_url": audio_url
    }