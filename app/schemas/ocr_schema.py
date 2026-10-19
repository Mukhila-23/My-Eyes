from pydantic import BaseModel


class OCRResponse(BaseModel):
    success: bool
    extracted_text: str
    audio_url: str
