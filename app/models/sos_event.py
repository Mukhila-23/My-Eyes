from sqlalchemy import (
    Column,
    Integer,
    String,
    Float,
    Text,
    DateTime,
    ForeignKey,
    Index,
)
from datetime import datetime

from app.database.database import Base
from sqlalchemy.orm import relationship


class SOSEvent(Base):
    __tablename__ = "sos_events"

    id = Column(Integer, primary_key=True, index=True)

    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )

    triggered_at = Column(DateTime, default=datetime.utcnow)

    latitude = Column(Float, nullable=True)
    longitude = Column(Float, nullable=True)

    # OK / PERMISSION_DENIED / SERVICE_DISABLED / TIMEOUT / UNAVAILABLE.
    # Recorded so the event log can honestly say whether the coordinates that
    # ship with the alert are real, rather than leaving it ambiguous.
    location_status = Column(
        String(20),
        nullable=False,
        default="UNAVAILABLE",
        server_default="UNAVAILABLE",
    )

    # TRIGGERED / CONFIRMED / CANCELLED / SENT / PARTIALLY_SENT / FAILED
    status = Column(String(20), nullable=False, default="TRIGGERED")

    contact_count = Column(Integer, nullable=False, default=0)

    # How many of those contacts the backend actually reached.
    notified_count = Column(Integer, nullable=False, default=0)

    # The exact text that was sent out, so support can audit what a contact
    # received. Nullable: an older row predates message capture.
    message = Column(Text, nullable=True)

    user = relationship("User", back_populates="sos_events")

    __table_args__ = (
        Index("ix_sos_events_user_triggered", "user_id", "triggered_at"),
    )
