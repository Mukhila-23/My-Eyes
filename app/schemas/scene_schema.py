from pydantic import BaseModel


class SceneResponse(BaseModel):
    description: str
    audio_url: str