from app.ai.tts_engine import generate_speech
from app.schemas.tts_schema import TTSRequest


def text_to_speech(data: TTSRequest):
    audio_url = generate_speech(data.text, data.companion)

    return {
        "audio_url": audio_url
    }
