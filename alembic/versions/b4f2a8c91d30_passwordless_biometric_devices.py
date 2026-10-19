"""add passwordless device credentials

Revision ID: b4f2a8c91d30
Revises: c721dc2f90ab
"""
from alembic import op
import sqlalchemy as sa

revision = "b4f2a8c91d30"
down_revision = "c721dc2f90ab"
branch_labels = None
depends_on = None


def upgrade() -> None:
    op.alter_column("users", "password", existing_type=sa.String(255), nullable=True)
    op.create_table(
        "device_credentials",
        sa.Column("id", sa.Integer(), primary_key=True),
        sa.Column("user_id", sa.Integer(), sa.ForeignKey("users.id"), nullable=False),
        sa.Column("device_id", sa.String(length=64), nullable=False),
        sa.Column("secret_hash", sa.String(length=255), nullable=False),
        sa.Column("created_at", sa.DateTime(), nullable=False),
        sa.Column("last_used_at", sa.DateTime(), nullable=False),
        sa.UniqueConstraint("device_id"),
    )
    op.create_index("ix_device_credentials_user_id", "device_credentials", ["user_id"])
    op.create_index("ix_device_credentials_device_id", "device_credentials", ["device_id"])


def downgrade() -> None:
    op.drop_index("ix_device_credentials_device_id", table_name="device_credentials")
    op.drop_index("ix_device_credentials_user_id", table_name="device_credentials")
    op.drop_table("device_credentials")
    op.alter_column("users", "password", existing_type=sa.String(255), nullable=False)
