import logging
import os

from fastapi import UploadFile
from sqlalchemy.orm import Session

from app.ai.ocr_engine import extract_text
from app.models.user import User
from app.models.history import ScanHistory
from app.services.image_upload_service import save_validated_image

logger = logging.getLogger("myeyes.ocr")


UPLOAD_FOLDER = "app/uploads"


def process_ocr(
    file: UploadFile,
    current_user: User,
    db: Session
):
    logger.info("READ TEXT START filename=%s", file.filename)
    unique_filename, file_path = save_validated_image(file)
    logger.info("IMAGE SAVED path=%s size=%d", file_path, os.path.getsize(file_path))

    # Extract text
    text = extract_text(file_path)
    logger.info("TEXT EXTRACTED characters=%d", len(text))

    # Flutter owns spoken feedback.  Calling gTTS here performs an additional
    # network request after OCR and was able to keep the HTTP response open
    # indefinitely when that external service was unreachable.
    audio_url = ""

    # Save to history
    history = ScanHistory(
        user_id=current_user.id,
        scan_type="OCR",
        input_image=f"/uploads/{unique_filename}",
        result=text
    )

    db.add(history)
    db.commit()

    response = {
        "success": True,
        "extracted_text": text,
        "audio_url": audio_url,
    }
    logger.info("RESPONSE CREATED OCR characters=%d", len(text))
    return response
