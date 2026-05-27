# tests for src/validation_io.lex
#
# validate_and_log has [sql, time] effects so this test file is effectful.
# run_all returns the failure count as usual; the effect set propagates.

import "std.list" as list
import "std.str"  as str

import "lex-trail/src/log"   as trail_log
import "lex-trail/src/event" as ev

import "../src/order"         as order
import "../src/limit"         as limit
import "../src/validation"    as v
import "../src/trail_kinds"   as kinds
import "../src/validation_io" as vio

fn pass() -> Result[Unit, Str] { Ok(()) }
fn fail(why :: Str) -> Result[Unit, Str] { Err(why) }
fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond { pass() } else { fail(label) }
}

fn sample_order() -> order.Order {
  order.order(
    "ORD-001",
    "MSFT",
    OrderBuy,
    100,
    LimitOrder("125.50"),
    "0",
    "ACCOUNT-A",
    "TRADER-01",
    "20260528-09:30:00.000"
  )
}

fn default_limits() -> limit.RiskLimit {
  limit.default_limits()
}

# Open an in-memory trail, call validate_and_log, close it.
# Returns the result and the event count logged.
fn run_validation(
  o      :: order.Order,
  lim    :: limit.RiskLimit
) -> [sql, fs_write, time] Result[{ result :: v.ValidationResult, event_count :: Int }, Str] {
  match trail_log.open_memory() {
    Err(e) => Err(e),
    Ok(log) => {
      let result := vio.validate_and_log(o, lim, "ALGO01", "EXCH01", log)
      let count := match trail_log.range(log, 0, 9999999999999) {
        Err(_)   => 0,
        Ok(evts) => list.len(evts),
      }
      trail_log.close(log)
      Ok({ result: result, event_count: count })
    },
  }
}

fn test_accepted_result() -> [sql, fs_write, time] Result[Unit, Str] {
  match run_validation(sample_order(), default_limits()) {
    Err(e) => fail(e),
    Ok(r)  => assert_true(v.is_accepted(r.result), "valid order should be accepted"),
  }
}

fn test_accepted_logs_two_events() -> [sql, fs_write, time] Result[Unit, Str] {
  match run_validation(sample_order(), default_limits()) {
    Err(e) => fail(e),
    Ok(r)  => assert_true(r.event_count == 2, "should log exactly 2 events"),
  }
}

fn test_rejected_result() -> [sql, fs_write, time] Result[Unit, Str] {
  let o := order.order(
    "ORD-002", "MSFT", OrderBuy, 99999,
    LimitOrder("125.50"), "0", "ACCOUNT-A", "TRADER-01", "20260528-09:30:00.000"
  )
  match run_validation(o, default_limits()) {
    Err(e) => fail(e),
    Ok(r)  => assert_true(v.is_rejected(r.result), "oversized order should be rejected"),
  }
}

fn test_rejected_logs_two_events() -> [sql, fs_write, time] Result[Unit, Str] {
  let o := order.order(
    "ORD-003", "MSFT", OrderBuy, 99999,
    LimitOrder("125.50"), "0", "ACCOUNT-A", "TRADER-01", "20260528-09:30:00.000"
  )
  match run_validation(o, default_limits()) {
    Err(e) => fail(e),
    Ok(r)  => assert_true(r.event_count == 2, "rejected path should also log 2 events"),
  }
}

fn test_two_orders_log_four_events() -> [sql, fs_write, time] Result[Unit, Str] {
  let o2 := order.order(
    "ORD-999",
    "AAPL",
    OrderSell,
    50,
    MarketOrder,
    "0",
    "ACCOUNT-B",
    "TRADER-02",
    "20260528-09:31:00.000"
  )
  match trail_log.open_memory() {
    Err(e) => fail(e),
    Ok(log) => {
      let _ := vio.validate_and_log(sample_order(), default_limits(), "ALGO01", "EXCH01", log)
      let _ := vio.validate_and_log(o2, default_limits(), "ALGO02", "EXCH01", log)
      let count := match trail_log.range(log, 0, 9999999999999) {
        Err(_)   => 0,
        Ok(evts) => list.len(evts),
      }
      trail_log.close(log)
      assert_true(count == 4, "two distinct orders should log 4 events total")
    },
  }
}

fn suite() -> [sql, fs_write, time] List[Result[Unit, Str]] {
  [
    test_accepted_result(),
    test_accepted_logs_two_events(),
    test_rejected_result(),
    test_rejected_logs_two_events(),
    test_two_orders_log_four_events(),
  ]
}

fn run_all() -> [sql, fs_write, time] Int {
  list.fold(suite(), 0,
    fn (n :: Int, r :: Result[Unit, Str]) -> Int {
      match r { Ok(_) => n, Err(_) => n + 1 }
    })
}
