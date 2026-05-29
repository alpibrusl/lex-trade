# Tests for src/price_check.lex — pure price tolerance gate.
#
# All tests are pure (no effects).

import "std.list" as list

import "lex-money/src/decimal" as d

import "../src/order" as order

import "../src/rejection" as rejection

import "../src/price_check" as pc

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

fn price(c :: Int, e :: Int) -> d.Decimal {
  d.decimal(c, e)
}

fn tolerance_200bps() -> pc.PriceTolerance {
  { max_deviation_bps: 200 }
}

fn limit_order(p :: Str) -> order.Order {
  order.order("CL-001", "AAPL", OrderBuy(()), 100, LimitOrder(p), "0", "ACC1", "TRADER-01", "20260528-09:30:00.000")
}

fn market_order() -> order.Order {
  order.order("CL-001", "AAPL", OrderBuy(()), 100, MarketOrder(()), "0", "ACC1", "TRADER-01", "20260528-09:30:00.000")
}

# ---- Tests ----------------------------------------------------------
fn test_market_order_always_passes() -> Result[Unit, Str] {
  let o := market_order()
  let ref := price(17500, -2)
  match pc.check_price_tolerance(o, ref, tolerance_200bps()) {
    Ok(_) => pass(),
    Err(_) => fail("market order should always pass"),
  }
}

fn test_limit_within_tolerance_passes() -> Result[Unit, Str] {
  let o := limit_order("174.00")
  let ref := price(17500, -2)
  match pc.check_price_tolerance(o, ref, tolerance_200bps()) {
    Ok(_) => pass(),
    Err(_) => fail("174.00 vs 175.00 is within 200bps"),
  }
}

fn test_limit_at_boundary_passes() -> Result[Unit, Str] {
  let o := limit_order("102.00")
  let ref := price(10000, -2)
  match pc.check_price_tolerance(o, ref, tolerance_200bps()) {
    Ok(_) => pass(),
    Err(_) => fail("102.00 vs 100.00 is exactly 200bps, should pass"),
  }
}

fn test_limit_exceeds_tolerance_is_rejected() -> Result[Unit, Str] {
  let o := limit_order("103.00")
  let ref := price(10000, -2)
  match pc.check_price_tolerance(o, ref, tolerance_200bps()) {
    Ok(_) => fail("103.00 vs 100.00 is 300bps, should be rejected"),
    Err(r) => match r {
      PriceToleranceBreached(_, _, bps) => assert_true(bps > 200, "bps > 200"),
      _ => fail("expected PriceToleranceBreached"),
    },
  }
}

fn test_limit_below_tolerance_is_rejected() -> Result[Unit, Str] {
  let o := limit_order("97.00")
  let ref := price(10000, -2)
  match pc.check_price_tolerance(o, ref, tolerance_200bps()) {
    Ok(_) => fail("97.00 vs 100.00 is 300bps, should be rejected"),
    Err(r) => match r {
      PriceToleranceBreached(op, _, _) => assert_true(op == "97.00", "price_str"),
      _ => fail("expected PriceToleranceBreached"),
    },
  }
}

fn test_exact_ref_price_passes() -> Result[Unit, Str] {
  let o := limit_order("175.00")
  let ref := price(17500, -2)
  match pc.check_price_tolerance(o, ref, tolerance_200bps()) {
    Ok(_) => pass(),
    Err(_) => fail("exact match should pass"),
  }
}

fn test_zero_tolerance_rejects_any_deviation() -> Result[Unit, Str] {
  let zero_tol := { max_deviation_bps: 0 }
  let o := limit_order("175.01")
  let ref := price(17500, -2)
  match pc.check_price_tolerance(o, ref, zero_tol) {
    Ok(_) => fail("any deviation should fail with 0bps tolerance"),
    Err(_) => pass(),
  }
}

fn test_stop_limit_order_checks_limit_price() -> Result[Unit, Str] {
  let o := order.order("CL-002", "AAPL", OrderBuy(()), 100, StopLimitOrder("175.00", "103.00"), "0", "ACC1", "TRADER-01", "20260528-09:30:00.000")
  let ref := price(10000, -2)
  match pc.check_price_tolerance(o, ref, tolerance_200bps()) {
    Ok(_) => fail("stop limit: limit price 103.00 is 300bps over ref"),
    Err(_) => pass(),
  }
}

# ---- Suite ----------------------------------------------------------
fn suite() -> List[Result[Unit, Str]] {
  [test_market_order_always_passes(), test_limit_within_tolerance_passes(), test_limit_at_boundary_passes(), test_limit_exceeds_tolerance_is_rejected(), test_limit_below_tolerance_is_rejected(), test_exact_ref_price_passes(), test_zero_tolerance_rejects_any_deviation(), test_stop_limit_order_checks_limit_price()]
}

fn run_all() -> Int {
  list.fold(suite(), 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => acc,
      Err(_) => acc + 1,
    }
  })
}

