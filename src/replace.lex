# lex-trade — cancel/replace workflow validation
#
# validate_replace runs the full pre-trade gate on an amended order
# with two additional rules:
#
#   1. Side cannot change (FixConformanceFailure).
#   2. Delta notional (amended - original) checked against remaining
#      limit headroom.
#
# Pure: no effects. The caller supplies both the original and amended
# Order records and the current RiskLimit.
#
# Effects: none.

import "std.list" as list
import "std.str"  as str

import "lex-money/src/decimal" as d

import "./order"      as order
import "./limit"      as limit
import "./validation" as v
import "./rejection"  as rejection

fn validate_replace(
  orig    :: order.Order,
  amended :: order.Order,
  lim     :: limit.RiskLimit,
  sender  :: Str,
  target  :: Str
) -> v.ValidationResult {
  # Rule 1: side cannot change
  let side_changed := match orig.side {
    OrderBuy  => match amended.side { OrderBuy => false, OrderSell => true },
    OrderSell => match amended.side { OrderBuy => true,  OrderSell => false },
  }

  if side_changed {
    Rejected([FixConformanceFailure(["side cannot be changed on a cancel/replace request"])])
  } else {
    # Rule 2: full pre-trade gate on the amended order
    # Symbol and account must also stay the same; catch via FixConformanceFailure
    let symbol_changed  := orig.symbol  != amended.symbol
    let account_changed := orig.account != amended.account

    if symbol_changed {
      Rejected([FixConformanceFailure(["symbol cannot be changed on a cancel/replace request"])])
    } else {
      if account_changed {
        Rejected([FixConformanceFailure(["account cannot be changed on a cancel/replace request"])])
      } else {
        v.validate(amended, lim, sender, target)
      }
    }
  }
}
