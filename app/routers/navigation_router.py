from typing import List, Optional

from fastapi import APIRouter, Depends, Query
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.navigation_schema import (
    DirectionsResult,
    GeoResult,
    SavedPlaceCreate,
    SavedPlaceResponse,
    SavedPlaceUpdate,
    SearchResult,
)
from app.services.navigation_service import (
    add_saved_place,
    delete_saved_place,
    geocode,
    get_directions,
    known_categories,
    list_saved_places,
    reverse_geocode,
    search_nearby,
    update_saved_place,
)

router = APIRouter(
    prefix="/navigation",
    tags=["Navigation"],
)


# ---------------- Saved Places (user-scoped) ---------------- #

@router.get("/saved-places", response_model=List[SavedPlaceResponse])
def read_saved_places(
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    return list_saved_places(current_user, db)


@router.post("/saved-places", response_model=SavedPlaceResponse, status_code=201)
def create_saved_place(
    data: SavedPlaceCreate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    return add_saved_place(data, current_user, db)


@router.put("/saved-places/{place_id}", response_model=SavedPlaceResponse)
def update_saved_place_endpoint(
    place_id: int,
    data: SavedPlaceUpdate,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    return update_saved_place(place_id, data, current_user, db)


@router.delete("/saved-places/{place_id}")
def delete_saved_place_endpoint(
    place_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    delete_saved_place(place_id, current_user, db)
    return {"success": True}


# ---------------- Geoapify proxy (key stays on the server) ---------------- #

@router.get("/geocode", response_model=List[GeoResult])
async def geocode_query(
    query: str = Query(..., min_length=1, max_length=200),
    lat: Optional[float] = Query(None, ge=-90, le=90),
    lng: Optional[float] = Query(None, ge=-180, le=180),
    current_user: User = Depends(get_current_user),
):
    """Resolve a spoken destination to candidate coordinates."""
    return await geocode(query, lat, lng)


@router.get("/nearby", response_model=List[SearchResult])
async def nearby_places(
    category: str = Query(..., min_length=1, max_length=60),
    lat: float = Query(..., ge=-90, le=90),
    lng: float = Query(..., ge=-180, le=180),
    radius_m: int = Query(5000, ge=100, le=50000),
    name: Optional[str] = Query(None, min_length=1, max_length=100),
    current_user: User = Depends(get_current_user),
):
    """Find places of a category near the user (e.g. the nearest hospital)."""
    return await search_nearby(category, lat, lng, radius_m, name)


@router.get("/categories", response_model=List[str])
def categories(
    current_user: User = Depends(get_current_user),
):
    """Category names the device may speak for 'find the nearest ...'."""
    return known_categories()


@router.get("/directions", response_model=DirectionsResult)
async def route_directions(
    origin_lat: float = Query(..., ge=-90, le=90),
    origin_lng: float = Query(..., ge=-180, le=180),
    dest_lat: float = Query(..., ge=-90, le=90),
    dest_lng: float = Query(..., ge=-180, le=180),
    mode: str = "walking",
    current_user: User = Depends(get_current_user),
):
    """Route with full geometry for real progress and off-route detection."""
    return await get_directions(origin_lat, origin_lng, dest_lat, dest_lng, mode)


@router.get("/reverse")
async def reverse_geocode_query(
    lat: float = Query(..., ge=-90, le=90),
    lng: float = Query(..., ge=-180, le=180),
    current_user: User = Depends(get_current_user),
):
    return {"address": await reverse_geocode(lat, lng)}