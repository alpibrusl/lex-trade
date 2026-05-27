# lex-trade — SQL-backed runtime risk limits (via lex-orm)
#
# Backend is selected by the URL passed to conn.open():
#   conn.open("postgres://user:pass@host/db")  → PostgreSQL
#   conn.open(":memory:")                       → SQLite (ephemeral)
#   conn.open("/var/lib/lex/risk.db")           → SQLite (persistent)
#
# API:
#   init(db)                      — create schema (idempotent)
#   fetch_limits(db, account)     — load; falls back to default_limits() when missing
#   store_limits(db, account, lim) — upsert (INSERT … ON CONFLICT DO UPDATE)
#   remove_limits(db, account)    — delete row (next fetch reverts to defaults)
#
# Placeholder rewriting (?→$1,…) for PostgreSQL is handled by
# query.for_dialect — no hand-rolled SQL branching needed.
#
# Effects: [sql]

import "std.sql"  as sql
import "std.str"  as str
import "std.int"  as int
import "std.list" as list

import "lex-orm/src/connection" as conn
import "lex-orm/src/query"      as q
import "lex-orm/src/error"      as dbe

import "./limit" as limit

# ---- Schema -----------------------------------------------------
# TEXT/INTEGER DDL is valid for both SQLite and PostgreSQL.

fn init(db :: conn.ConnDb) -> [sql] Result[Unit, dbe.DbErr] {
  match sql.exec(db.handle,
    "CREATE TABLE IF NOT EXISTS risk_limits (account TEXT NOT NULL PRIMARY KEY, max_order_qty INTEGER NOT NULL, max_notional_str TEXT NOT NULL, allowed_symbols TEXT NOT NULL DEFAULT '', allowed_sides TEXT NOT NULL DEFAULT 'buy,sell')",
    []) {
    Err(e) => Err(dbe.sql_error(match e.code { None => "", Some(c) => c }, e.message)),
    Ok(_)  => Ok(()),
  }
}

# ---- Fetch -------------------------------------------------------

fn fetch_limits(db :: conn.ConnDb, account :: Str) -> [sql] Result[limit.RiskLimit, dbe.DbErr] {
  let sq := q.for_dialect(
    { sql: "SELECT max_order_qty, max_notional_str, allowed_symbols, allowed_sides FROM risk_limits WHERE account = ?",
      params: [PStr(account)] },
    db.dialect)
  match sql.query(db.handle, sq.sql, sq.params) {
    Err(e)   => Err(dbe.sql_error(match e.code { None => "", Some(c) => c }, e.message)),
    Ok(rows) => match list.head(rows) {
      None    => Ok(limit.default_limits()),
      Some(r) => Ok(decode_row(r)),
    },
  }
}

fn decode_row[R](row :: R) -> limit.RiskLimit {
  let qty    := match sql.get_int(row, "max_order_qty")    { Some(n) => n, None => 10000 }
  let notl   := match sql.get_str(row, "max_notional_str") { Some(s) => s, None => "5000000.00" }
  let syms_s := match sql.get_str(row, "allowed_symbols")  { Some(s) => s, None => "" }
  let sids_s := match sql.get_str(row, "allowed_sides")    { Some(s) => s, None => "buy,sell" }
  {
    max_order_qty:    qty,
    max_notional_str: notl,
    allowed_symbols:  if str.is_empty(syms_s) { [] } else { str.split(syms_s, ",") },
    allowed_sides:    str.split(sids_s, ","),
  }
}

# ---- Store (upsert) ----------------------------------------------
# ON CONFLICT … DO UPDATE SET EXCLUDED.* is standard SQL supported by
# both PostgreSQL and SQLite ≥ 3.24 (the bundled rusqlite version).

fn store_limits(db :: conn.ConnDb, account :: Str, lim :: limit.RiskLimit) -> [sql] Result[Unit, dbe.DbErr] {
  let syms_s := str.join(lim.allowed_symbols, ",")
  let sids_s := str.join(lim.allowed_sides, ",")
  let sq := q.for_dialect(
    { sql: "INSERT INTO risk_limits(account, max_order_qty, max_notional_str, allowed_symbols, allowed_sides) VALUES (?, ?, ?, ?, ?) ON CONFLICT (account) DO UPDATE SET max_order_qty = EXCLUDED.max_order_qty, max_notional_str = EXCLUDED.max_notional_str, allowed_symbols = EXCLUDED.allowed_symbols, allowed_sides = EXCLUDED.allowed_sides",
      params: [PStr(account), PInt(lim.max_order_qty), PStr(lim.max_notional_str), PStr(syms_s), PStr(sids_s)] },
    db.dialect)
  match sql.exec(db.handle, sq.sql, sq.params) {
    Err(e) => Err(dbe.sql_error(match e.code { None => "", Some(c) => c }, e.message)),
    Ok(_)  => Ok(()),
  }
}

# ---- Remove -------------------------------------------------------

fn remove_limits(db :: conn.ConnDb, account :: Str) -> [sql] Result[Unit, dbe.DbErr] {
  let sq := q.for_dialect(
    { sql: "DELETE FROM risk_limits WHERE account = ?", params: [PStr(account)] },
    db.dialect)
  match sql.exec(db.handle, sq.sql, sq.params) {
    Err(e) => Err(dbe.sql_error(match e.code { None => "", Some(c) => c }, e.message)),
    Ok(_)  => Ok(()),
  }
}
