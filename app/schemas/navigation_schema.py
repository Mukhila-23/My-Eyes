from pydantic import BaseModel, Field, field_validator
from typing import List, Optional
from datetime import datetime


# ---------------- Saved Places ---------------- #

class SavedPlaceCreate(BaseModel):
    name: str = Field(min_length=1, max_length=100)
    latitude: float = Field(ge=-90, le=90)
    longitude: float = Field(ge=-180, le=180)

    @field_validator("name")
    @classmethod
    def _validate_name(cls, value: str) -> str:
        value = value.strip()
        if not value:
            raise ValueError("Place name cannot be empty")
        return value


class SavedPlaceUpdate(BaseModel):
    name: Optional[str] = Field(default=None, min_length=1, max_length=100)
    latitude: Optional[float] = Field(default=None, ge=-90, le=90)
    longitude: Optional[float] = Field(default=None, ge=-180, le=180)


class SavedPlaceResponse(BaseModel):
    id: int
    user_id: int
    name: str
    latitude: float
    longitude: float
    created_at: datetime
    updated_at: Optional[datetime]

    class Config:
        from_attributes = True


# ---------------- Geoapify results (server proxy) ---------------- #

class GeoResult(BaseModel):
    """A geocoded destination candidate."""

    name: str
    latitude: float
    longitude: float
    formatted_address: str = ""
    # Geoapify geocoding extras that help the device rank and label results.
    category: Optional[str] = None
    result_type: Optional[str] = None
    place_id: Optional[str] = None
    confidence: Optional[float] = None


class SearchResult(BaseModel):
    """A nearby place returned by the Geoapify Places API."""

    name: str
    latitude: float
    longitude: float
    formatted_address: str = ""
    distance_m: Optional[float] = None
    category: Optional[str] = None
    place_id: Optional[str] = None


class DirectionsStep(BaseModel):
    """One turn-by-turn step.

    ``from_index``/``to_index`` are Geoapify's indices into the route
    geometry. They are the only reliable way to know where a step sits on
    the route; counting steps is not equivalent.
    """

    instruction: str                 # plain, spoken-friendly text
    distance_m: float
    duration_sec: float = 0.0

    # Structured maneuver data (from details=instruction_details).
    maneuver: str = ""               # e.g. "Right", "Arrive", "Roundabout"
    pre_transition: str = ""         # "Turn right." style prompt
    post_transition: str = ""        # "Continue for 400 meters."
    streets: List[str] = Field(default_factory=list)

    # Geometry slice for this step.
    from_index: int = 0
    to_index: int = 0
    start_lat: float = 0.0
    start_lng: float = 0.0
    end_lat: float = 0.0
    end_lng: float = 0.0


class DirectionsResult(BaseModel):
    origin: str
    destination: str
    distance_m: float
    duration_sec: float

    # Full route shape as [lon, lat] pairs in travel order.
    geometry: List[List[float]] = Field(default_factory=list)
    steps: List[DirectionsStep] = Field(default_factory=list)

    # Resolved provider mode, so the device never has to guess.
    mode: str = "walking"
    distance_units: str = "meters"


class DirectionsRequest(BaseModel):
    origin_lat: float = Field(ge=-90, le=90)
    origin_lng: float = Field(ge=-180, le=180)
    dest_lat: float = Field(ge=-90, le=90)
    dest_lng: float = Field(ge=-180, le=180)
    mode: str = "walking"

    @field_validator("mode")
    @classmethod
    def _validate_mode(cls, value: str) -> str:
        value = value.strip().lower()
        # Only modes Geoapify Routing actually supports.
        allowed = {"walking", "driving", "cycling"}
        if value not in allowed:
            return "walking"
        return value