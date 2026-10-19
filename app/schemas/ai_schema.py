from pydantic import BaseModel, Field, model_validator
from typing import List, Optional
from datetime import datetime


class AIChatRequest(BaseModel):
    """Body for POST /ai-help (and its alias POST /ai/chat).

    The user's question may be supplied as either `question` or `message`
    (both names are accepted so old and new clients work). An optional
    conversation_id continues an existing Help conversation; when it is
    omitted a new conversation is started.
    """

    question: Optional[str] = Field(default=None, max_length=2000)
    message: Optional[str] = Field(default=None, max_length=2000)
    conversation_id: Optional[int] = Field(default=None, ge=1)

    @model_validator(mode="after")
    def _resolve_question(self) -> "AIChatRequest":
        """Accept `question` or `message`, reject empty ones clearly."""
        raw = self.question if self.question is not None else self.message
        text = (raw or "").strip()

        if not text:
            raise ValueError(
                "Question cannot be empty. Send {'question': 'your question'}"
            )

        # Normalise so downstream code has a single field to read.
        object.__setattr__(self, "question", text)
        object.__setattr__(self, "message", text)
        return self

    @property
    def text(self) -> str:
        return self.question or self.message or ""


class AIChatResponse(BaseModel):
    """Response for POST /ai-help.

    `answer` is the primary field; `response` is retained as an alias so
    existing clients keep working.
    """

    success: bool = True
    answer: str
    response: str
    conversation_id: int


class AIDeleteResponse(BaseModel):
    """Response for DELETE /ai-help/{conversation_id}."""

    success: bool
    message: str


class AIMessageOut(BaseModel):
    id: int
    role: str
    message: str
    created_at: datetime

    class Config:
        from_attributes = True


class AIConversationOut(BaseModel):
    id: int
    created_at: datetime
    updated_at: Optional[datetime]
    messages: List[AIMessageOut] = Field(default_factory=list)

    class Config:
        from_attributes = True