# lex-trade — SQL-backed runtime risk limits
#
# Persists per-account RiskLimit records in a SQLite table.
# The caller owns the Db handle and its lifecycle.
#
# API:
#   init(db)                   — create the schema (idempotent)
#   fetch_limits(db, account)  — load limits; falls back to default_limits()
#   store_limits(db, account, lim) — upsert a RiskLimit
#   remove_limits(db, account) — delete a record (reverts account to defaults)
#
# allowed_symbols is stored as a comma-separated string; an empty string
# means "all symbols permitted" (matching limit.symbol_allowed semantics).
#
# Effects: [sql]

import "std.sql"  as sql
import "std.str"  as str
import "std.int"  as int
import "std.list" as list

import "./limit" as limit

# ---- Schema -----------------------------------------------------

fn init(db :: Db) -> [sql] Result[Unit, Str] {
  match sql.exec(db,
    "CREATE TABLE IF NOT EXISTS risk_limits (account TEXT NOT NULL PRIMARY KEY, max_order_qty INTEGER NOT NULL, max_notional_str TEXT NOT NULL, allowed_symbols TEXT NOT NULL DEFAULT '', allowed_sides TEXT NOT NULL DEFAULT 'buy,sell')",
    []) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(()),
  }
}

# ---- Fetch -------------------------------------------------------

fn fetch_limits(db :: Db, account :: Str) -> [sql] Result[limit.RiskLimit, Str] {
  match sql.query(db,
    "SELECT max_order_qty, max_notional_str, allowed_symbols, allowed_sides FROM risk_limits WHERE account = ?",
    [PStr(account)]) {
    Err(e)   => Err(e.message),
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

# ---- Store -------------------------------------------------------

fn store_limits(db :: Db, account :: Str, lim :: limit.RiskLimit) -> [sql] Result[Unit, Str] {
  let syms_s := str.join(lim.allowed_symbols, ",")
  let sids_s := str.join(lim.allowed_sides, ",")
  match sql.exec(db,
    "INSERT OR REPLACE INTO risk_limits(account, max_order_qty, max_notional_str, allowed_symbols, allowed_sides) VALUES (?, ?, ?, ?, ?)",
    [PStr(account), PInt(lim.max_order_qty), PStr(lim.max_notional_str), PStr(syms_s), PStr(sids_s)]) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(()),
  }
}

# ---- Remove -------------------------------------------------------

fn remove_limits(db :: Db, account :: Str) -> [sql] Result[Unit, Str] {
  match sql.exec(db, "DELETE FROM risk_limits WHERE account = ?", [PStr(account)]) {
    Err(e) => Err(e.message),
    Ok(_)  => Ok(()),
  }
}
