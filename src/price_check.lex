# lex-trade — limit price tolerance check
#
# Checks that a limit order's price does not deviate from a reference
# price by more than max_deviation_bps basis points (1 bps = 0.01%).
#
# Only applies to LimitOrder and StopLimitOrder; Market and Stop orders
# pass unconditionally (their price is set by the exchange).
#
# Deviation is computed without division using cross-multiplication:
#   |order_price - ref_price| * 10000 > ref_price * max_bps
#   ⟺ deviation_bps > max_deviation_bps
#
# Pure: no effects.

import "lex-money/src/decimal" as d

import "lex-positions/src/position" as pos

import "./order" as order

import "./rejection" as rejection

type PriceTolerance = { max_deviation_bps :: Int }

fn default_tolerance() -> PriceTolerance {
  { max_deviation_bps: 200 }
}

fn check_price_tolerance(o :: order.Order, ref_price :: d.Decimal, tolerance :: PriceTolerance) -> Result[Unit, rejection.RejectionReason] {
  let limit_price_str := match o.kind {
    MarketOrder(_) => None,
    LimitOrder(p) => Some(p),
    StopOrder(_) => None,
    StopLimitOrder(p, _) => Some(p),
  }
  match limit_price_str {
    None => Ok(()),
    Some(pstr) => match pos.parse_price(pstr) {
      None => Err(rejection.InternalError("unparseable limit price: " + pstr)),
      Some(ord_price) => check_deviation(ord_price, ref_price, tolerance.max_deviation_bps, pstr),
    },
  }
}

# ---- Internal -------------------------------------------------------
fn check_deviation(ord_price :: d.Decimal, ref_price :: d.Decimal, max_bps :: Int, price_str :: Str) -> Result[Unit, rejection.RejectionReason] {
  let diff := d.sub(ord_price, ref_price)
  let abs_diff := d.abs(diff)
  let lhs := d.mul(abs_diff, d.from_int(10000))
  let rhs := d.mul(d.abs(ref_price), d.from_int(max_bps))
  if d.gt(lhs, rhs) {
    let approx_bps := approx_bps_int(abs_diff, ref_price)
    let ref_str := pos.decimal_to_str(ref_price)
    Err(rejection.PriceToleranceBreached(price_str, ref_str, approx_bps))
  } else {
    Ok(())
  }
}

fn approx_bps_int(abs_diff :: d.Decimal, ref_price :: d.Decimal) -> Int {
  let diff_c := abs_diff.coefficient
  let ref_c := ref_price.coefficient
  let exp_diff := abs_diff.exponent - ref_price.exponent
  if exp_diff == 0 {
    diff_c * 10000 / ref_c
  } else {
    if exp_diff > 0 {
      diff_c * d.pow10(exp_diff) * 10000 / ref_c
    } else {
      diff_c * 10000 / (ref_c * d.pow10(0 - exp_diff))
    }
  }
}

