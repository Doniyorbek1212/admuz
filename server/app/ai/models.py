"""UZARO AI chats: one row per conversation, its messages in order."""

import uuid
from datetime import datetime

from sqlalchemy import BigInteger, DateTime, ForeignKey, Index, String, Text, func
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column

from app.db import Base


class AiChat(Base):
    __tablename__ = "ai_chats"
    __table_args__ = (Index("ix_ai_chats_customer", "customer_id", "updated_at"),)

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)
    customer_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("customers.id", ondelete="CASCADE"))
    title: Mapped[str] = mapped_column(String(80))
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
    updated_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())


class AiMessage(Base):
    __tablename__ = "ai_messages"
    __table_args__ = (Index("ix_ai_messages_chat", "chat_id", "id"),)

    id: Mapped[int] = mapped_column(BigInteger, primary_key=True, autoincrement=True)
    chat_id: Mapped[uuid.UUID] = mapped_column(ForeignKey("ai_chats.id", ondelete="CASCADE"))
    role: Mapped[str] = mapped_column(String(8))  # user | model
    text: Mapped[str] = mapped_column(Text)
    created_at: Mapped[datetime] = mapped_column(DateTime(timezone=True), server_default=func.now())
