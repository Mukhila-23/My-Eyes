import logging

from fastapi import UploadFile
from sqlalchemy.orm import Session

from app.ai.currency_engine import detect_currency
from app.models.history import ScanHistory
from app.models.user import User
from app.services.image_upload_service import save_validated_image

logger = logging.getLogger("myeyes.currency")

# Spoken form for the supported denominations.  A blind user hears words, not
# digits, so every supported note gets a natural sentence.
_DENOMINATION_WORDS = {
    10: "ten rupees",
    20: "twenty rupees",
    50: "fifty rupees",
    100: "one hundred rupees",
    200: "two hundred rupees",
    500: "five hundred rupees",
}

_NO_DETECTION_TEXT = (
    "I couldn't identify the currency. Please place one currency note clearly "
    "in front of the camera and try again."
)

# Every distinct failure the module can report, so the app can speak the right
# sentence instead of a single catch-all error.
_ERROR_TEXTS = {
    "MODEL_ERROR": (
        "Currency detection is temporarily unavailable. Please try again."
    ),
}


def process_currency(
    file: UploadFile,
    current_user: User,
    db: Session
):
    logger.info(
        "[Currency] Backend received image: filename=%s content_type=%s size=%s",
        file.filename, file.content_type, file.size,
    )
    unique_filename, file_path = save_validated_image(file)
    logger.info("[Currency] Image saved path=%s", file_path)

    # Detect currency
    result = detect_currency(file_path)

    error_type = result.get("error_type")

    if result["success"]:
        denomination = result["denomination"]
        spoken = _DENOMINATION_WORDS.get(denomination, f"{denomination} rupees")
        display_text = f"Indian currency. {spoken[0].upper()}{spoken[1:]}."
        history_result = f"INR {denomination}"
        message = display_text
    elif error_type:
        display_text = _ERROR_TEXTS.get(
            error_type, "Currency detection failed. Please try again."
        )
        history_result = f"Currency error: {error_type}"
        message = display_text
    else:
        display_text = _NO_DETECTION_TEXT
        history_result = "No currency denomination detected"
        message = _NO_DETECTION_TEXT

    # Save history
    history = ScanHistory(
        user_id=current_user.id,
        scan_type="CURRENCY",
        input_image=f"/uploads/{unique_filename}",
        result=history_result
    )

    db.add(history)
    db.commit()

    response = {
        "success": result["success"],
        "currency": result["currency"],
        "denomination": result["denomination"],
        "display_text": display_text,
        "confidence": result["confidence"],
        "message": message,
        "error_type": error_type,
        "evidence": result.get("evidence"),
        # Flutter is the authoritative TTS path. Avoid a second external gTTS
        # request delaying an otherwise complete inference response.
        "audio_url": "",
    }
    logger.info(
        "[Currency] Backend response: success=%s currency=%s denomination=%s "
        "confidence=%s error_type=%s",
        result["success"], result["currency"], result["denomination"],
        result["confidence"], error_type,
    )
    return response