from fastapi import FastAPI
from fastapi.middleware.cors import CORSMiddleware
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException

# Load app/.env explicitly before anything reads configuration. Previously this
# only happened as a side effect of importing app.database.database, which made
# the AI Help key invisible to any code path that did not touch the database.
from pathlib import Path
from dotenv import load_dotenv

_ENV_PATH = Path(__file__).resolve().parent / ".env"
load_dotenv(dotenv_path=_ENV_PATH)

import logging  # noqa: E402  (must follow the .env load above)

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
logging.getLogger("httpx").setLevel(logging.WARNING)
logging.getLogger("httpcore").setLevel(logging.WARNING)
logging.getLogger("ultralytics").setLevel(logging.WARNING)

from app.database.database import Base, engine  # noqa: E402
from sqlalchemy import inspect, text  # noqa: E402
from app.routers import auth,vision  # noqa: E402
from app.routers import profile_router,history_router,ocr_router,tts_router,medicine_router  # noqa: E402
from app.routers import currency_router,product_reader_router,object_detection_router,scene_router  # noqa: E402
from app.routers import emergency_contact_router, sos_router  # noqa: E402
from app.routers import emergency_relay_router  # noqa: E402
from app.routers import ai_router  # noqa: E402
from app.routers import navigation_router  # noqa: E402
from app.error_handlers import (  # noqa: E402
    validation_error_handler,
    http_exception_handler,
    unhandled_exception_handler,
)
from fastapi.staticfiles import StaticFiles  # noqa: E402
import os  # noqa: E402
# Create database tables
Base.metadata.create_all(bind=engine)


def _ensure_columns() -> None:
    """Add columns introduced after a database was first created.

    `create_all` only creates *missing tables*, so a new column on an existing
    table (users.companion, which stores the selected voice, or the sos_events
    readiness columns) would otherwise stay absent on an already-initialized
    database and every account query - or every SOS insert - would fail.

    This runs once at startup and is a no-op when the columns already exist,
    which is the normal case once Alembic revision b3c4d5e6f7a8 has been
    applied. It exists so a deployment that has not run `alembic upgrade head`
    still boots instead of 500-ing on a query.
    """
    inspector = inspect(engine)
    tables = set(inspector.get_table_names())

    if "users" in tables:
        existing = {column["name"] for column in inspector.get_columns("users")}
        if "companion" not in existing:
            with engine.begin() as connection:
                connection.execute(
                    text("ALTER TABLE users ADD COLUMN companion VARCHAR(20)")
                )
            logging.getLogger("myeyes").info(
                "Migration: added users.companion"
            )

    if "sos_events" in tables:
        existing = {column["name"] for column in inspector.get_columns("sos_events")}
        additions = []
        if "location_status" not in existing:
            additions.append(
                "location_status VARCHAR(20) NOT NULL DEFAULT 'UNAVAILABLE'"
            )
        if "notified_count" not in existing:
            additions.append("notified_count INTEGER NOT NULL DEFAULT 0")
        if "message" not in existing:
            additions.append("message TEXT")

        if additions:
            with engine.begin() as connection:
                for column in additions:
                    connection.execute(
                        text(f"ALTER TABLE sos_events ADD COLUMN {column}")
                    )
            logging.getLogger("myeyes").info(
                "Migration: added sos_events columns %s",
                ", ".join(column.split()[0] for column in additions),
            )


_ensure_columns()

app = FastAPI(
    title="My Eyes API",
    version="1.0.0",
    description="Backend API for My Eyes - Vision Beyond Sight"
)

# ---- Centralized structured error handling (422 Unprocessable Content,
#      HTTPException statuses and unexpected 500s all return a clean
#      {success:false, error:{code,message}} envelope). ----
app.add_exception_handler(RequestValidationError, validation_error_handler)
app.add_exception_handler(StarletteHTTPException, http_exception_handler)
app.add_exception_handler(Exception, unhandled_exception_handler)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)
# Create uploads folder if it doesn't exist
os.makedirs("app/uploads", exist_ok=True)

# Serve uploaded files
app.mount(
    "/uploads",
    StaticFiles(directory="app/uploads"),
    name="uploads"
)
# Create audio folder if it doesn't exist
os.makedirs("app/audio", exist_ok=True)
# Serve uploaded audio files
app.mount(
    "/audio",
    StaticFiles(directory="app/audio"),
    name="audio"
)

# Include Routers
app.include_router(auth.router)
app.include_router(profile_router.router)
app.include_router(history_router.router)
app.include_router(ocr_router.router)
app.include_router(tts_router.router)
app.include_router(medicine_router.router)
app.include_router(currency_router.router)
app.include_router(product_reader_router.router)
app.include_router(object_detection_router.router)
app.include_router(scene_router.router)
app.include_router(vision.router)
app.include_router(emergency_contact_router.router)
app.include_router(sos_router.router)
app.include_router(emergency_relay_router.router)
app.include_router(ai_router.router)
app.include_router(ai_router.legacy_router)
app.include_router(navigation_router.router)

@app.get("/")
def home():
    return {
        "message": "Welcome to My Eyes API"
    }


@app.on_event("startup")
def log_ai_help_configuration() -> None:
    """Report AI Help readiness at startup (never prints the key itself)."""
    from app.services.ai_service import (
        describe_configuration,
        configuration_problem,
    )
    from app.services.emergency_notifier import describe_configuration as _notifier

    ai_log = logging.getLogger("myeyes.ai")
    for line in describe_configuration():
        ai_log.info(line)

    # A bad credential must not look like a healthy boot. Report it loudly at
    # startup instead of letting the first user request discover it.
    problem = configuration_problem()
    if problem:
        ai_log.error("AI HELP IS NOT USABLE: %s", problem)
    else:
        ai_log.info("AI Help is configured and ready.")

    # SOS delivery readiness. Without a provider the phone still alerts its
    # contacts through the messaging app, but saying so at boot is far better
    # than discovering it during a real emergency.
    sos_log = logging.getLogger("myeyes.sos")
    for line in _notifier():
        sos_log.info(line)

    # Relay readiness. Only meaningful once EMERGENCY_ALERT_WEBHOOK_URL points
    # at the relay; when it does not, the relay is inert and there is nothing
    # to report, so it stays quiet rather than logging about a service that is
    # not in the path.
    if os.getenv("EMERGENCY_ALERT_WEBHOOK_URL", "").strip():
        from app.services.emergency_relay_service import (
            describe_configuration as _relay,
        )

        relay_log = logging.getLogger("myeyes.sos.relay")
        for line in _relay():
            relay_log.info(line)
