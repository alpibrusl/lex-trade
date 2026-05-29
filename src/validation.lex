# lex-trade — pure pre-trade validation pipeline
#
# The central correctness gate. Given a domain Order and a RiskLimit,
# this module:
#   1. Checks risk-limit predicates (quantity, symbol, side).
#   2. Converts the order to a typed NewOrderSingle.
#   3. Runs lex-fix FIX-protocol conformance validation.
#   4. Returns Accepted(nos) or Rejected(violations).
#
# Pure: no effects, no I/O. The effectful logging shell lives in
# validation_io.lex.
#
# Effects: none.

import "std.list" as list

import "lex-fix/src/v44/new_order_single" as nos

import "lex-fix/src/conformance" as conf

import "./order" as order

import "./limit" as limit

import "./rejection" as rejection

# ---- Result type ------------------------------------------------
type ValidationResult = Accepted(nos.NewOrderSingle) | Rejected(List[rejection.RejectionReason])

fn side_str(s :: order.OrderSide) -> Str {
  match s {
    OrderBuy(_) => "buy",
    OrderSell(_) => "sell",
  }
}

# ---- Public API -------------------------------------------------
fn validate(o :: order.Order, lim :: limit.RiskLimit, sender :: Str, target :: Str) -> ValidationResult {
  let v0 := []
  let v1 := if limit.within_qty(lim, o.quantity) {
    v0
  } else {
    list.concat(v0, [ExceedsMaxQty(o.quantity, lim.max_order_qty)])
  }
  let v2 := if limit.symbol_allowed(lim, o.symbol) {
    v1
  } else {
    list.concat(v1, [SymbolNotAllowed(o.symbol)])
  }
  let v3 := if limit.side_allowed(lim, side_str(o.side)) {
    v2
  } else {
    list.concat(v2, [SideNotAllowed(side_str(o.side))])
  }
  let nos_val := order.order_to_nos(o, sender, target)
  let fix_msg := nos.to_fix_message(nos_val, 1)
  let v4 := match conf.validate_new_order(fix_msg) {
    Ok(_) => v3,
    Err(errs) => list.concat(v3, [FixConformanceFailure(conf.describe_errors(errs))]),
  }
  if list.is_empty(v4) {
    Accepted(nos_val)
  } else {
    Rejected(v4)
  }
}

fn is_accepted(r :: ValidationResult) -> Bool {
  match r {
    Accepted(_) => true,
    Rejected(_) => false,
  }
}

fn is_rejected(r :: ValidationResult) -> Bool {
  match r {
    Accepted(_) => false,
    Rejected(_) => true,
  }
}

fn accepted_order(r :: ValidationResult) -> Option[nos.NewOrderSingle] {
  match r {
    Accepted(n) => Some(n),
    Rejected(_) => None,
  }
}

