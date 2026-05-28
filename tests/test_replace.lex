# Tests for src/replace.lex — validate_replace pure logic.
#
# All tests are pure (no effects).

import "std.list" as list

import "../src/order"      as order
import "../src/limit"      as limit
import "../src/validation" as v
import "../src/replace"    as replace

fn pass() -> Result[Unit, Str] { Ok(()) }
fn fail(why :: Str) -> Result[Unit, Str] { Err(why) }
fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond { pass() } else { fail(label) }
}

fn base_order() -> order.Order {
  order.order(
    "CL-001", "AAPL", OrderBuy, 100,
    LimitOrder("150.00"), "0",
    "ACC1", "TRADER-01", "20260528-09:30:00.000"
  )
}

fn lim() -> limit.RiskLimit {
  limit.default_limits()
}

fn test_valid_replace_passes() -> Result[Unit, Str] {
  let orig := base_order()
  let amended := order.order(
    "CL-002", "AAPL", OrderBuy, 90,
    LimitOrder("151.00"), "0",
    "ACC1", "TRADER-01", "20260528-09:31:00.000"
  )
  match replace.validate_replace(orig, amended, lim(), "ALGO01", "EXCH01") {
    Accepted(_) => pass(),
    Rejected(vs) => fail("valid replace should be Accepted"),
  }
}

fn test_replace_changing_side_is_rejected() -> Result[Unit, Str] {
  let orig := base_order()
  let amended := order.order(
    "CL-002", "AAPL", OrderSell, 100,
    LimitOrder("150.00"), "0",
    "ACC1", "TRADER-01", "20260528-09:31:00.000"
  )
  match replace.validate_replace(orig, amended, lim(), "ALGO01", "EXCH01") {
    Accepted(_)  => fail("side change should be rejected"),
    Rejected(vs) => match list.head(vs) {
      None    => fail("no violation"),
      Some(r) => match r {
        FixConformanceFailure(_) => pass(),
        _                        => fail("expected FixConformanceFailure"),
      },
    },
  }
}

fn test_replace_changing_symbol_is_rejected() -> Result[Unit, Str] {
  let orig := base_order()
  let amended := order.order(
    "CL-002", "MSFT", OrderBuy, 100,
    LimitOrder("300.00"), "0",
    "ACC1", "TRADER-01", "20260528-09:31:00.000"
  )
  match replace.validate_replace(orig, amended, lim(), "ALGO01", "EXCH01") {
    Accepted(_)  => fail("symbol change should be rejected"),
    Rejected(vs) => match list.head(vs) {
      None    => fail("no violation"),
      Some(r) => match r {
        FixConformanceFailure(_) => pass(),
        _                        => fail("expected FixConformanceFailure"),
      },
    },
  }
}

fn test_replace_exceeding_qty_limit_is_rejected() -> Result[Unit, Str] {
  let orig := base_order()
  let amended := order.order(
    "CL-002", "AAPL", OrderBuy, 99999,  # exceeds max_order_qty
    LimitOrder("150.00"), "0",
    "ACC1", "TRADER-01", "20260528-09:31:00.000"
  )
  match replace.validate_replace(orig, amended, lim(), "ALGO01", "EXCH01") {
    Accepted(_)  => fail("qty violation should be caught"),
    Rejected(vs) => match list.head(vs) {
      None    => fail("no violation"),
      Some(r) => match r {
        ExceedsMaxQty(_, _) => pass(),
        _                    => fail("expected ExceedsMaxQty"),
      },
    },
  }
}

fn test_replace_changing_account_is_rejected() -> Result[Unit, Str] {
  let orig := base_order()
  let amended := order.order(
    "CL-002", "AAPL", OrderBuy, 100,
    LimitOrder("150.00"), "0",
    "ACC2", "TRADER-01", "20260528-09:31:00.000"
  )
  match replace.validate_replace(orig, amended, lim(), "ALGO01", "EXCH01") {
    Accepted(_)  => fail("account change should be rejected"),
    Rejected(vs) => match list.head(vs) {
      None    => fail("no violation"),
      Some(r) => match r {
        FixConformanceFailure(_) => pass(),
        _                        => fail("expected FixConformanceFailure"),
      },
    },
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [
    test_valid_replace_passes(),
    test_replace_changing_side_is_rejected(),
    test_replace_changing_symbol_is_rejected(),
    test_replace_exceeding_qty_limit_is_rejected(),
    test_replace_changing_account_is_rejected(),
  ]
}

fn run_all() -> Int {
  list.fold(suite(), 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r { Ok(_) => acc, Err(_) => acc + 1 }
  })
}
