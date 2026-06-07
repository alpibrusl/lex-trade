# lex-trade — RiskLimit types
#
# Defines the risk-limit record and the pure predicates that the
# validation pipeline uses to gate an order before FIX encoding.
#
# max_notional_str  — upper bound on notional value, as a formatted
#                     string (e.g. "5000000.00") for audit-trail
#                     display. The validation pipeline does not
#                     currently enforce notional; a Money-based check
#                     is the intended follow-up once lex-money
#                     integration is wired.
# allowed_symbols   — empty list means all symbols are permitted.
# allowed_sides     — "buy" and/or "sell".
#
# Effects: none.

import "std.list" as list

type RiskLimit = { max_order_qty :: Int, max_notional_str :: Str, allowed_symbols :: List[Str], allowed_sides :: List[Str] }

fn default_limits() -> RiskLimit {
  { max_order_qty: 1000000, max_notional_str: "500000000.00", allowed_symbols: [], allowed_sides: ["buy", "sell"] }
}

fn within_qty(limit :: RiskLimit, qty :: Int) -> Bool {
  qty <= limit.max_order_qty
}

fn symbol_allowed(limit :: RiskLimit, symbol :: Str) -> Bool {
  if list.is_empty(limit.allowed_symbols) {
    true
  } else {
    list.fold(limit.allowed_symbols, false, fn (acc :: Bool, s :: Str) -> Bool {
      if acc {
        true
      } else {
        s == symbol
      }
    })
  }
}

fn side_allowed(limit :: RiskLimit, side :: Str) -> Bool {
  list.fold(limit.allowed_sides, false, fn (acc :: Bool, s :: Str) -> Bool {
    if acc {
      true
    } else {
      s == side
    }
  })
}

