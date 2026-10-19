from fastapi import APIRouter

from app.schemas.tts_schema import TTSRequest, TTSResponse
from app.services.tts_service import text_to_speech

router = APIRouter(
    prefix="/tts",
    tags=["Text To Speech"]
)


@router.post("/generate", response_model=TTSResponse)
def generate_audio(data: TTSRequest):
    return text_to_speech(data)