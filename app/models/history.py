from sqlalchemy import (
    Column,
    Integer,
    String,
    Text,
    DateTime,
    ForeignKey,
    Index,
)
from datetime import datetime

from app.database.database import Base
from sqlalchemy.orm import relationship

class ScanHistory(Base):
    __tablename__ = "scan_history"

    id = Column(Integer, primary_key=True, index=True)

    user_id = Column(
        Integer,
        ForeignKey("users.id", ondelete="CASCADE"),
        nullable=False,
        index=True,
    )

    scan_type = Column(
        String(50),
        nullable=False
    )

    input_image = Column(
        String(255),
        nullable=True
    )

    result = Column(
        Text,
        nullable=False
    )

    created_at = Column(
        DateTime,
        default=datetime.utcnow
    )
    user = relationship(
    "User",
    back_populates="history"
)

    __table_args__ = (
        # Every module history screen reads "my scans of this type, newest
        # first". One index serves that query and the per-module counts, so the
        # module History button never falls back to a full-table scan.
        Index("ix_scan_history_user_type_created", "user_id", "scan_type", "created_at"),
    )
