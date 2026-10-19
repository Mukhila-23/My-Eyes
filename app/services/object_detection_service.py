import os
import shutil
import uuid

from fastapi import UploadFile
from sqlalchemy.orm import Session

from app.ai.object_detection_engine import detect_objects
from app.ai.tts_engine import generate_speech
from app.models.history import ScanHistory
from app.models.user import User

UPLOAD_FOLDER = "app/uploads"


def process_object_detection(
    file: UploadFile,
    current_user: User,
    db: Session
):
    os.makedirs(UPLOAD_FOLDER, exist_ok=True)

    extension = os.path.splitext(file.filename)[1]
    unique_filename = f"{uuid.uuid4()}{extension}"

    image_path = os.path.join(UPLOAD_FOLDER, unique_filename)

    with open(image_path, "wb") as buffer:
        shutil.copyfileobj(file.file, buffer)

    detected = detect_objects(image_path)

    object_names = [obj["object"] for obj in detected]

    if object_names:
        speech = "Detected objects are: " + ", ".join(object_names)
    else:
        speech = "No objects detected."

    audio_url = generate_speech(speech)

    history = ScanHistory(
        user_id=current_user.id,
        scan_type="OBJECT_DETECTION",
        input_image=f"/uploads/{unique_filename}",
        result=", ".join(object_names)
    )

    db.add(history)
    db.commit()

    return {
        "objects": detected,
        "audio_url": audio_url
    }