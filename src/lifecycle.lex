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

import "lex-fix/src/v44/enums" as en

import "lex-money/src/decimal" as d

import "lex-money/src/rounding" as r

import "lex-positions/src/position" as pos

# ---- State ----------------------------------------------------------
type OrderState = PendingNew(Unit) | New(Unit) | PartiallyFilled((Int, d.Decimal)) | Filled(d.Decimal) | PendingCancel(Unit) | Canceled(Int) | ExchangeRejected(Str) | Expired(Unit)

type OrderEvent = ExchangeAck(Str) | PartialFill((Int, d.Decimal)) | FullFill(d.Decimal) | CancelAck(Unit) | ExchangeReject(Str)

fn is_terminal(state :: OrderState) -> Bool
  examples {
    is_terminal(Filled({ coefficient: 0, exponent: 0 })) => true,
    is_terminal(New(())) => false,
    is_terminal(PendingNew(())) => false
  }
{
  match state {
    Filled(_) => true,
    Canceled(_) => true,
    ExchangeRejected(_) => true,
    Expired(_) => true,
    _ => false,
  }
}

fn is_cancelable(state :: OrderState) -> Bool
  examples {
    is_cancelable(New(())) => true,
    is_cancelable(PendingNew(())) => true,
    is_cancelable(Canceled(0)) => false
  }
{
  match state {
    New(_) => true,
    PendingNew(_) => true,
    PartiallyFilled(_, _) => true,
    PendingCancel(_) => true,
    _ => false,
  }
}

fn state_name(state :: OrderState) -> Str {
  match state {
    PendingNew(_) => "PendingNew",
    New(_) => "New",
    PartiallyFilled(_, _) => "PartiallyFilled",
    Filled(_) => "Filled",
    PendingCancel(_) => "PendingCancel",
    Canceled(_) => "Canceled",
    ExchangeRejected(_) => "Rejected",
    Expired(_) => "Expired",
  }
}

fn event_name(event :: OrderEvent) -> Str {
  match event {
    ExchangeAck(_) => "ExchangeAck",
    PartialFill(_, _) => "PartialFill",
    FullFill(_) => "FullFill",
    CancelAck(_) => "CancelAck",
    ExchangeReject(_) => "ExchangeReject",
  }
}

# ---- Transition table -----------------------------------------------
fn transition(state :: OrderState, event :: OrderEvent) -> Result[OrderState, Str] {
  match state {
    PendingNew(_) => match event {
      ExchangeAck(_) => Ok(New(())),
      ExchangeReject(msg) => Ok(ExchangeRejected(msg)),
      _ => Err("invalid event " + event_name(event) + " in state PendingNew"),
    },
    New(_) => match event {
      PartialFill(qty, price) => Ok(PartiallyFilled(qty, price)),
      FullFill(price) => Ok(Filled(price)),
      CancelAck(_) => Ok(Canceled(0)),
      ExchangeReject(msg) => Ok(ExchangeRejected(msg)),
      ExchangeAck(_) => Err("duplicate ExchangeAck in state New"),
    },
    PartiallyFilled(filled_qty, old_avg) => match event {
      PartialFill(qty, price) => {
        let new_total := filled_qty + qty
        Ok(PartiallyFilled(new_total, waac(filled_qty, old_avg, qty, price, new_total)))
      },
      FullFill(price) => Ok(Filled(price)),
      CancelAck(_) => Ok(Canceled(0)),
      _ => Err("invalid event " + event_name(event) + " in state PartiallyFilled"),
    },
    PendingCancel(_) => match event {
      CancelAck(_) => Ok(Canceled(0)),
      PartialFill(qty, price) => Ok(PartiallyFilled(qty, price)),
      FullFill(price) => Ok(Filled(price)),
      _ => Err("invalid event " + event_name(event) + " in state PendingCancel"),
    },
    Filled(_) => Err("order already Filled; cannot apply event " + event_name(event)),
    Canceled(_) => Err("order already Canceled; cannot apply event " + event_name(event)),
    ExchangeRejected(_) => Err("order already Rejected; cannot apply event " + event_name(event)),
    Expired(_) => Err("order Expired; cannot apply event " + event_name(event)),
  }
}

# ---- ExecutionReport → OrderEvent -----------------------------------
fn from_execution_report(report :: er.ExecutionReport) -> Result[OrderEvent, Str] {
  match report.exec_type {
    ExecNew(_) => Ok(ExchangeAck(report.order_id)),
    ExecPartialFill(_) => if str.is_empty(report.last_qty) {
      Err("PartialFill ER missing last_qty")
    } else {
      if str.is_empty(report.last_px) {
        Err("PartialFill ER missing last_px")
      } else {
        match pos.parse_price(report.last_qty) {
          None => Err("cannot parse last_qty: " + report.last_qty),
          Some(qty_dec) => match pos.decimal_to_int(qty_dec) {
            None => Err("last_qty is not integer: " + report.last_qty),
            Some(qty) => match pos.parse_price(report.last_px) {
              None => Err("cannot parse last_px: " + report.last_px),
              Some(price) => Ok(PartialFill(qty, price)),
            },
          },
        }
      }
    },
    ExecFill(_) => {
      let price_str := if str.is_empty(report.last_px) {
        report.avg_px
      } else {
        report.last_px
      }
      match pos.parse_price(price_str) {
        None => Err("cannot parse fill price: " + price_str),
        Some(price) => Ok(FullFill(price)),
      }
    },
    ExecCanceled(_) => Ok(CancelAck(())),
    ExecRejected(_) => Ok(ExchangeReject(if str.is_empty(report.text) {
      "exchange rejection (no reason given)"
    } else {
      report.text
    })),
    ExecPendingNew(_) => Err("ExecPendingNew is informational; no lifecycle event"),
    ExecPendingCancel(_) => Err("ExecPendingCancel is informational; no lifecycle event"),
    ExecReplaced(_) => Err("ExecReplaced starts a new lifecycle; track the new cl_ord_id"),
  }
}

# ---- Internal -------------------------------------------------------
fn waac(old_qty :: Int, old_avg :: d.Decimal, fill_qty :: Int, fill_price :: d.Decimal, new_qty :: Int) -> d.Decimal {
  let numer := d.add(d.mul(d.from_int(old_qty), old_avg), d.mul(d.from_int(fill_qty), fill_price))
  let rounded := r.round_to(numer, -8, HalfEven(()))
  { coefficient: rounded.coefficient / new_qty, exponent: -8 }
}

