"""Gift sender privacy: the sender can stay anonymous, the recipient can hide the sender's name

Revision ID: 0019
Revises: 0018
Create Date: 2026-11-11 12:40:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0019'
down_revision: str | Sequence[str] | None = '0018'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('sent_gifts', sa.Column('anonymous', sa.Boolean(), server_default=sa.false(), nullable=False))
    op.add_column('sent_gifts', sa.Column('sender_hidden', sa.Boolean(), server_default=sa.false(), nullable=False))


def downgrade() -> None:
    op.drop_column('sent_gifts', 'sender_hidden')
    op.drop_column('sent_gifts', 'anonymous')
