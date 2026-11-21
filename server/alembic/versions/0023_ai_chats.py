"""UZARO AI chats and messages

Revision ID: 0023
Revises: 0022
Create Date: 2026-11-16 12:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = '0023'
down_revision: str | Sequence[str] | None = '0022'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

UUID = postgresql.UUID(as_uuid=True)


def upgrade() -> None:
    op.create_table(
        'ai_chats',
        sa.Column('id', UUID, primary_key=True),
        sa.Column('customer_id', UUID, sa.ForeignKey('customers.id', ondelete='CASCADE'), nullable=False),
        sa.Column('title', sa.String(80), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index('ix_ai_chats_customer', 'ai_chats', ['customer_id', 'updated_at'])
    op.create_table(
        'ai_messages',
        sa.Column('id', sa.BigInteger(), sa.Identity(), primary_key=True),
        sa.Column('chat_id', UUID, sa.ForeignKey('ai_chats.id', ondelete='CASCADE'), nullable=False),
        sa.Column('role', sa.String(8), nullable=False),
        sa.Column('text', sa.Text(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    op.create_index('ix_ai_messages_chat', 'ai_messages', ['chat_id', 'id'])


def downgrade() -> None:
    op.drop_table('ai_messages')
    op.drop_table('ai_chats')
