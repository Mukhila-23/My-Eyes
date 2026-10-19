from typing import Optional

from pydantic import BaseModel


class CurrencyResponse(BaseModel):
    success: bool
    currency: Optional[str] = None
    denomination: Optional[int] = None
    display_text: str
    confidence: float
    audio_url: str
    # Distinguishes "no note found" (error_type is None) from a real failure
    # such as MODEL_ERROR, so the app can speak the correct message.
    message: Optional[str] = None
    error_type: Optional[str] = None
    # How the denomination was proven (printed_amount, printed_numeral, ...).
    evidence: Optional[str] = None