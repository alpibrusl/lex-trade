# lex-trade — lex-trail event kind constants
#
# Finance-specific event kinds for the execution audit trail.
# Appended by validation_io.lex during the validate-and-log cycle.
#
# Naming convention: "trade.<noun>.<verb>" (past tense)
# Effects: none.

fn order_validated() -> Str {
  "trade.order.validated"
}

fn order_accepted() -> Str {
  "trade.order.accepted"
}

fn order_rejected() -> Str {
  "trade.order.rejected"
}

