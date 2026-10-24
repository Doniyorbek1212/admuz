"""app settings editable from the admin panel (prices, payment card, app release); admin login/password

Revision ID: 0003
Revises: 0002
Create Date: 2026-10-23 18:00:00

"""
from collections.abc import Sequence

import sqlalchemy as sa

from alembic import op

revision: str = '0003'
down_revision: str | Sequence[str] | None = '0002'
branch_labels: str | Sequence[str] | None = None
depends_on: str | Sequence[str] | None = None


def upgrade() -> None:
    op.create_table(
        'app_settings',
        sa.Column('key', sa.String(length=64), nullable=False),
        sa.Column('value', sa.String(length=2000), nullable=False),
        sa.Column('updated_by', sa.String(length=64), nullable=False),
        sa.Column('updated_at', sa.DateTime(timezone=True), server_default=sa.text('now()'), nullable=False),
        sa.PrimaryKeyConstraint('key'),
    )
    op.add_column('admin_users', sa.Column('login', sa.String(length=64), nullable=True))
    op.add_column('admin_users', sa.Column('password_hash', sa.String(length=255), nullable=True))
    op.create_unique_constraint('uq_admin_users_login', 'admin_users', ['login'])


def downgrade() -> None:
    op.drop_constraint('uq_admin_users_login', 'admin_users', type_='unique')
    op.drop_column('admin_users', 'password_hash')
    op.drop_column('admin_users', 'login')
    op.drop_table('app_settings')
