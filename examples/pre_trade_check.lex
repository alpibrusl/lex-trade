# lex-trade — pre-trade check worked example
#
# Demonstrates the agent-native pre-trade validation pipeline:
#   Agent emits Order → substrate validates against risk limits and
#   FIX conformance → Accepted or Rejected before touching the market.
#
# This is the worked example from the agent-native framework's
# Phase 3 finance stress test.

import "std.str"  as str
import "std.list" as list

import "../src/order"      as order
import "../src/limit"      as limit
import "../src/rejection"  as rejection
import "../src/validation" as v

# A simulated order from an agent
fn sample_order() -> order.Order {
  order.order(
    "ORD-2026-001",
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

fn sample_limits() -> limit.RiskLimit {
  limit.default_limits()
}

fn run_example() -> Str {
  let o      := sample_order()
  let limits := sample_limits()
  let result := v.validate(o, limits, "ALGO01", "EXCH01")
  match result {
    Accepted(_) => "order accepted — ready for market submission",
    Rejected(reasons) => str.concat("order rejected: ",
      list.fold(reasons, "",
        fn (acc :: Str, r :: rejection.RejectionReason) -> Str {
          if acc == "" { rejection.describe(r) }
          else { str.concat(acc, str.concat(", ", rejection.describe(r))) }
        })),
  }
}
