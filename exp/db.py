"""Read-only Postgres access to the Terminal-2 Supabase project.

EXP never writes. Every pooled connection opens with
``default_transaction_read_only=on`` and a statement timeout, so a bug cannot become a
mutation and a slow query cannot pin the shared database. The ``Database`` protocol is
what the rest of the app depends on; tests inject an in-memory fake."""
from __future__ import annotations

from typing import Any, Protocol


class Database(Protocol):
    def fetch(self, sql: str, params: dict[str, Any]) -> list[dict[str, Any]]: ...


class PostgresDatabase:
    def __init__(self, dsn: str, statement_timeout_ms: int, max_size: int = 4):
        from psycopg.rows import dict_row
        from psycopg_pool import ConnectionPool

        options = (
            "-c default_transaction_read_only=on "
            f"-c statement_timeout={int(statement_timeout_ms)} "
            "-c application_name=exp-compare"
        )
        self._pool = ConnectionPool(
            conninfo=dsn,
            min_size=1,
            max_size=max_size,
            open=False,
            kwargs={"options": options, "row_factory": dict_row, "autocommit": True},
        )

    def open(self) -> None:
        self._pool.open()

    def close(self) -> None:
        self._pool.close()

    def fetch(self, sql: str, params: dict[str, Any]) -> list[dict[str, Any]]:
        with self._pool.connection() as conn, conn.cursor() as cur:
            cur.execute(sql, params)
            return list(cur.fetchall())
