"""Persistencia: Supabase Postgres si hay DATABASE_URL; si no, SQLite local (desarrollo/pruebas)."""
from __future__ import annotations

import os
import re
import sqlite3
from contextlib import contextmanager

DATABASE_URL = os.environ.get("DATABASE_URL")  # cadena de conexión de Supabase (ver supabase/schema.sql)
DB_PATH = os.environ.get("AGENDA_DB", "agenda.db")

SCHEMA = """
CREATE TABLE IF NOT EXISTS calendars(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  name TEXT NOT NULL,
  context TEXT NOT NULL,         -- universidad | trabajo | personal
  url TEXT NOT NULL
);
CREATE TABLE IF NOT EXISTS tasks(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  context TEXT NOT NULL DEFAULT 'personal',
  estimate_min INTEGER NOT NULL DEFAULT 60,
  deadline TEXT NOT NULL,        -- ISO 8601
  priority INTEGER NOT NULL DEFAULT 2,
  done INTEGER NOT NULL DEFAULT 0,
  source_uid TEXT UNIQUE,        -- UID del evento ICS si se importó (evita duplicados)
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS time_logs(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  task_id INTEGER NOT NULL REFERENCES tasks(id) ON DELETE CASCADE,
  minutes INTEGER NOT NULL,
  logged_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE TABLE IF NOT EXISTS notes(
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL DEFAULT '',
  body TEXT NOT NULL DEFAULT '',
  tags TEXT NOT NULL DEFAULT '',
  task_id INTEGER,
  canvas TEXT NOT NULL DEFAULT '[]',        -- JSON: elementos de la nota (texto, código, imagen, dibujo...)
  color TEXT NOT NULL DEFAULT '#FFF59D',
  pinned INTEGER NOT NULL DEFAULT 0,
  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,
  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP
);
"""


def to_pg(sql: str) -> tuple[str, bool]:
    """Traduce el SQL estilo SQLite usado en main.py a Postgres. Devuelve (sql, usa_returning)."""
    sql = sql.replace("?", "%s")
    returning = False
    if re.match(r"\s*INSERT OR IGNORE", sql, re.I):
        sql = re.sub(r"INSERT OR IGNORE", "INSERT", sql, count=1, flags=re.I) + " ON CONFLICT DO NOTHING"
    elif re.match(r"\s*INSERT", sql, re.I):
        sql += " RETURNING id"
        returning = True
    return sql, returning


class _PgCursor:
    def __init__(self, cur, returning: bool):
        self._cur = cur
        self.lastrowid = cur.fetchone()["id"] if returning else None

    @property
    def rowcount(self) -> int:
        return self._cur.rowcount

    def fetchone(self):
        return self._cur.fetchone()

    def fetchall(self):
        return self._cur.fetchall()

    def __iter__(self):
        return iter(self._cur.fetchall())


class _PgConn:
    def __init__(self, conn):
        self._conn = conn

    def execute(self, sql: str, args=()):
        sql, returning = to_pg(sql)
        return _PgCursor(self._conn.execute(sql, tuple(args)), returning)


@contextmanager
def connect():
    if DATABASE_URL:
        import psycopg
        from psycopg.rows import dict_row

        # prepare_threshold=None: necesario con el pooler (modo transacción) de Supabase
        conn = psycopg.connect(DATABASE_URL, row_factory=dict_row, prepare_threshold=None)
        try:
            yield _PgConn(conn)
            conn.commit()
        except Exception:
            conn.rollback()
            raise
        finally:
            conn.close()
    else:
        conn = sqlite3.connect(DB_PATH)
        conn.row_factory = sqlite3.Row
        conn.execute("PRAGMA foreign_keys=ON")
        try:
            yield conn
            conn.commit()
        finally:
            conn.close()


def init() -> None:
    if DATABASE_URL:
        return  # en Supabase el esquema se crea una vez con supabase/schema.sql
    with connect() as c:
        c.executescript(SCHEMA)
        # Migración para bases SQLite creadas con la versión anterior
        cols = {r["name"] for r in c.execute("PRAGMA table_info(notes)")}
        for name, ddl in (("canvas", "TEXT NOT NULL DEFAULT '[]'"),
                          ("color", "TEXT NOT NULL DEFAULT '#FFF59D'"),
                          ("pinned", "INTEGER NOT NULL DEFAULT 0")):
            if name not in cols:
                c.execute(f"ALTER TABLE notes ADD COLUMN {name} {ddl}")
