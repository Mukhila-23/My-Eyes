"""Smart Navigation backend service.

Server-side proxy to Geoapify (Geocoding API, Places API, Routing API),
which is OpenStreetMap-based and has a free tier. Plus local saved-places
persistence.

Why server-side: the Geoapify API key lives ONLY on the backend (in .env),
never on the Flutter device. The app talks to FastAPI over the existing JWT,
and FastAPI talks to Geoapify. This keeps the device secure and keeps the
OAuth2/JWT pattern consistent with the rest of My Eyes.

No Google Maps Platform is used anywhere.
"""

from __future__ import annotations

import asyncio
import math
import os
import time
from typing import Any, Dict, List, Optional, Tuple

import httpx
from fastapi import HTTPException, status
from sqlalchemy.orm import Session

from app.models.saved_place import SavedPlace
from app.schemas.navigation_schema import (
    DirectionsResult,
    DirectionsStep,
    GeoResult,
    SavedPlaceCreate,
    SavedPlaceUpdate,
    SearchResult,
)

_BASE = "https://api.geoapify.com"
_TIMEOUT = httpx.Timeout(12.0, connect=6.0)

# Geoapify bills every 20 places returned as one Places request, so the
# effective free cost of a call is ceil(limit / 20). Staying at <= 20 keeps
# each nearby search to a single request.
_PLACE_LIMIT = 20

# Keep the spoken candidate list short: only the first few are ever read out.
_GEOCODE_LIMIT = 5

# Default "find me the nearest X" search radius.
_NEARBY_RADIUS_M = 5000

# Response cache. Geocoding and Places are deterministic for a given query,
# so caching them keeps repeated voice commands inside the free tier.
_CACHE_TTL_SEC = 900
_CACHE_MAX = 256

# Client modes -> Geoapify Routing `mode` values. Only modes Geoapify Routing
# actually supports are exposed.
#
# The values are Geoapify's, not OpenStreetMap's. Verified live against
# /v1/routing, whose full allow-list is: walk, hike, scooter, motorcycle,
# drive, truck, light_truck, medium_truck, truck_dangerous_goods, heavy_truck,
# long_truck, bicycle, mountain_bike, road_bike, bus, drive_shortest,
# drive_traffic_approximated, truck_traffic_approximated, transit,
# approximated_transit. Note "bicycle" -- "bike" and "cycling" are both
# rejected with HTTP 400.
_MODE_MAP = {
    "walking": "walk",
    "driving": "drive",
    "cycling": "bicycle",
}

# Voice-friendly category name -> verified Geoapify Places category keys.
# Every key below is taken from Geoapify's published category list.
_CATEGORY_MAP: Dict[str, List[str]] = {
    "hospital": ["healthcare.hospital"],
    "clinic": ["healthcare.clinic_or_praxis"],
    "pharmacy": ["healthcare.pharmacy"],
    "chemist": ["commercial.chemist", "healthcare.pharmacy"],
    "doctor": ["healthcare.clinic_or_praxis"],
    "dentist": ["healthcare.dentist"],
    "atm": ["service.financial.atm"],
    "bank": ["service.financial.bank"],
    "bus stop": ["public_transport.bus", "public_transport.platform"],
    "bus station": ["public_transport.bus"],
    "petrol station": ["service.vehicle.fuel"],
    "gas station": ["service.vehicle.fuel"],
    "charging station": ["service.vehicle.charging_station"],
    "restaurant": ["catering.restaurant"],
    "cafe": ["catering.cafe"],
    "bakery": ["commercial.food_and_drink.bakery"],
    "supermarket": ["commercial.supermarket"],
    "grocery": ["commercial.supermarket"],
    "shop": ["commercial"],
    "police station": ["service.police"],
    "fire station": ["service.fire_station"],
    "post office": ["service.post.office"],
    "post box": ["service.post.box"],
    "library": ["education.library"],
    "school": ["education.school"],
    "college": ["education.college"],
    "university": ["education.university"],
    "park": ["leisure.park"],
    "playground": ["leisure.playground"],
    "cinema": ["entertainment.cinema"],
    "gym": ["sport.fitness.gym"],
    "swimming pool": ["sport.swimming_pool"],
    "parking": ["parking"],
    "taxi": ["service.taxi"],
    "toilet": ["amenity.toilet"],
    "drinking water": ["amenity.drinking_water"],
    "temple": ["religion.place_of_worship"],
    "mosque": ["religion.place_of_worship.islam"],
    "church": ["religion.place_of_worship.christianity"],
    "give box": ["amenity.give_box"],
}


# ================================================================
# KEY + HTTP PLUMBING
# ================================================================

def _api_key() -> str:
    key = os.getenv("GEOAPIFY_API_KEY", "").strip()
    if not key:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail=(
                "Navigation is not configured on the server. "
                "Please contact support."
            ),
        )
    return key


_cache: Dict[str, Tuple[float, Any]] = {}
_cache_lock = asyncio.Lock()


def _cache_get(key: str) -> Any | None:
    hit = _cache.get(key)
    if hit is None:
        return None
    expires_at, value = hit
    if expires_at < time.monotonic():
        _cache.pop(key, None)
        return None
    return value


def _cache_put(key: str, value: Any) -> None:
    if len(_cache) >= _CACHE_MAX:
        # Cheap bounded eviction: drop the oldest few entries.
        for stale in sorted(_cache, key=lambda k: _cache[k][0])[:16]:
            _cache.pop(stale, None)
    _cache[key] = (time.monotonic() + _CACHE_TTL_SEC, value)


def _unavailable(detail: str) -> HTTPException:
    return HTTPException(
        status_code=status.HTTP_502_BAD_GATEWAY,
        detail=detail,
    )


def _raise_for_geoapify_error(status_code: int, body: Any) -> None:
    """Map Geoapify HTTP failures onto spoken, user-safe messages."""
    message = ""
    if isinstance(body, dict):
        err = body.get("error")
        if isinstance(err, dict):
            message = str(err.get("message") or "")
        elif isinstance(err, str):
            message = err
        if not message:
            message = str(body.get("message") or "")

    if status_code in (401, 403):
        # The stored key is wrong or revoked. Never echo the provider text.
        raise _unavailable(
            "Navigation is temporarily unavailable because the server's "
            "location service key was rejected. Please contact support."
        )
    if status_code == 429:
        raise _unavailable(
            "The location service is busy right now and has rate limited us. "
            "Please try again in a moment."
        )
    if status_code == 400:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail="That request could not be understood by the location service.",
        )
    if status_code == 404:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No results were found for that request.",
        )
    raise _unavailable(
        "Navigation services are temporarily unavailable. Please try again."
    )


async def _get_json(path: str, params: Dict[str, Any]) -> Any:
    """Call a Geoapify JSON endpoint and return the decoded body.

    Raises a spoken HTTPException for every provider failure mode so the
    device never sees a raw stack trace or provider message.
    """
    query = dict(params)
    query["apiKey"] = _api_key()
    query.setdefault("lang", "en")

    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT) as client:
            resp = await client.get(
                f"{_BASE}{path}",
                params=query,
                headers={"User-Agent": "MyEyes/1.0"},
            )
    except httpx.TimeoutException:
        raise _unavailable(
            "Navigation services took too long to respond. Please try again."
        )
    except httpx.HTTPError:
        raise _unavailable(
            "I can't reach the location service right now. "
            "Please check your internet connection."
        )

    if resp.status_code >= 400:
        try:
            body = resp.json()
        except Exception:
            body = None
        _raise_for_geoapify_error(resp.status_code, body)

    try:
        return resp.json()
    except Exception:
        raise _unavailable("The location service returned an invalid response.")


# ================================================================
# GEOCODING
# ================================================================

def _best_name(item: Dict[str, Any], fallback: str) -> str:
    """Geoapify returns amenity names separately from the formatted address."""
    for key in ("name", "address_line1", "formatted", "street"):
        value = item.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    return fallback


def _short_address(item: Dict[str, Any]) -> str:
    """A compact, speakable address for 'You are near ...'."""
    street = (item.get("street") or "").strip()
    house = (item.get("housenumber") or "").strip()
    city = (item.get("city") or item.get("suburb") or "").strip()
    parts = [p for p in (" ".join(x for x in (house, street) if x), city) if p]
    if parts:
        return ", ".join(parts)
    formatted = (item.get("formatted") or "").strip()
    return formatted or "an unknown area"


async def geocode(query: str, lat: Optional[float] = None,
                  lng: Optional[float] = None) -> List[GeoResult]:
    """Forward geocode a spoken destination such as 'PSG College'.

    When the caller supplies a position we bias towards it so 'Apollo
    hospital' prefers a nearby Apollo hospital, but we do not filter, so a
    distant exact match is still reachable.
    """
    params: Dict[str, Any] = {
        "text": query,
        "format": "json",
        "limit": _GEOCODE_LIMIT,
    }
    if lat is not None and lng is not None:
        # Geoapify proximity bias is longitude,latitude.
        params["bias"] = f"proximity:{lng},{lat}"

    cache_key = f"geo|{query.strip().lower()}|{params.get('bias', '')}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    body = await _get_json("/v1/geocode/search", params)
    raw = body.get("results") if isinstance(body, dict) else None
    if not isinstance(raw, list):
        raise _unavailable("The location service returned an invalid response.")

    results: List[GeoResult] = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        try:
            lat_i = float(item.get("lat"))
            lng_i = float(item.get("lon"))
        except (TypeError, ValueError):
            continue
        rank = item.get("rank")
        confidence = None
        if isinstance(rank, dict):
            try:
                confidence = float(rank.get("confidence"))
            except (TypeError, ValueError):
                confidence = None
        results.append(GeoResult(
            name=_best_name(item, query),
            latitude=lat_i,
            longitude=lng_i,
            formatted_address=(item.get("formatted") or "").strip(),
            category=item.get("category"),
            result_type=item.get("result_type"),
            place_id=item.get("place_id"),
            confidence=confidence,
        ))

    _cache_put(cache_key, results)
    return results


async def reverse_geocode(lat: float, lng: float) -> str:
    """Coordinates -> a short spoken address for 'Where am I?'."""
    body = await _get_json(
        "/v1/geocode/reverse",
        {"lat": f"{lat}", "lon": f"{lng}", "format": "json"},
    )
    raw = body.get("results") if isinstance(body, dict) else None
    if not isinstance(raw, list) or not raw:
        return "an unknown area"
    first = raw[0]
    if not isinstance(first, dict):
        return "an unknown area"
    name = (first.get("name") or "").strip()
    address = _short_address(first)
    return f"{name}, {address}" if name and address else (address or "an unknown area")


# ================================================================
# PLACES (category / "find the nearest X")
# ================================================================

def resolve_category(name: str) -> Optional[List[str]]:
    """Map a spoken category onto verified Geoapify category keys."""
    return _CATEGORY_MAP.get(name.strip().lower())


def known_categories() -> List[str]:
    return sorted(_CATEGORY_MAP.keys())


def _haversine(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    r = 6371000.0  # Earth radius in metres
    p1, p2 = math.radians(lat1), math.radians(lat2)
    dp = math.radians(lat2 - lat1)
    dl = math.radians(lng2 - lng1)
    a = (
        math.sin(dp / 2) ** 2
        + math.cos(p1) * math.cos(p2) * math.sin(dl / 2) ** 2
    )
    return 2 * r * math.asin(math.sqrt(a))


async def search_nearby(
    category: str,
    lat: float,
    lng: float,
    radius_m: int = _NEARBY_RADIUS_M,
    name: Optional[str] = None,
) -> List[SearchResult]:
    """Find places of a category near the user, nearest first.

    ``filter`` bounds the search radius so 'nearest hospital' never returns
    something 40 km away; ``bias`` orders results by distance.
    """
    categories = resolve_category(category)
    if categories is None:
        raise HTTPException(
            status_code=status.HTTP_400_BAD_REQUEST,
            detail=f"I don't know how to search for '{category}'.",
        )

    # Quantise the origin so repeated commands from a near-identical position
    # share one cache entry instead of burning the free quota.
    origin = f"{round(lat, 3)},{round(lng, 3)}"
    params: Dict[str, Any] = {
        "categories": ",".join(categories),
        "filter": f"circle:{lng},{lat},{int(radius_m)}",
        "bias": f"proximity:{lng},{lat}",
        "limit": _PLACE_LIMIT,
    }
    if name:
        params["name"] = name

    cache_key = f"pl|{origin}|{params['categories']}|{radius_m}|{name or ''}"
    cached = _cache_get(cache_key)
    if cached is not None:
        return cached

    body = await _get_json("/v2/places", params)
    features = body.get("features") if isinstance(body, dict) else None
    if not isinstance(features, list):
        raise _unavailable("The location service returned an invalid response.")

    results: List[SearchResult] = []
    for feature in features:
        if not isinstance(feature, dict):
            continue
        props = feature.get("properties")
        if not isinstance(props, dict):
            continue

        lat_i = props.get("lat")
        lng_i = props.get("lon")
        if lat_i is None or lng_i is None:
            coords = (feature.get("geometry") or {}).get("coordinates")
            if isinstance(coords, list) and len(coords) >= 2:
                lng_i, lat_i = coords[0], coords[1]
        try:
            lat_i = float(lat_i)
            lng_i = float(lng_i)
        except (TypeError, ValueError):
            continue

        # Geoapify supplies distance only when a bias is present.
        distance = props.get("distance")
        if distance is None:
            distance_m = _haversine(lat, lng, lat_i, lng_i)
        else:
            try:
                distance_m = float(distance)
            except (TypeError, ValueError):
                distance_m = _haversine(lat, lng, lat_i, lng_i)

        cats = props.get("categories")
        results.append(SearchResult(
            name=_best_name(props, "Unnamed place"),
            latitude=lat_i,
            longitude=lng_i,
            formatted_address=(props.get("formatted") or "").strip(),
            distance_m=distance_m,
            category=cats[0] if isinstance(cats, list) and cats else None,
            place_id=props.get("place_id"),
        ))

    results.sort(key=lambda r: r.distance_m if r.distance_m is not None else math.inf)
    _cache_put(cache_key, results)
    return results


# ================================================================
# ROUTING
# ================================================================

def _haversine_m(lat1: float, lng1: float, lat2: float, lng2: float) -> float:
    return _haversine(lat1, lng1, lat2, lng2)


def _coord(raw: Any) -> Optional[Tuple[float, float]]:
    """Accept a GeoJSON [lon, lat] pair or a {lon, lat} object."""
    if isinstance(raw, (list, tuple)) and len(raw) >= 2:
        try:
            return float(raw[0]), float(raw[1])
        except (TypeError, ValueError):
            return None
    if isinstance(raw, dict):
        try:
            return float(raw.get("lon")), float(raw.get("lat"))
        except (TypeError, ValueError):
            return None
    return None


def _flatten_positions(raw: Any, out: List[List[float]]) -> None:
    """Recursively flatten GeoJSON coordinate nesting into [lon, lat] pairs.

    Geoapify returns the route as a MultiLineString, so ``coordinates`` is
    ``[[[lon, lat], ...]]`` -- one level deeper than a plain LineString.
    Unwrapping a single level is therefore not enough, and a partial unwrap
    silently yields an empty route, so this walks down to the positions.
    """
    if not isinstance(raw, (list, tuple)) or not raw:
        return
    # A position is [lon, lat], optionally with elevation.
    first_two = raw[:2]
    if all(isinstance(v, (int, float)) and not isinstance(v, bool)
           for v in first_two):
        out.append([float(first_two[0]), float(first_two[1])])
        return
    for item in raw:
        _flatten_positions(item, out)


def _route_geometry(route: Dict[str, Any]) -> List[List[float]]:
    """Normalise the route shape to a flat list of [lon, lat] pairs.

    Handles LineString, MultiLineString and a bare position, because Geoapify
    picks MultiLineString for routing and LineString elsewhere.
    """
    geom = route.get("geometry")
    if isinstance(geom, dict):
        geom = geom.get("coordinates")
    elif geom is None:
        return []

    pairs: List[List[float]] = []
    _flatten_positions(geom, pairs)
    if pairs:
        return pairs

    # Fallback for a single {lon, lat} object.
    single = _coord(geom)
    if single is not None:
        return [[single[0], single[1]]]
    return []


def _leg_geometry(leg: Dict[str, Any], route: List[List[float]],
                  offset: int) -> List[List[float]]:
    """A leg's geometry, falling back to the shared route geometry slice."""
    coords = _route_geometry(leg)
    if coords:
        return coords
    # Legs carry no inline geometry unless an encoded polyline was requested,
    # so slice the route using the leg's own first step index.
    first = 0
    steps = leg.get("steps")
    if isinstance(steps, list) and steps and isinstance(steps[0], dict):
        try:
            first = int(steps[0].get("from_index") or 0)
        except (TypeError, ValueError):
            first = 0
    return route[first + offset:]


def _build_steps(legs: List[Dict[str, Any]], route: List[List[float]],
                 origin: Tuple[float, float]) -> List[DirectionsStep]:
    steps: List[DirectionsStep] = []
    # Index offset accumulates across legs so from_index/to_index stay valid
    # against the concatenated route geometry.
    offset = 0

    for leg in legs:
        leg_geom = _leg_geometry(leg, route, offset)
        for raw in leg.get("steps") or []:
            if not isinstance(raw, dict):
                continue

            instruction = raw.get("instruction")
            instruction = instruction if isinstance(instruction, dict) else {}
            text = (instruction.get("text") or "").strip()
            if not text:
                # A step with no instruction still advances geometry progress;
                # skip it so we never speak a blank turn.
                continue

            try:
                from_index = int(raw.get("from_index") or 0)
            except (TypeError, ValueError):
                from_index = 0
            try:
                to_index = int(raw.get("to_index") or 0)
            except (TypeError, ValueError):
                to_index = from_index

            global_from = from_index + offset
            global_to = to_index + offset

            start = None
            end = None
            if 0 <= global_from < len(route):
                start = (route[global_from][1], route[global_from][0])
            if 0 <= global_to < len(route):
                end = (route[global_to][1], route[global_to][0])
            if start is None and leg_geom:
                start = (leg_geom[0][1], leg_geom[0][0])
            if end is None and leg_geom:
                tail = leg_geom[-1]
                end = (tail[1], tail[0])
            if start is None:
                start = origin
            if end is None:
                end = start

            streets = instruction.get("streets")
            streets = [str(s) for s in streets] if isinstance(streets, list) else []

            try:
                distance_m = float(raw.get("distance") or 0.0)
            except (TypeError, ValueError):
                distance_m = 0.0
            try:
                duration_sec = float(raw.get("time") or 0.0)
            except (TypeError, ValueError):
                duration_sec = 0.0

            steps.append(DirectionsStep(
                instruction=text,
                distance_m=distance_m,
                duration_sec=duration_sec,
                maneuver=str(instruction.get("type") or ""),
                pre_transition=(instruction.get("pre_transition_instruction") or "").strip(),
                post_transition=(instruction.get("post_transition_instruction") or "").strip(),
                streets=streets,
                from_index=global_from,
                to_index=global_to,
                start_lat=start[0],
                start_lng=start[1],
                end_lat=end[0],
                end_lng=end[1],
            ))
        offset += len(leg_geom)

    return steps


async def get_directions(
    origin_lat: float,
    origin_lng: float,
    dest_lat: float,
    dest_lng: float,
    mode: str = "walking",
) -> DirectionsResult:
    """Calculate a walking/driving/cycling route with real geometry.

    Returns the full route shape plus steps annotated with geometry indexes so
    the device can measure true progress and true distance-from-route.
    """
    geo_mode = _MODE_MAP.get((mode or "walking").strip().lower(), "walk")

    body = await _get_json(
        "/v1/routing",
        {
            # Geoapify Routing waypoints are latitude,longitude.
            "waypoints": f"{origin_lat},{origin_lng}|{dest_lat},{dest_lng}",
            "mode": geo_mode,
            "format": "geojson",
            # Adds structured maneuver + pre/post transition text, which is
            # what makes early "in 150 meters" guidance possible.
            "details": "instruction_details",
            "units": "metric",
        },
    )

    features = body.get("features") if isinstance(body, dict) else None
    feature = None
    if isinstance(features, list):
        for candidate in features:
            if isinstance(candidate, dict):
                feature = candidate
                break
    if feature is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="No route could be found between those places.",
        )

    # In GeoJSON the route shape is a sibling of the summary, i.e.
    # features[0].geometry, while distance/time/legs live in
    # features[0].properties. They must not be read from the same object.
    geometry = _route_geometry(feature)
    route = feature.get("properties")
    if not isinstance(route, dict):
        route = {}

    legs_raw = route.get("legs")
    legs = [l for l in legs_raw if isinstance(l, dict)] if isinstance(legs_raw, list) else []
    steps = _build_steps(legs, geometry, (origin_lat, origin_lng))

    try:
        distance_m = float(route.get("distance") or 0.0)
    except (TypeError, ValueError):
        distance_m = 0.0
    try:
        duration_sec = float(route.get("time") or 0.0)
    except (TypeError, ValueError):
        duration_sec = 0.0

    return DirectionsResult(
        origin="your location",
        destination="your destination",
        distance_m=distance_m,
        duration_sec=duration_sec,
        geometry=geometry,
        steps=steps,
        mode=geo_mode,
        distance_units=str(route.get("distance_units") or "meters"),
    )


# ================================================================
# SAVED PLACES (user-scoped CRUD)
# ================================================================

def list_saved_places(current_user, db: Session):
    places = (
        db.query(SavedPlace)
        .filter(SavedPlace.user_id == current_user.id)
        .order_by(SavedPlace.name.asc())
        .all()
    )
    return places


def add_saved_place(data: SavedPlaceCreate, current_user, db: Session):
    place = SavedPlace(
        user_id=current_user.id,
        name=data.name,
        latitude=data.latitude,
        longitude=data.longitude,
    )
    db.add(place)
    db.commit()
    db.refresh(place)
    return place


def update_saved_place(
    place_id: int,
    data: SavedPlaceUpdate,
    current_user,
    db: Session,
):
    place = _get_owned_place(place_id, current_user, db)
    if data.name is not None:
        place.name = data.name.strip()
    if data.latitude is not None:
        place.latitude = data.latitude
    if data.longitude is not None:
        place.longitude = data.longitude
    db.commit()
    db.refresh(place)
    return place


def delete_saved_place(place_id: int, current_user, db: Session):
    place = _get_owned_place(place_id, current_user, db)
    db.delete(place)
    db.commit()


def _get_owned_place(place_id: int, current_user, db: Session) -> SavedPlace:
    place = (
        db.query(SavedPlace)
        .filter(
            SavedPlace.id == place_id,
            SavedPlace.user_id == current_user.id,
        )
        .first()
    )
    if place is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail="Saved place not found",
        )
    return place