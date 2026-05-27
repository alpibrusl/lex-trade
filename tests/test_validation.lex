# tests for src/validation.lex

import "std.list" as list

import "../src/order"      as order
import "../src/limit"      as limit
import "../src/rejection"  as rejection
import "../src/validation" as v

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
    "20260527-09:30:00.000"
  )
}

fn test_valid_order_accepted() -> Result[Unit, Str] {
  let o      := sample_order()
  let limits := limit.default_limits()
  let result := v.validate(o, limits, "ALGO01", "EXCH01")
  assert_true(v.is_accepted(result), "valid order should be accepted")
}

fn test_exceeds_qty_rejected() -> Result[Unit, Str] {
  let o := order.order(
    "ORD-002",
    "MSFT",
    OrderBuy,
    99999,
    LimitOrder("125.50"),
    "0",
    "ACCOUNT-A",
    "TRADER-01",
    "20260527-09:30:00.000"
  )
  let limits := limit.default_limits()
  let result := v.validate(o, limits, "ALGO01", "EXCH01")
  assert_true(v.is_rejected(result), "oversized order should be rejected")
}

fn test_exceeds_qty_has_correct_reason() -> Result[Unit, Str] {
  let o := order.order(
    "ORD-003",
    "MSFT",
    OrderBuy,
    99999,
    LimitOrder("125.50"),
    "0",
    "ACCOUNT-A",
    "TRADER-01",
    "20260527-09:30:00.000"
  )
  let limits := limit.default_limits()
  let result := v.validate(o, limits, "ALGO01", "EXCH01")
  match result {
    Accepted(_)      => fail("should have been rejected"),
    Rejected(reasons) => {
      let has_qty := list.fold(reasons, false,
        fn (acc :: Bool, r :: rejection.RejectionReason) -> Bool {
          if acc { true }
          else {
            match r {
              ExceedsMaxQty(_, _) => true,
              _                   => false,
            }
          }
        })
      assert_true(has_qty, "should have ExceedsMaxQty reason")
    },
  }
}

fn test_symbol_blocked_rejected() -> Result[Unit, Str] {
  let o      := sample_order()
  let limits := {
    max_order_qty:    10000,
    max_notional_str: "5000000.00",
    allowed_symbols:  ["AAPL", "GOOG"],
    allowed_sides:    ["buy", "sell"],
  }
  let result := v.validate(o, limits, "ALGO01", "EXCH01")
  assert_true(v.is_rejected(result), "blocked symbol should be rejected")
}

fn test_is_accepted_true() -> Result[Unit, Str] {
  let o      := sample_order()
  let limits := limit.default_limits()
  let result := v.validate(o, limits, "ALGO01", "EXCH01")
  assert_true(v.is_accepted(result), "is_accepted returns true for Accepted")
}

fn test_is_rejected_true() -> Result[Unit, Str] {
  let o := order.order(
    "ORD-004",
    "MSFT",
    OrderBuy,
    99999,
    LimitOrder("125.50"),
    "0",
    "ACCOUNT-A",
    "TRADER-01",
    "20260527-09:30:00.000"
  )
  let limits := limit.default_limits()
  let result := v.validate(o, limits, "ALGO01", "EXCH01")
  assert_true(v.is_rejected(result), "is_rejected returns true for Rejected")
}

fn test_accepted_order_some() -> Result[Unit, Str] {
  let o      := sample_order()
  let limits := limit.default_limits()
  let result := v.validate(o, limits, "ALGO01", "EXCH01")
  match v.accepted_order(result) {
    None    => fail("expected Some for accepted order"),
    Some(n) => assert_true(n.cl_ord_id == "ORD-001", "cl_ord_id matches"),
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [
    test_valid_order_accepted(),
    test_exceeds_qty_rejected(),
    test_exceeds_qty_has_correct_reason(),
    test_symbol_blocked_rejected(),
    test_is_accepted_true(),
    test_is_rejected_true(),
    test_accepted_order_some(),
  ]
}

fn run_all() -> Int {
  list.fold(suite(), 0,
    fn (n :: Int, r :: Result[Unit, Str]) -> Int {
      match r { Ok(_) => n, Err(_) => n + 1 }
    })
}
