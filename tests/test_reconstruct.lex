# lex-trade tests — trade reconstruction (src/reconstruct.lex)
#
# Opens an in-memory trail, calls validate_log_and_record, reads the
# reconstruction back, replays, and asserts results_match. Also verifies
# that a rejected order is stored and replayed correctly.

import "std.list" as list

import "std.str" as str

import "lex-trail/src/log" as trail_log

import "../src/order" as order

import "../src/limit" as limit

import "../src/validation" as v

import "../src/validation_io" as vio

import "../src/reconstruct" as rc

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

fn sample_order() -> order.Order {
  order.order("ORD-RC-001", "MSFT", OrderBuy(()), 100, LimitOrder("125.50"), "0", "ACC-1", "TRADER-1", "20260530-10:00:00.000")
}

fn over_limit_order() -> order.Order {
  order.order("ORD-RC-002", "MSFT", OrderBuy(()), 99999, LimitOrder("125.50"), "0", "ACC-1", "TRADER-1", "20260530-10:00:00.000")
}

fn default_lim() -> limit.RiskLimit {
  limit.default_limits()
}

# ---- Test 1: round-trip and replay for an accepted order ----------
fn test_reconstruct_accepted() -> [sql, fs_write, time] Result[Unit, Str] {
  match trail_log.open_memory() {
    Err(e) => fail(str.concat("open_memory: ", e)),
    Ok(log) => {
      let lar := vio.validate_log_and_record(sample_order(), default_lim(), None, { max_deviation_bps: 200 }, "ALGO01", "EXCH01", log, "validation.validate@0.9.7")
      if str.is_empty(lar.entry_id) {
        fail("entry_id should be non-empty on successful trail append")
      } else {
        match rc.reconstruct(log.db, lar.entry_id) {
          Err(e) => fail(str.concat("reconstruct failed: ", e)),
          Ok(rec) => {
            let replay_result := rc.replay(rec)
            let matched := rc.results_match(rec, replay_result)
            if not matched {
              fail("replay result does not match stored result_tag")
            } else {
              if rec.result_tag == "Accepted" {
                pass()
              } else {
                fail(str.concat("expected Accepted, got: ", rec.result_tag))
              }
            }
          },
        }
      }
    },
  }
}

# ---- Test 2: rejected order is stored and replays as Rejected -----
fn test_reconstruct_rejected() -> [sql, fs_write, time] Result[Unit, Str] {
  match trail_log.open_memory() {
    Err(e) => fail(str.concat("open_memory: ", e)),
    Ok(log) => {
      let lar := vio.validate_log_and_record(over_limit_order(), default_lim(), None, { max_deviation_bps: 200 }, "ALGO01", "EXCH01", log, "")
      if str.is_empty(lar.entry_id) {
        fail("entry_id should be non-empty even for rejected orders")
      } else {
        match rc.reconstruct(log.db, lar.entry_id) {
          Err(e) => fail(str.concat("reconstruct failed for rejected order: ", e)),
          Ok(rec) => {
            let replay_result := rc.replay(rec)
            let matched := rc.results_match(rec, replay_result)
            if not matched {
              fail("replay of rejected order does not match stored result_tag")
            } else {
              if rec.result_tag == "Rejected" {
                if list.len(rec.violations) > 0 {
                  pass()
                } else {
                  fail("rejected order should have at least one stored violation")
                }
              } else {
                fail(str.concat("expected Rejected, got: ", rec.result_tag))
              }
            }
          },
        }
      }
    },
  }
}

# ---- Test 3: reconstruct for unknown entry_id returns Err ---------
fn test_reconstruct_unknown_id() -> [sql, fs_write] Result[Unit, Str] {
  match trail_log.open_memory() {
    Err(e) => fail(str.concat("open_memory: ", e)),
    Ok(log) => {
      let __init := rc.init_reconstruct(log.db)
      match rc.reconstruct(log.db, "no-such-id") {
        Ok(_) => fail("should return Err for unknown entry_id"),
        Err(_) => pass(),
      }
    },
  }
}

# ---- Test 4: order_kind_from_parts round-trips ----------------------
fn test_kind_roundtrip_limit() -> Result[Unit, Str] {
  let k := LimitOrder("99.50")
  let reconstructed := rc.order_kind_from_parts(rc.order_type_str(k), rc.order_price_str(k), rc.order_stop_price_str(k))
  match reconstructed {
    LimitOrder(p) => assert_true(p == "99.50", "LimitOrder price round-trips"),
    _ => fail("LimitOrder did not round-trip to LimitOrder"),
  }
}

fn test_kind_roundtrip_stoplimit() -> Result[Unit, Str] {
  let k := StopLimitOrder("110.00", "105.00")
  let reconstructed := rc.order_kind_from_parts(rc.order_type_str(k), rc.order_price_str(k), rc.order_stop_price_str(k))
  match reconstructed {
    StopLimitOrder(p, sp) => assert_true(p == "110.00" and sp == "105.00", "StopLimitOrder prices round-trip"),
    _ => fail("StopLimitOrder did not round-trip"),
  }
}

fn suite() -> [sql, fs_write, time] List[Result[Unit, Str]] {
  [test_reconstruct_accepted(), test_reconstruct_rejected(), test_reconstruct_unknown_id(), test_kind_roundtrip_limit(), test_kind_roundtrip_stoplimit()]
}

fn run_all() -> [sql, fs_write, time] Int {
  list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
}
