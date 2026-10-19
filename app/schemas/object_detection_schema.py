from pydantic import BaseModel
from typing import List


class DetectedObject(BaseModel):
    object: str
    confidence: float


class ObjectDetectionResponse(BaseModel):
    objects: List[DetectedObject]
    audio_url: str