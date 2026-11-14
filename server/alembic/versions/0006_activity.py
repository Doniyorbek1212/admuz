"""activity_days: distinct users per day for app opens and hub/movies section views (admin statistics)

Revision ID: 0006
Revises: 0005
Create Date: 2026-11-02 11:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0006'
down_revision: str | Sequence[str] | None = '0005'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'activity_days',
        sa.Column('day', sa.Date(), nullable=False),
        sa.Column('customer_id', sa.UUID(), nullable=False),
        sa.Column('event', sa.String(length=32), nullable=False),
        sa.ForeignKeyConstraint(['customer_id'], ['customers.id'], ondelete='CASCADE'),
        sa.PrimaryKeyConstraint('day', 'customer_id', 'event'),
    )
    op.create_index('ix_activity_days_event_day', 'activity_days', ['event', 'day'])


def downgrade() -> None:
    op.drop_index('ix_activity_days_event_day', table_name='activity_days')
    op.drop_table('activity_days')
