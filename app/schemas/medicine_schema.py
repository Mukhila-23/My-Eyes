from pydantic import BaseModel


class MedicineResponse(BaseModel):
    medicine_name: str
    full_text: str
    audio_url: str