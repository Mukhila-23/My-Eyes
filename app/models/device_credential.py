from datetime import datetime

from sqlalchemy import Column, DateTime, ForeignKey, Integer, String
from sqlalchemy.orm import relationship

from app.database.database import Base


class DeviceCredential(Base):
    """A public device id plus a hash of a random, device-held secret.

    This is deliberately not biometric data. Android verifies the user's
    fingerprint locally before Flutter reads and uses the device secret.
    """

    __tablename__ = "device_credentials"

    id = Column(Integer, primary_key=True, index=True)
    user_id = Column(Integer, ForeignKey("users.id"), nullable=False, index=True)
    device_id = Column(String(64), nullable=False, unique=True, index=True)
    secret_hash = Column(String(255), nullable=False)
    created_at = Column(DateTime, default=datetime.utcnow, nullable=False)
    last_used_at = Column(DateTime, default=datetime.utcnow, nullable=False)

    user = relationship("User", back_populates="device_credentials")
