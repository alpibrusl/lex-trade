# lex-trade — order lifecycle state machine
#
# Models the lifecycle of a single order from submission through terminal state.
# All transitions are pure — no effects, fully testable.
#
# transition(state, event) produces Ok(new_state) for valid transitions
# and Err(reason) for invalid ones (e.g. Fill on a Canceled order).
#
# from_execution_report converts a FIX ExecutionReport into an OrderEvent.
#
# Effects: none.

import "std.str" as str

import "lex-fix/src/v44/execution_report" as er
import "lex-fix/src/v44/enums"            as en

import "lex-money/src/decimal" as d
import "lex-money/src/rounding" as r

import "lex-positions/src/position" as pos

# ---- State ----------------------------------------------------------

type OrderState =
    PendingNew
  | New
  | PartiallyFilled(Int, d.Decimal)   # filled_qty, avg_price
  | Filled(d.Decimal)                  # avg_price
  | PendingCancel
  | Canceled(Int)                      # leaves_qty at cancel time
  | Rejected(Str)                      # exchange rejection reason
  | Expired

# ---- Event ----------------------------------------------------------

type OrderEvent =
    ExchangeAck(Str)                   # order_id assigned by exchange
  | PartialFill(Int, d.Decimal)        # qty filled this report, fill price
  | FullFill(d.Decimal)               # final fill price
  | CancelAck
  | ExchangeReject(Str)               # rejection message

# ---- Predicates -----------------------------------------------------

fn is_terminal(state :: OrderState) -> Bool
  examples {
    is_terminal(Filled({ coefficient: 0, exponent: 0 })) => true,
    is_terminal(New)                                      => false,
    is_terminal(PendingNew)                               => false,
  }
{
  match state {
    Filled(_)   => true,
    Canceled(_) => true,
    Rejected(_) => true,
    Expired     => true,
    _           => false,
  }
}

fn is_cancelable(state :: OrderState) -> Bool
  examples {
    is_cancelable(New)                => true,
    is_cancelable(PendingNew)         => false,
    is_cancelable(Canceled(0))        => false,
  }
{
  match state {
    New                   => true,
    PartiallyFilled(_, _) => true,
    PendingCancel         => true,
    _                     => false,
  }
}

fn state_name(state :: OrderState) -> Str {
  match state {
    PendingNew            => "PendingNew",
    New                   => "New",
    PartiallyFilled(_, _) => "PartiallyFilled",
    Filled(_)             => "Filled",
    PendingCancel         => "PendingCancel",
    Canceled(_)           => "Canceled",
    Rejected(_)           => "Rejected",
    Expired               => "Expired",
  }
}

fn event_name(event :: OrderEvent) -> Str {
  match event {
    ExchangeAck(_)    => "ExchangeAck",
    PartialFill(_, _) => "PartialFill",
    FullFill(_)       => "FullFill",
    CancelAck         => "CancelAck",
    ExchangeReject(_) => "ExchangeReject",
  }
}

# ---- Transition table -----------------------------------------------

fn transition(state :: OrderState, event :: OrderEvent) -> Result[OrderState, Str] {
  match state {
    PendingNew => match event {
      ExchangeAck(_)      => Ok(New),
      ExchangeReject(msg) => Ok(Rejected(msg)),
      _                   => Err("invalid event " + event_name(event) + " in state PendingNew"),
    },

    New => match event {
      PartialFill(qty, price) => Ok(PartiallyFilled(qty, price)),
      FullFill(price)         => Ok(Filled(price)),
      CancelAck               => Ok(Canceled(0)),
      ExchangeReject(msg)     => Ok(Rejected(msg)),
      ExchangeAck(_)          => Err("duplicate ExchangeAck in state New"),
    },

    PartiallyFilled(filled_qty, old_avg) => match event {
      PartialFill(qty, price) => {
        let new_total := filled_qty + qty
        Ok(PartiallyFilled(new_total, waac(filled_qty, old_avg, qty, price, new_total)))
      },
      FullFill(price) => Ok(Filled(price)),
      CancelAck       => Ok(Canceled(0)),
      _               => Err("invalid event " + event_name(event) + " in state PartiallyFilled"),
    },

    PendingCancel => match event {
      CancelAck               => Ok(Canceled(0)),
      PartialFill(qty, price) => Ok(PartiallyFilled(qty, price)),
      FullFill(price)         => Ok(Filled(price)),
      _                       => Err("invalid event " + event_name(event) + " in state PendingCancel"),
    },

    Filled(_)   => Err("order already Filled; cannot apply event " + event_name(event)),
    Canceled(_) => Err("order already Canceled; cannot apply event " + event_name(event)),
    Rejected(_) => Err("order already Rejected; cannot apply event " + event_name(event)),
    Expired     => Err("order Expired; cannot apply event " + event_name(event)),
  }
}

# ---- ExecutionReport → OrderEvent -----------------------------------

fn from_execution_report(report :: er.ExecutionReport) -> Result[OrderEvent, Str] {
  match report.exec_type {
    ExecNew => Ok(ExchangeAck(report.order_id)),

    ExecPartialFill => match report.last_qty {
      None          => Err("PartialFill ER missing last_qty"),
      Some(qty_str) => match report.last_px {
        None         => Err("PartialFill ER missing last_px"),
        Some(px_str) => match pos.parse_price(qty_str) {
          None          => Err("cannot parse last_qty: " + qty_str),
          Some(qty_dec) => match pos.decimal_to_int(qty_dec) {
            None      => Err("last_qty is not integer: " + qty_str),
            Some(qty) => match pos.parse_price(px_str) {
              None        => Err("cannot parse last_px: " + px_str),
              Some(price) => Ok(PartialFill(qty, price)),
            },
          },
        },
      },
    },

    ExecFill => {
      let price_str := match report.last_px {
        Some(p) => p,
        None    => report.avg_px,
      }
      match pos.parse_price(price_str) {
        None        => Err("cannot parse fill price: " + price_str),
        Some(price) => Ok(FullFill(price)),
      }
    },

    ExecCanceled => Ok(CancelAck),

    ExecRejected => Ok(ExchangeReject(match report.text {
      Some(t) => t,
      None    => "exchange rejection (no reason given)",
    })),

    ExecPendingNew    => Err("ExecPendingNew is informational; no lifecycle event"),
    ExecPendingCancel => Err("ExecPendingCancel is informational; no lifecycle event"),
    ExecReplaced      => Err("ExecReplaced starts a new lifecycle; track the new cl_ord_id"),
  }
}

# ---- Internal -------------------------------------------------------

fn waac(old_qty :: Int, old_avg :: d.Decimal, fill_qty :: Int, fill_price :: d.Decimal, new_qty :: Int) -> d.Decimal {
  let numer := d.add(
    d.mul(d.from_int(old_qty), old_avg),
    d.mul(d.from_int(fill_qty), fill_price)
  )
  let rounded := r.round_to(numer, -8, HalfEven)
  { coefficient: rounded.coefficient / new_qty, exponent: -8 }
}
