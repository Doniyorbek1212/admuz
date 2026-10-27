"""places: the hub's "Region" directory of local services (taxi, pharmacy, clinic, hotel...)

Revision ID: 0004
Revises: 0003
Create Date: 2026-10-26 12:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa
from sqlalchemy.dialects import postgresql

from alembic import op

revision: str = '0004'
down_revision: str | Sequence[str] | None = '0003'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None

_category = postgresql.ENUM(
    'taxi', 'pharmacy', 'hotel', 'doctor', 'car_service', 'bank', 'travel', 'food', name='place_category', create_type=False
)


def upgrade() -> None:
    _category.create(op.get_bind(), checkfirst=True)
    op.create_table(
        'places',
        sa.Column('id', sa.UUID(), nullable=False),
        sa.Column('category', _category, nullable=False),
        sa.Column('region', sa.String(length=40), nullable=False),
        sa.Column('district', sa.String(length=80), nullable=True),
        sa.Column('name', sa.String(length=200), nullable=False),
        sa.Column('subcategory', sa.String(length=80), nullable=False, server_default=''),
        sa.Column('description', sa.String(length=3000), nullable=False, server_default=''),
        sa.Column('address', sa.String(length=300), nullable=False, server_default=''),
        sa.Column('landmark', sa.String(length=200), nullable=False, server_default=''),
        sa.Column('phones', postgresql.JSONB(astext_type=sa.Text()), nullable=False, server_default='[]'),
        sa.Column('telegram', sa.String(length=64), nullable=False, server_default=''),
        sa.Column('instagram', sa.String(length=64), nullable=False, server_default=''),
        sa.Column('website', sa.String(length=300), nullable=False, server_default=''),
        sa.Column('working_hours', sa.String(length=200), nullable=False, server_default=''),
        sa.Column('is_24h', sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column('latitude', sa.Float(), nullable=True),
        sa.Column('longitude', sa.Float(), nullable=True),
        sa.Column('verified', sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column('featured', sa.Boolean(), nullable=False, server_default=sa.false()),
        sa.Column('active', sa.Boolean(), nullable=False, server_default=sa.true()),
        sa.Column('sort_order', sa.Integer(), nullable=False, server_default='0'),
        sa.Column('source_ref', sa.String(length=64), nullable=True),
        sa.Column('created_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.PrimaryKeyConstraint('id'),
        sa.UniqueConstraint('source_ref', name='uq_places_source_ref'),
    )
    op.create_index('ix_places_region_category_active', 'places', ['region', 'category', 'active'])
    op.create_index('ix_places_region_district', 'places', ['region', 'district'])


def downgrade() -> None:
    op.drop_index('ix_places_region_district', table_name='places')
    op.drop_index('ix_places_region_category_active', table_name='places')
    op.drop_table('places')
    _category.drop(op.get_bind(), checkfirst=True)
