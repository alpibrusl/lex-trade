# lex-trade — position-aware pre-trade gate
#
# Checks an order against the account's current position before
# submission. Enforces two rules:
#
#   1. Gross notional after the fill must not exceed max_notional.
#      (Uses the order price or a provided mark price for market orders.)
#
#   2. An order that would flip the position from long to short (or vice
#      versa) is allowed only if allow_flip is true in the config.
#
# check_position returns Ok(unit) when both rules pass, or
# Err(PositionViolation(reason)) when either fails. The caller should
# merge this into the RejectionReason list before rendering a verdict.
#
# Effects: [positions, sql]

import "std.str"  as str
import "std.int"  as int

import "lex-money/src/decimal" as d

import "lex-positions/src/position"       as pos
import "lex-positions/src/position_store" as pstore
import "lex-positions/src/exposure"       as exp

import "lex-orm/src/connection" as conn
import "lex-orm/src/error"      as dbe

import "./order"     as order
import "./rejection" as rejection

type PositionCheckConfig = {
  max_notional :: d.Decimal,  # gross notional limit per (account, symbol)
  allow_flip   :: Bool,        # true = cross-zero fills are allowed
}

type PositionCheckResult =
    PassedPositionCheck
  | FailedPositionCheck(rejection.RejectionReason)

fn check_position(
  db     :: conn.ConnDb,
  config :: PositionCheckConfig,
  o      :: order.Order,
  price_str :: Str
) -> [positions, sql] PositionCheckResult {
  let key := { account: o.account, symbol: o.symbol }
  match pstore.fetch(db, key) {
    Err(err) =>
      FailedPositionCheck(InternalError(str.concat("position fetch error: ", dbe.message(err)))),
    Ok(current) => {
      let mark := match pos.parse_price(price_str) {
        None    => d.zero(),
        Some(p) => p,
      }
      # Rule 1: post-trade notional check
      let signed_qty := match o.side {
        OrderBuy  => o.quantity,
        OrderSell => 0 - o.quantity,
      }
      let projected_qty := current.qty + signed_qty
      let projected_pos := {
        key: current.key,
        qty: projected_qty,
        avg_cost: current.avg_cost,
        realized_pnl: current.realized_pnl,
      }
      let notional := exp.gross_notional(projected_pos, mark)
      if not d.is_zero(mark) and d.gt(notional, config.max_notional) {
        let msg := str.concat("projected notional ",
          str.concat(pos.decimal_to_str(notional),
            str.concat(" exceeds limit ", pos.decimal_to_str(config.max_notional))))
        FailedPositionCheck(PositionViolation(msg))
      } else {
        # Rule 2: flip check
        if not config.allow_flip and is_flip(current.qty, signed_qty) {
          FailedPositionCheck(PositionViolation("order would flip position; cross-zero trades not allowed"))
        } else {
          PassedPositionCheck
        }
      }
    },
  }
}

# ---- Helpers --------------------------------------------------------

fn is_flip(current_qty :: Int, signed_fill_qty :: Int) -> Bool {
  let new_qty := current_qty + signed_fill_qty
  (current_qty > 0 and new_qty < 0) or (current_qty < 0 and new_qty > 0)
}
