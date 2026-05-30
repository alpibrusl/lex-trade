# lex-trade — effectful validation wrapper
#
# Wraps the pure `validation.validate` pipeline with lex-trail logging.
# Two events are appended per call:
#   1. trade.order.validated  — order context (symbol, side, qty, routing)
#   2. trade.order.accepted | trade.order.rejected — outcome, parented on #1
#
# validate_log_and_record additionally writes all decision inputs to the
# reconstruction store (src/reconstruct.lex) so they can be replayed later.
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

import "./order" as order

import "./limit" as limit

import "./validation" as v

import "./rejection" as rejection

import "./trail_kinds" as kinds

import "./price_check" as pc

import "./reconstruct" as rc

# ---- Result type -------------------------------------------------
# Returned by validate_log_and_record; carries both the validation
# result and the trail entry_id needed to call reconstruct.reconstruct.
type LogAndRecord = { result :: v.ValidationResult, entry_id :: Str }

# ---- JSON payload builders ---------------------------------------
fn side_str(s :: order.OrderSide) -> Str {
  match s {
    OrderBuy(_) => "buy",
    OrderSell(_) => "sell",
  }
}

fn q(s :: Str) -> Str {
  str.concat("\"", str.concat(s, "\""))
}

fn order_payload(o :: order.Order, sender :: Str, target :: Str) -> Str {
  let parts := [str.concat("\"order_id\":", q(o.id)), str.concat(",\"symbol\":", q(o.symbol)), str.concat(",\"side\":", q(side_str(o.side))), str.concat(",\"quantity\":", int.to_str(o.quantity)), str.concat(",\"account\":", q(o.account)), str.concat(",\"sender\":", q(sender)), str.concat(",\"target\":", q(target))]
  let inner := list.fold(parts, "", fn (acc :: Str, s :: Str) -> Str {
    str.concat(acc, s)
  })
  str.concat("{", str.concat(inner, "}"))
}

fn rejection_payload(vs :: List[rejection.RejectionReason]) -> Str {
  let descs := list.map(vs, rejection.describe)
  let joined := list.fold(descs, "", fn (acc :: Str, m :: Str) -> Str {
    if acc == "" {
      q(m)
    } else {
      str.concat(acc, str.concat(",", q(m)))
    }
  })
  str.concat("{\"result\":\"Rejected\",\"violations\":[", str.concat(joined, "]}"))
}

# ---- Public API -------------------------------------------------
fn validate_and_log(o :: order.Order, lim :: limit.RiskLimit, ref_price :: Option[d.Decimal], tolerance :: pc.PriceTolerance, sender :: Str, target :: Str, log :: trail_log.Log) -> [sql, time] v.ValidationResult {
  let price_rejected := match ref_price {
    None => None,
    Some(rp) => match pc.check_price_tolerance(o, rp, tolerance) {
      Ok(_) => None,
      Err(reason) => Some(reason),
    },
  }
  let result := match price_rejected {
    Some(reason) => Rejected([reason]),
    None => v.validate(o, lim, sender, target),
  }
  let ctx_payload := order_payload(o, sender, target)
  let parent_id := match trail_log.append(log, kinds.order_validated(), None, ctx_payload) {
    Ok(evt) => Some(evt.id),
    Err(_) => None,
  }
  let outcome_kind := match result {
    Accepted(_) => kinds.order_accepted(),
    Rejected(_) => kinds.order_rejected(),
  }
  let outcome_payload := match result {
    Accepted(_) => "{\"result\":\"Accepted\"}",
    Rejected(vs) => rejection_payload(vs),
  }
  let __lex_discard_1 := trail_log.append(log, outcome_kind, parent_id, outcome_payload)
  result
}

# validate_log_and_record — like validate_and_log but also writes the full
# decision record to the reconstruction store so it can be replayed later.
# Returns both the ValidationResult and the trail entry_id.
#
# algo_sig_id should be the SigId of validation.validate at deploy time
# (compute with `lex sig-id src/validation.lex:validate`). Pass "" to
# skip provenance tracking.
fn validate_log_and_record(o :: order.Order, lim :: limit.RiskLimit, ref_price :: Option[d.Decimal], tolerance :: pc.PriceTolerance, sender :: Str, target :: Str, log :: trail_log.Log, algo_sig_id :: Str) -> [sql, time] LogAndRecord {
  let price_rejected := match ref_price {
    None => None,
    Some(rp) => match pc.check_price_tolerance(o, rp, tolerance) {
      Ok(_) => None,
      Err(reason) => Some(reason),
    },
  }
  let result := match price_rejected {
    Some(reason) => Rejected([reason]),
    None => v.validate(o, lim, sender, target),
  }
  let ctx_payload := order_payload(o, sender, target)
  let outcome_kind := match result {
    Accepted(_) => kinds.order_accepted(),
    Rejected(_) => kinds.order_rejected(),
  }
  let outcome_payload := match result {
    Accepted(_) => "{\"result\":\"Accepted\"}",
    Rejected(vs) => rejection_payload(vs),
  }
  match trail_log.append(log, kinds.order_validated(), None, ctx_payload) {
    Err(_) => {
      let __o := trail_log.append(log, outcome_kind, None, outcome_payload)
      { result: result, entry_id: "" }
    },
    Ok(ctx_evt) => {
      let __o := trail_log.append(log, outcome_kind, Some(ctx_evt.id), outcome_payload)
      let __rc := rc.write_reconstruct(log.db, ctx_evt.id, o, lim, ref_price, sender, target, result, algo_sig_id, ctx_evt.ts_ms)
      { result: result, entry_id: ctx_evt.id }
    },
  }
}

