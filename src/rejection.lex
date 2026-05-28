# lex-trade — Rejection ADT
#
# All reasons an order can be rejected before market submission.
# Variants carry the data needed to produce an audit-trail entry
# or a human-readable explanation.
#
# Effects: none.

import "std.str"  as str
import "std.int"  as int
import "std.list" as list

type RejectionReason =
    ExceedsMaxQty(Int, Int)
  | SymbolNotAllowed(Str)
  | SideNotAllowed(Str)
  | FixConformanceFailure(List[Str])
  | PositionViolation(Str)
  | OrderNotCancelable(Str)
  | InternalError(Str)

fn describe(r :: RejectionReason) -> Str {
  match r {
    ExceedsMaxQty(qty, max) =>
      str.concat("quantity ",
        str.concat(int.to_str(qty),
          str.concat(" exceeds limit of ", int.to_str(max)))),
    SymbolNotAllowed(sym) =>
      str.concat("symbol not allowed: ", sym),
    SideNotAllowed(side) =>
      str.concat("side not allowed: ", side),
    FixConformanceFailure(msgs) =>
      str.concat("FIX conformance failure: ",
        list.fold(msgs, "",
          fn (acc :: Str, m :: Str) -> Str {
            if acc == "" { m }
            else { str.concat(acc, str.concat("; ", m)) }
          })),
    PositionViolation(msg) =>
      str.concat("position violation: ", msg),
    OrderNotCancelable(state) =>
      str.concat("order not cancelable in state: ", state),
    InternalError(msg) =>
      str.concat("internal error: ", msg),
  }
}
