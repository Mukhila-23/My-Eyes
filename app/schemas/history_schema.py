from pydantic import BaseModel, Field
from datetime import datetime
from typing import List, Optional


# ---------- Create Scan ----------

class ScanCreate(BaseModel):
    scan_type: str
    input_image: Optional[str] = None
    result: str


# ---------- Response ----------

class ScanResponse(BaseModel):
    id: int
    user_id: int
    scan_type: str
    input_image: Optional[str] = None
    result: str
    created_at: datetime

    class Config:
        from_attributes = True


class ScanTypeSummary(BaseModel):
    """One row of the dashboard-level "what do I have history for?" list.

    Returned instead of an empty screen so the client can say "you have 3
    currency scans" rather than showing nothing at all.
    """

    scan_type: str
    count: int
    latest_at: Optional[datetime] = None


class ScanTypeSummaryList(BaseModel):
    summaries: List[ScanTypeSummary] = Field(default_factory=list)