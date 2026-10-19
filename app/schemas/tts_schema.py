from typing import Optional

from pydantic import BaseModel, Field


class TTSRequest(BaseModel):
    text: str

    # Which companion voice to render with ("alex" / "maya"). Optional so
    # existing callers keep the previous default voice.
    companion: Optional[str] = Field(default=None, max_length=20)


class TTSResponse(BaseModel):
    audio_url: str
