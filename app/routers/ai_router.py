from fastapi import APIRouter, Depends
from sqlalchemy.orm import Session

from app.database.database import get_db
from app.dependencies import get_current_user
from app.models.user import User
from app.schemas.ai_schema import (
    AIChatRequest,
    AIChatResponse,
    AIDeleteResponse,
)
from app.services.ai_service import chat, clear_conversation

# ---------------------------------------------------------------------------
# There is exactly ONE AI Help implementation: `app.services.ai_service.chat`.
#
#   POST   /ai-help                     {"question": "..."}  -> {"success", "answer"}
#   DELETE /ai-help/{conversation_id}   "New chat"           -> {"success"}
#   POST   /ai/chat                     alias (older clients)
#   DELETE /ai/chat/{conversation_id}   alias (older clients)
#
# The prefixed router only re-registers the same handlers under the legacy
# paths so nothing else in the app has to change.
#
# The provider behind these routes is the Gemini API (Free Tier), called only
# from the backend. The Flutter app never holds a Gemini key.
# ---------------------------------------------------------------------------

router = APIRouter(tags=["AI Help"])
legacy_router = APIRouter(prefix="/ai", tags=["AI Help"])


def _ai_chat(data: AIChatRequest, db: Session, current_user: User) -> dict:
    """Shared handler: the user's exact question is forwarded to Gemini."""
    return chat(data.text, data.conversation_id, current_user, db)


def _ai_clear(conversation_id: int, db: Session, current_user: User) -> dict:
    """Shared handler: clears Help conversation context for this user only."""
    return clear_conversation(conversation_id, current_user, db)


# ---------------------------- canonical -----------------------------------


@router.post("/ai-help", response_model=AIChatResponse)
def ai_help_chat(
    data: AIChatRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Ask the AI Help assistant a question (voice and typed questions both
    arrive here).

    conversation_id is optional. When omitted a new Help conversation is
    started; when supplied, the stored context of that conversation is
    reused so follow-up questions resolve their references.
    """
    return _ai_chat(data, db, current_user)


@router.delete("/ai-help/{conversation_id}", response_model=AIDeleteResponse)
def ai_help_clear(
    conversation_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Clear the current Help conversation ("New chat")."""
    return _ai_clear(conversation_id, db, current_user)


# ------------------------- legacy path aliases -----------------------------


@legacy_router.post(
    "/chat",
    response_model=AIChatResponse,
    include_in_schema=False,
)
def ai_chat_legacy(
    data: AIChatRequest,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Alias of POST /ai-help."""
    return _ai_chat(data, db, current_user)


@legacy_router.delete(
    "/chat/{conversation_id}",
    response_model=AIDeleteResponse,
    include_in_schema=False,
)
def ai_clear_legacy(
    conversation_id: int,
    db: Session = Depends(get_db),
    current_user: User = Depends(get_current_user),
):
    """Alias of DELETE /ai-help/{conversation_id}."""
    return _ai_clear(conversation_id, db, current_user)