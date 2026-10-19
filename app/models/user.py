from sqlalchemy import Column, Integer, String, DateTime
from datetime import datetime

from app.database.database import Base
from sqlalchemy.orm import relationship


class User(Base):
    __tablename__ = "users"

    id = Column(Integer, primary_key=True, index=True)

    full_name = Column(String(100), nullable=False)

    email = Column(String(100), unique=True, nullable=False)

    # Legacy accounts may retain a hash. New biometric-first accounts have no
    # password and therefore store NULL here.
    password = Column(String(255), nullable=True)

    phone_number = Column(String(15), nullable=True)

    # Selected companion for every spoken message: 'alex' (male) or 'maya'
    # (female). Nullable so legacy accounts keep working untouched; a NULL
    # value simply means the engine default (Alex) is used.
    companion = Column(String(20), nullable=True)

    created_at = Column(DateTime, default=datetime.utcnow)
    history = relationship("ScanHistory", back_populates="user")
    device_credentials = relationship(
        "DeviceCredential", back_populates="user", cascade="all, delete-orphan"
    )
    emergency_contacts = relationship(
        "EmergencyContact",
        back_populates="user",
        cascade="all, delete-orphan"
    )
    sos_events = relationship(
        "SOSEvent",
        back_populates="user",
        cascade="all, delete-orphan"
    )
    ai_conversations = relationship(
        "AIConversation",
        back_populates="user",
        cascade="all, delete-orphan"
    )
    saved_places = relationship(
        "SavedPlace",
        back_populates="user",
        cascade="all, delete-orphan"
    )
