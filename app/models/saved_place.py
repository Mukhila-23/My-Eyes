from sqlalchemy import Column, Integer, String, Float, DateTime, ForeignKey
from datetime import datetime

from app.database.database import Base
from sqlalchemy.orm import relationship


class SavedPlace(Base):
    """A place the user saved for quick voice navigation (e.g. Home).

    Location data is sensitive: only the user's own saved places are ever
    returned, and nothing beyond the explicitly saved coordinates is stored.
    """

    __tablename__ = "saved_places"

    id = Column(Integer, primary_key=True, index=True)

    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
    )

    name = Column(String(100), nullable=False)

    latitude = Column(Float, nullable=False)

    longitude = Column(Float, nullable=False)

    created_at = Column(DateTime, default=datetime.utcnow)

    updated_at = Column(
        DateTime,
        default=datetime.utcnow,
        onupdate=datetime.utcnow,
    )

    user = relationship("User", back_populates="saved_places")
