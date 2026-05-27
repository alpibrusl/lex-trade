# lex-trade — effectful validation wrapper (stub)
#
# Production use: wrap `validation.validate` and log the result to
# lex-trail. Logging is stubbed here — import lex-trail and call
# trail.append when the dependency is available.
#
# Effects: [io]

import "./order"      as order
import "./limit"      as limit
import "./validation" as v

fn validate_and_log(
  o      :: order.Order,
  lim    :: limit.RiskLimit,
  sender :: Str,
  target :: Str
) -> [io] v.ValidationResult {
  # TODO: open a trail, log the order, log the result, close the trail.
  # For now: pure validation, no logging.
  v.validate(o, lim, sender, target)
}
