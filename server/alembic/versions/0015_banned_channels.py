"""Banned Telegram channels: hidden from search in the app, seeded from the Supreme Court list of 3 Nov 2026

Revision ID: 0015
Revises: 0014
Create Date: 2026-11-10 18:00:00

"""
import uuid
from collections.abc import Sequence
from pathlib import Path

import sqlalchemy as sa

from alembic import op

revision: str = '0015'
down_revision: str | Sequence[str] | None = '0014'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

# title <TAB> username <TAB> note, one source per line (Telegram section of the list, duplicates merged).
SEED = Path(__file__).with_name('0015_banned_channels.tsv')


def upgrade() -> None:
    table = op.create_table(
        'banned_channels',
        sa.Column('id', sa.UUID(), primary_key=True),
        sa.Column('title', sa.String(300), server_default='', nullable=False),
        sa.Column('username', sa.String(64), server_default='', nullable=False),
        sa.Column('note', sa.String(300), server_default='', nullable=False),
        sa.Column('active', sa.Boolean(), server_default=sa.true(), nullable=False),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )
    rows = []
    for line in SEED.read_text(encoding='utf-8').splitlines():
        title, username, note = line.split('\t')
        rows.append({'id': uuid.uuid4(), 'title': title, 'username': username, 'note': note, 'active': True})
    op.bulk_insert(table, rows)


def downgrade() -> None:
    op.drop_table('banned_channels')
