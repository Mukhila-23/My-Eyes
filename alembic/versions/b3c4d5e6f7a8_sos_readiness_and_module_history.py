"""sos readiness columns, companion column, module-history and contact indexes

Revision ID: b3c4d5e6f7a8
Revises: a2b3c4d5e6f7
Create Date: 2026-10-06 09:00:00.000000

Why each piece exists:

* users.companion
  `app/main.py::_ensure_columns` has been adding this column with raw SQL at
  startup, so a database created through Alembic alone never had it and
  `create_all` could not add it either (it only creates missing *tables*). It
  is migrated properly here; the runtime ALTER stays as a no-op safety net for
  databases that predate both.

* sos_events.location_status / notified_count / message
  Lets an event record whether the coordinates that shipped with the alert
  were a real fix, how many contacts were actually reached, and the exact text
  that was sent. All nullable-with-default so existing rows keep working.

* emergency_contacts.user_id index + (user_id, phone_number) unique
  The login flow reads a user's contacts on every login and the unique
  constraint is what stops one number being stored twice (which would page
  the same person twice). Rows that already violate it are removed first, so
  this migration cannot fail on an existing database.

* scan_history (user_id, scan_type, created_at)
  Backs every module History button.

Create Date is intentionally fixed so re-running the migration is a no-op.
"""

from typing import Sequence, Union

from alembic import op
import sqlalchemy as sa


# revision identifiers, used by Alembic.
revision: str = 'b3c4d5e6f7a8'
down_revision: Union[str, Sequence[str], None] = 'a2b3c4d5e6f7'
branch_labels: Union[str, Sequence[str], None] = None
depends_on: Union[str, Sequence[str], None] = None


def _has_column(table: str, column: str) -> bool:
    """True when `table.column` already exists.

    Both migration paths matter: a database may have been bootstrapped by
    `Base.metadata.create_all` (which runs at app import) rather than by
    Alembic, so an index/constraint can already be present even though Alembic
    has never stamped that revision.
    """
    inspector = sa.inspect(op.get_bind())
    if table not in inspector.get_table_names():
        return False
    return column in {c['name'] for c in inspector.get_columns(table)}


def _has_index(table: str, index_name: str) -> bool:
    """True when the named index exists on `table`.

    `unique=True` indexes are reported through get_indexes on PostgreSQL and
    through get_unique_constraints on some drivers, so both are checked.
    """
    inspector = sa.inspect(op.get_bind())
    if table not in inspector.get_table_names():
        return False

    if index_name in {i['name'] for i in inspector.get_indexes(table)}:
        return True

    return index_name in {u['name'] for u in inspector.get_unique_constraints(table)}


def _has_constraint(table: str, constraint_name: str) -> bool:
    """True when a unique constraint (or backing unique index) exists."""
    inspector = sa.inspect(op.get_bind())
    if table not in inspector.get_table_names():
        return False

    if constraint_name in {u['name'] for u in inspector.get_unique_constraints(table)}:
        return True

    return any(
        index.get('unique') and index.get('name') == constraint_name
        for index in inspector.get_indexes(table)
    )


def upgrade() -> None:
    """Upgrade schema."""

    # ---------------- users.companion ---------------- #
    if _has_column('users', 'companion'):
        # Added by the startup ALTER on databases created before this
        # migration existed.
        op.execute('UPDATE users SET companion = \'alex\' WHERE companion IS NULL')
    else:
        op.add_column(
            'users',
            sa.Column('companion', sa.String(length=20), nullable=True),
        )

    # ---------------- sos_events readiness columns ---------------- #
    if _has_column('sos_events', 'location_status'):
        op.execute(
            "UPDATE sos_events SET location_status = 'OK' "
            "WHERE (latitude IS NOT NULL AND longitude IS NOT NULL) "
            "AND location_status = 'UNAVAILABLE'"
        )
    else:
        op.add_column(
            'sos_events',
            sa.Column(
                'location_status',
                sa.String(length=20),
                nullable=False,
                server_default='UNAVAILABLE',
            ),
        )

    if not _has_column('sos_events', 'notified_count'):
        op.add_column(
            'sos_events',
            sa.Column(
                'notified_count',
                sa.Integer(),
                nullable=False,
                server_default='0',
            ),
        )

    if not _has_column('sos_events', 'message'):
        op.add_column(
            'sos_events',
            sa.Column('message', sa.Text(), nullable=True),
        )

    # ---------------- emergency_contacts indexes ---------------- #
    if not _has_index('emergency_contacts', 'ix_emergency_contacts_user_id'):
        op.create_index(
            'ix_emergency_contacts_user_id',
            'emergency_contacts',
            ['user_id'],
            unique=False,
        )

    # Drop duplicates (keep the lowest id) before adding the unique
    # constraint, so an existing database cannot make this migration fail.
    op.execute(
        """
        DELETE FROM emergency_contacts a
        USING emergency_contacts b
        WHERE a.user_id = b.user_id
          AND a.phone_number = b.phone_number
          AND a.id > b.id
        """
    )

    if not _has_constraint('emergency_contacts', 'uq_emergency_contacts_user_phone'):
        op.create_unique_constraint(
            'uq_emergency_contacts_user_phone',
            'emergency_contacts',
            ['user_id', 'phone_number'],
        )

    if not _has_index('emergency_contacts', 'ix_emergency_contacts_user_priority'):
        op.create_index(
            'ix_emergency_contacts_user_priority',
            'emergency_contacts',
            ['user_id', 'priority'],
            unique=False,
        )

    # ---------------- sos_events index ---------------- #
    if _has_column('sos_events', 'triggered_at') and \
            not _has_index('sos_events', 'ix_sos_events_user_triggered'):
        op.create_index(
            'ix_sos_events_user_triggered',
            'sos_events',
            ['user_id', 'triggered_at'],
            unique=False,
        )

    # ---------------- scan_history module-history index ---------------- #
    if not _has_index('scan_history', 'ix_scan_history_user_type_created'):
        op.create_index(
            'ix_scan_history_user_type_created',
            'scan_history',
            ['user_id', 'scan_type', 'created_at'],
            unique=False,
        )

    if not _has_index('scan_history', 'ix_scan_history_user_id'):
        op.create_index(
            'ix_scan_history_user_id',
            'scan_history',
            ['user_id'],
            unique=False,
        )


def downgrade() -> None:
    """Downgrade schema."""

    if _has_index('scan_history', 'ix_scan_history_user_id'):
        op.drop_index('ix_scan_history_user_id', table_name='scan_history')
    if _has_index('scan_history', 'ix_scan_history_user_type_created'):
        op.drop_index(
            'ix_scan_history_user_type_created',
            table_name='scan_history',
        )

    if _has_index('sos_events', 'ix_sos_events_user_triggered'):
        op.drop_index('ix_sos_events_user_triggered', table_name='sos_events')

    if _has_constraint('emergency_contacts', 'uq_emergency_contacts_user_phone'):
        op.drop_constraint(
            'uq_emergency_contacts_user_phone',
            'emergency_contacts',
            type_='unique',
        )
    if _has_index('emergency_contacts', 'ix_emergency_contacts_user_priority'):
        op.drop_index(
            'ix_emergency_contacts_user_priority',
            table_name='emergency_contacts',
        )

    if _has_column('sos_events', 'message'):
        op.drop_column('sos_events', 'message')
    if _has_column('sos_events', 'notified_count'):
        op.drop_column('sos_events', 'notified_count')
    if _has_column('sos_events', 'location_status'):
        op.drop_column('sos_events', 'location_status')

    # users.companion is intentionally left in place: dropping it would break
    # every existing session's companion preference, and the column is
    # nullable so it costs nothing to keep.
