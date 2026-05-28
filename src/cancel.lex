# lex-trade — cancel workflow validation
#
# validate_cancel checks that an order is in a cancelable state before
# emitting an OrderCancelRequest. The order state is looked up from
# order_store; if the order is not found, it is treated as PendingNew
# (not yet cancelable).
#
# Rejection reasons:
#   OrderNotCancelable(state_name) — order is terminal or not yet acked
#   InternalError(msg)             — order_store lookup failed
#
# Effects: [orders, sql]

import "std.str" as str

import "lex-fix/src/v44/order_cancel_request" as ocr
import "lex-fix/src/v44/enums"                as en

import "lex-orm/src/connection" as conn
import "lex-orm/src/error"      as dbe

import "./lifecycle"  as lc
import "./order_store" as ostore
import "./rejection"  as rejection
import "./order"      as order

fn validate_cancel(
  db            :: conn.ConnDb,
  cl_ord_id     :: Str,
  orig_cl_ord_id :: Str,
  account       :: Str,
  symbol        :: Str,
  side          :: order.OrderSide,
  order_qty     :: Int,
  transact_time :: Str,
  sender        :: Str,
  target        :: Str
) -> [orders, sql] Result[ocr.OrderCancelRequest, rejection.RejectionReason] {
  match ostore.fetch(db, orig_cl_ord_id, account) {
    Err(err) => Err(InternalError(dbe.message(err))),
    Ok(opt_state) => {
      let state := match opt_state {
        None    => PendingNew,
        Some(s) => s,
      }
      if not lc.is_cancelable(state) {
        Err(OrderNotCancelable(lc.state_name(state)))
      } else {
        let fix_side := match side {
          OrderBuy  => Buy,
          OrderSell => Sell,
        }
        Ok({
          cl_ord_id:      cl_ord_id,
          orig_cl_ord_id: orig_cl_ord_id,
          symbol:         symbol,
          side:           fix_side,
          order_qty:      order_qty,
          transact_time:  transact_time,
          sender_comp_id: sender,
          target_comp_id: target,
          account:        Some(account),
          text:           None,
        })
      }
    },
  }
}
