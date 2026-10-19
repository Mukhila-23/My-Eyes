from fastapi import UploadFile
from sqlalchemy.orm import Session

from app.ai.medicine_engine import extract_medicine_details
from app.ai.tts_engine import generate_speech
from app.models.history import ScanHistory
from app.models.user import User
from app.services.image_upload_service import save_validated_image


def process_medicine(file: UploadFile, current_user: User, db: Session):
    unique_filename, file_path = save_validated_image(file)
    medicine = extract_medicine_details(file_path)
    full_text = medicine["full_text"]

    # Empty OCR is a normal outcome, so it never reaches gTTS.
    audio_url = generate_speech(full_text)
    history = ScanHistory(
        user_id=current_user.id,
        scan_type="MEDICINE",
        input_image=f"/uploads/{unique_filename}",
        result=full_text,
    )
    db.add(history)
    db.commit()
    return {
        "medicine_name": medicine["medicine_name"],
        "full_text": full_text,
        "audio_url": audio_url,
    }
