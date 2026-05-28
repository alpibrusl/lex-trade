# lex-trade — effectful validation wrapper
#
# Wraps the pure `validation.validate` pipeline with lex-trail logging.
# Two events are appended per call:
#   1. trade.order.validated  — order context (symbol, side, qty, routing)
#   2. trade.order.accepted | trade.order.rejected — outcome, parented on #1
#
# When ref_price is Some(p), a price-tolerance gate runs first.
# Pass None to skip it (useful in tests and market orders).
#
# The caller is responsible for opening and closing the Log handle.
#
# Effects: [sql, time]

import "std.str" as str
import "std.int" as int
import "std.list" as list

import "lex-money/src/decimal" as d

import "lex-trail/src/log" as trail_log

import "./order"        as order
import "./limit"        as limit
import "./validation"   as v
import "./rejection"    as rejection
import "./trail_kinds"  as kinds
import "./price_check"  as pc

# ---- JSON payload builders ---------------------------------------

fn side_str(s :: order.OrderSide) -> Str {
  match s {
    OrderBuy  => "buy",
    OrderSell => "sell",
  }
}

fn q(s :: Str) -> Str {
  str.concat("\"", str.concat(s, "\""))
}

fn order_payload(o :: order.Order, sender :: Str, target :: Str) -> Str {
  let parts := [
    str.concat("\"order_id\":",  q(o.id)),
    str.concat(",\"symbol\":",   q(o.symbol)),
    str.concat(",\"side\":",     q(side_str(o.side))),
    str.concat(",\"quantity\":", int.to_str(o.quantity)),
    str.concat(",\"account\":",  q(o.account)),
    str.concat(",\"sender\":",   q(sender)),
    str.concat(",\"target\":",   q(target)),
  ]
  let inner := list.fold(parts, "", fn (acc :: Str, s :: Str) -> Str { str.concat(acc, s) })
  str.concat("{", str.concat(inner, "}"))
}

fn rejection_payload(vs :: List[rejection.RejectionReason]) -> Str {
  let descs := list.map(vs, rejection.describe)
  let joined := list.fold(descs, "",
    fn (acc :: Str, m :: Str) -> Str {
      if acc == "" { q(m) }
      else { str.concat(acc, str.concat(",", q(m))) }
    })
  str.concat("{\"result\":\"Rejected\",\"violations\":[",
    str.concat(joined, "]}"))
}

# ---- Public API -------------------------------------------------

fn validate_and_log(
  o         :: order.Order,
  lim       :: limit.RiskLimit,
  ref_price :: Option[d.Decimal],
  tolerance :: pc.PriceTolerance,
  sender    :: Str,
  target    :: Str,
  log       :: trail_log.Log
) -> [sql, time] v.ValidationResult {
  # Gate 1 — price tolerance (skipped when ref_price is None)
  let price_rejected := match ref_price {
    None    => None,
    Some(rp) => match pc.check_price_tolerance(o, rp, tolerance) {
      PriceOk              => None,
      PriceRejected(reason) => Some(reason),
    },
  }

  let result := match price_rejected {
    Some(reason) => Rejected([reason]),
    None         => v.validate(o, lim, sender, target),
  }

  let ctx_payload := order_payload(o, sender, target)
  let parent_id := match trail_log.append(log, kinds.order_validated(), None, ctx_payload) {
    Ok(evt) => Some(evt.id),
    Err(_)  => None,
  }

  let outcome_kind := match result {
    Accepted(_) => kinds.order_accepted(),
    Rejected(_) => kinds.order_rejected(),
  }
  let outcome_payload := match result {
    Accepted(_)  => "{\"result\":\"Accepted\"}",
    Rejected(vs) => rejection_payload(vs),
  }
  let _ := trail_log.append(log, outcome_kind, parent_id, outcome_payload)

  result
}
