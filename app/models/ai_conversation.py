from sqlalchemy import Column, Integer, String, Text, DateTime, ForeignKey
from datetime import datetime

from app.database.database import Base
from sqlalchemy.orm import relationship


class AIConversation(Base):
    """A single AI Help conversation for a user.

    A conversation groups a sequence of user/assistant messages so the
    backend can send the relevant context each time without the client
    re-sending the whole history. Conversations are isolated per user.
    """

    __tablename__ = "ai_conversations"

    id = Column(Integer, primary_key=True, index=True)

    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    created_at = Column(DateTime, default=datetime.utcnow)

    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
    )

    user = relationship("User", back_populates="ai_conversations")

    messages = relationship(
        "AIMessage",
        back_populates="conversation",
        cascade="all, delete-orphan",
        order_by="AIMessage.id",
    )


class AIMessage(Base):
    """One stored turn in an AI Help conversation.

    role is one of "user" or "assistant". Nothing sensitive is stored
    beyond the assistant reply text the user explicitly asked for.
    """

    __tablename__ = "ai_messages"

    id = Column(Integer, primary_key=True, index=True)

    conversation_id = Column(
        Integer,
        ForeignKey("ai_conversations.id", ondelete="CASCADE"),
        nullable=False,
    )

    role = Column(String(20), nullable=False)

    message = Column(Text, nullable=False)

    created_at = Column(DateTime, default=datetime.utcnow)

    conversation = relationship(
        "AIConversation",
        back_populates="messages",
    )
