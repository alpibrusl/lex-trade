# lex-trade — SQL-backed order lifecycle state store
#
# Persists OrderState keyed by (cl_ord_id, account). Supports SQLite
# and PostgreSQL via lex-orm ConnDb.
#
# Schema:
#   order_states (
#     cl_ord_id    TEXT NOT NULL,
#     account      TEXT NOT NULL,
#     symbol       TEXT NOT NULL,
#     state_kind   TEXT NOT NULL,       -- state_name()
#     filled_qty   INTEGER NOT NULL DEFAULT 0,
#     avg_price_str TEXT NOT NULL DEFAULT '0',
#     reason       TEXT NOT NULL DEFAULT '',
#     PRIMARY KEY (cl_ord_id, account)
#   )
#
# fetch returns None when no row exists (order never seen).
# upsert overwrites the current state on every lifecycle event.
#
# Effects: [orders, sql]

import "std.sql"  as sql
import "std.list" as list
import "std.str"  as str

import "lex-orm/src/connection" as conn
import "lex-orm/src/query"      as q
import "lex-orm/src/error"      as dbe

import "lex-positions/src/position" as pos

import "./lifecycle" as lc

fn init(db :: conn.ConnDb) -> [orders, sql] Result[Unit, dbe.DbErr] {
  let ddl := "CREATE TABLE IF NOT EXISTS order_states (cl_ord_id TEXT NOT NULL, account TEXT NOT NULL, symbol TEXT NOT NULL, state_kind TEXT NOT NULL, filled_qty INTEGER NOT NULL DEFAULT 0, avg_price_str TEXT NOT NULL DEFAULT '0', reason TEXT NOT NULL DEFAULT '', PRIMARY KEY (cl_ord_id, account))"
  match sql.exec(db.handle, ddl, []) {
    Err(e) => Err(dbe.sql_error(match e.code { None => "", Some(c) => c }, e.message)),
    Ok(_)  => Ok(()),
  }
}

fn fetch(db :: conn.ConnDb, cl_ord_id :: Str, account :: Str) -> [orders, sql] Result[Option[lc.OrderState], dbe.DbErr] {
  let sq := q.for_dialect(
    { sql: "SELECT state_kind, filled_qty, avg_price_str, reason FROM order_states WHERE cl_ord_id = ? AND account = ?",
      params: [PStr(cl_ord_id), PStr(account)] },
    db.dialect
  )
  let raw :: Result[List[{ state_kind :: Str, filled_qty :: Int, avg_price_str :: Str, reason :: Str }], SqlError] :=
    sql.query(db.handle, sq.sql, sq.params)
  match raw {
    Err(e) => Err(dbe.sql_error(match e.code { None => "", Some(c) => c }, e.message)),
    Ok(rows) => match list.head(rows) {
      None      => Ok(None),
      Some(row) => match decode_state(row) {
        Err(e) => Err(e),
        Ok(st) => Ok(Some(st)),
      },
    },
  }
}

fn upsert(db :: conn.ConnDb, cl_ord_id :: Str, account :: Str, symbol :: Str, state :: lc.OrderState) -> [orders, sql] Result[Unit, dbe.DbErr] {
  let encoded := encode_state(state)
  let sq := q.for_dialect(
    { sql: "INSERT INTO order_states (cl_ord_id, account, symbol, state_kind, filled_qty, avg_price_str, reason) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT (cl_ord_id, account) DO UPDATE SET state_kind = EXCLUDED.state_kind, filled_qty = EXCLUDED.filled_qty, avg_price_str = EXCLUDED.avg_price_str, reason = EXCLUDED.reason",
      params: [
        PStr(cl_ord_id), PStr(account), PStr(symbol),
        PStr(match encoded { (k, _, _, _) => k }),
        PInt(match encoded { (_, fq, _, _) => fq }),
        PStr(match encoded { (_, _, ap, _) => ap }),
        PStr(match encoded { (_, _, _, rs) => rs }),
      ] },
    db.dialect
  )
  match sql.exec(db.handle, sq.sql, sq.params) {
    Err(e) => Err(dbe.sql_error(match e.code { None => "", Some(c) => c }, e.message)),
    Ok(_)  => Ok(()),
  }
}

fn apply_event(
  db        :: conn.ConnDb,
  cl_ord_id :: Str,
  account   :: Str,
  symbol    :: Str,
  event     :: lc.OrderEvent
) -> [orders, sql] Result[lc.OrderState, dbe.DbErr] {
  match fetch(db, cl_ord_id, account) {
    Err(e) => Err(e),
    Ok(opt_state) => {
      let current := match opt_state {
        None    => PendingNew,
        Some(s) => s,
      }
      match lc.transition(current, event) {
        Err(msg) => Err(dbe.query_err(msg)),
        Ok(next) => match upsert(db, cl_ord_id, account, symbol, next) {
          Err(e) => Err(e),
          Ok(_)  => Ok(next),
        },
      }
    },
  }
}

# ---- Serialization --------------------------------------------------

fn encode_state(state :: lc.OrderState) -> (Str, Int, Str, Str) {
  match state {
    PendingNew              => ("PendingNew",      0,           "0", ""),
    New                     => ("New",             0,           "0", ""),
    PartiallyFilled(fq, ap) => ("PartiallyFilled", fq, pos.decimal_to_str(ap), ""),
    Filled(ap)              => ("Filled",          0,  pos.decimal_to_str(ap), ""),
    PendingCancel           => ("PendingCancel",   0,           "0", ""),
    Canceled(lq)            => ("Canceled",        lq,          "0", ""),
    Rejected(rs)            => ("Rejected",        0,           "0", rs),
    Expired                 => ("Expired",         0,           "0", ""),
  }
}

fn decode_state(row :: { state_kind :: Str, filled_qty :: Int, avg_price_str :: Str, reason :: Str }) -> Result[lc.OrderState, dbe.DbErr] {
  if row.state_kind == "PendingNew" {
    Ok(PendingNew)
  } else {
    if row.state_kind == "New" {
      Ok(New)
    } else {
      if row.state_kind == "PartiallyFilled" {
        match pos.parse_price(row.avg_price_str) {
          None    => Err(dbe.decode_err("invalid avg_price_str: " + row.avg_price_str)),
          Some(p) => Ok(PartiallyFilled(row.filled_qty, p)),
        }
      } else {
        if row.state_kind == "Filled" {
          match pos.parse_price(row.avg_price_str) {
            None    => Err(dbe.decode_err("invalid avg_price_str: " + row.avg_price_str)),
            Some(p) => Ok(Filled(p)),
          }
        } else {
          if row.state_kind == "PendingCancel" {
            Ok(PendingCancel)
          } else {
            if row.state_kind == "Canceled" {
              Ok(Canceled(row.filled_qty))
            } else {
              if row.state_kind == "Rejected" {
                Ok(Rejected(row.reason))
              } else {
                if row.state_kind == "Expired" {
                  Ok(Expired)
                } else {
                  Err(dbe.decode_err("unknown state_kind: " + row.state_kind))
                }
              }
            }
          }
        }
      }
    }
  }
}
