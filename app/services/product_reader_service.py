import os
import shutil
import uuid

from fastapi import UploadFile
from sqlalchemy.orm import Session

from app.ai.product_reader_engine import extract_product_details
from app.ai.tts_engine import generate_speech
from app.models.history import ScanHistory
from app.models.user import User

UPLOAD_FOLDER = "app/uploads"


def process_product(
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

    details = extract_product_details(image_path)

    speech = (
        f"{details['product_name']}. "
        f"MRP {details['mrp']}. "
        f"Net Quantity {details['net_quantity']}."
    )

    audio_url = generate_speech(speech)

    history = ScanHistory(
        user_id=current_user.id,
        scan_type="PRODUCT",
        input_image=f"/uploads/{unique_filename}",
        result=str(details)
    )

    db.add(history)
    db.commit()

    details["audio_url"] = audio_url

    return details