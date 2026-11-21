"""Interest-based hub ads: ad topics and view/click counters, per-customer interest scores

Revision ID: 0013
Revises: 0012
Create Date: 2026-11-09 12:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = '0013'
down_revision: str | Sequence[str] | None = '0012'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.add_column('ad_campaigns', sa.Column('topics', postgresql.JSONB(), server_default='[]', nullable=False))
    op.add_column('ad_campaigns', sa.Column('views', sa.Integer(), server_default='0', nullable=False))
    op.add_column('ad_campaigns', sa.Column('clicks', sa.Integer(), server_default='0', nullable=False))
    op.create_table(
        'customer_interests',
        sa.Column('customer_id', sa.UUID(), sa.ForeignKey('customers.id', ondelete='CASCADE'), primary_key=True),
        sa.Column('topic', sa.String(32), primary_key=True),
        sa.Column('score', sa.Float(), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.func.now(), nullable=False),
    )


def downgrade() -> None:
    op.drop_table('customer_interests')
    op.drop_column('ad_campaigns', 'clicks')
    op.drop_column('ad_campaigns', 'views')
    op.drop_column('ad_campaigns', 'topics')
