from sqlalchemy import (
    Column,
    Integer,
    String,
    DateTime,
    ForeignKey,
    Index,
    UniqueConstraint,
)
from datetime import datetime

from app.database.database import Base
from sqlalchemy.orm import relationship


class EmergencyContact(Base):
    __tablename__ = "emergency_contacts"

    id = Column(Integer, primary_key=True, index=True)

    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )

    name = Column(String(100), nullable=False)

    phone_number = Column(String(20), nullable=False)

    # Exposed as `relationship` by the API layer; the column name predates it.
    relation = Column(String(50), nullable=False)

    # 1 = primary, 2..N = secondary
    priority = Column(Integer, nullable=False, default=2)

    created_at = Column(DateTime, default=datetime.utcnow)
    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow
    )

    user = relationship("User", back_populates="emergency_contacts")

    __table_args__ = (
        # Every module-scoped read is "my contacts, ordered by priority", so
        # the covering index is (user_id, priority) rather than user_id alone.
        Index("ix_emergency_contacts_user_priority", "user_id", "priority"),
        # A user cannot store the same number twice under two priorities:
        # that would silently notify the same person twice in one SOS.
        UniqueConstraint(
            "user_id",
            "phone_number",
            name="uq_emergency_contacts_user_phone",
        ),
    )
