# Tests for src/cancel.lex and src/order_store.lex
#
# Uses in-memory SQLite.
# Effects: [orders, sql, fs_write]

import "std.list" as list

import "lex-orm/src/connection" as conn

import "lex-orm/src/error" as dbe

import "lex-money/src/decimal" as d

import "../src/lifecycle" as lc

import "../src/order_store" as ostore

import "../src/cancel" as cancel

import "../src/order" as order

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn fail(why :: Str) -> Result[Unit, Str] {
  Err(why)
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    fail(label)
  }
}

fn open_db() -> [orders, sql, fs_write] Result[conn.ConnDb, Str] {
  match conn.connect_sqlite(":memory:") {
    Err(err) => Err(dbe.message(err)),
    Ok(db) => match ostore.init(db) {
      Err(err) => Err(dbe.message(err)),
      Ok(_) => Ok(db),
    },
  }
}

fn price(c :: Int, e :: Int) -> d.Decimal {
  d.decimal(c, e)
}

fn make_cancel(db :: conn.ConnDb, cl_ord_id :: Str, orig :: Str, account :: Str) -> [orders, sql] Result[Unit, Str] {
  match cancel.validate_cancel(db, cl_ord_id, orig, account, "AAPL", OrderBuy(()), 100, "20260528-10:00:00.000", "ALGO01", "EXCH01") {
    Ok(_) => Ok(()),
    Err(r) => Err("unexpected rejection"),
  }
}

# ---- Tests ----------------------------------------------------------
fn test_cancel_unknown_order_is_rejected() -> [orders, sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(msg) => fail(msg),
    Ok(db) => match cancel.validate_cancel(db, "NEW-001", "ORIG-001", "ACC1", "AAPL", OrderBuy(()), 100, "20260528-10:00:00.000", "ALGO01", "EXCH01") {
      Ok(_) => fail("should reject unknown order"),
      Err(OrderNotCancelable(_)) => pass(),
      Err(r) => fail("wrong rejection type"),
    },
  }
}

fn test_cancel_new_order_succeeds() -> [orders, sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(msg) => fail(msg),
    Ok(db) => {
      let __lex_discard_1 := ostore.upsert(db, "CL-001", "ACC1", "AAPL", New(()))
      match cancel.validate_cancel(db, "CXL-001", "CL-001", "ACC1", "AAPL", OrderBuy(()), 100, "20260528-10:00:00.000", "ALGO01", "EXCH01") {
        Ok(req) => assert_true(req.orig_cl_ord_id == "CL-001", "orig_cl_ord_id"),
        Err(_) => fail("cancel of New order should succeed"),
      }
    },
  }
}

fn test_cancel_partially_filled_succeeds() -> [orders, sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(msg) => fail(msg),
    Ok(db) => {
      let __lex_discard_2 := ostore.upsert(db, "CL-002", "ACC1", "AAPL", PartiallyFilled(50, price(1000, -2)))
      match cancel.validate_cancel(db, "CXL-002", "CL-002", "ACC1", "AAPL", OrderBuy(()), 100, "20260528-10:00:00.000", "ALGO01", "EXCH01") {
        Ok(_) => pass(),
        Err(_) => fail("cancel of PartiallyFilled should succeed"),
      }
    },
  }
}

fn test_cancel_filled_order_is_rejected() -> [orders, sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(msg) => fail(msg),
    Ok(db) => {
      let __lex_discard_3 := ostore.upsert(db, "CL-003", "ACC1", "AAPL", Filled(price(1050, -2)))
      match cancel.validate_cancel(db, "CXL-003", "CL-003", "ACC1", "AAPL", OrderBuy(()), 100, "20260528-10:00:00.000", "ALGO01", "EXCH01") {
        Ok(_) => fail("cancel of Filled should fail"),
        Err(OrderNotCancelable(s)) => assert_true(s == "Filled", "state=Filled"),
        Err(_) => fail("wrong rejection type"),
      }
    },
  }
}

fn test_cancel_canceled_order_is_rejected() -> [orders, sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(msg) => fail(msg),
    Ok(db) => {
      let __lex_discard_4 := ostore.upsert(db, "CL-004", "ACC1", "AAPL", Canceled(50))
      match cancel.validate_cancel(db, "CXL-004", "CL-004", "ACC1", "AAPL", OrderBuy(()), 100, "20260528-10:00:00.000", "ALGO01", "EXCH01") {
        Ok(_) => fail("cancel of Canceled should fail"),
        Err(OrderNotCancelable(_)) => pass(),
        Err(_) => fail("wrong rejection type"),
      }
    },
  }
}

fn test_order_store_apply_event_pipeline() -> [orders, sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(msg) => fail(msg),
    Ok(db) => {
      match ostore.apply_event(db, "CL-005", "ACC1", "MSFT", ExchangeAck("ORD-005")) {
        Err(e) => fail(dbe.message(e)),
        Ok(New(_)) => {
          match ostore.apply_event(db, "CL-005", "ACC1", "MSFT", PartialFill(50, price(1000, -2))) {
            Err(e) => fail(dbe.message(e)),
            Ok(PartiallyFilled(50, _)) => pass(),
            Ok(_) => fail("expected PartiallyFilled(50, ...)"),
          }
        },
        Ok(_) => fail("expected New"),
      }
    },
  }
}

fn suite() -> [orders, sql, fs_write] List[Result[Unit, Str]] {
  [test_cancel_unknown_order_is_rejected(), test_cancel_new_order_succeeds(), test_cancel_partially_filled_succeeds(), test_cancel_filled_order_is_rejected(), test_cancel_canceled_order_is_rejected(), test_order_store_apply_event_pipeline()]
}

fn run_all() -> [orders, sql, fs_write] Int {
  list.fold(suite(), 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

