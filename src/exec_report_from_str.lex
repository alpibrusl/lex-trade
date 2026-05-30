# lex-trade — execution report adapter from raw strings
#
# Provides a string-based API so lex-oms does not need to import
# lex-fix directly (which would create duplicate module-hash conflicts
# with the lex-fix instances already loaded transitively via lex-trade
# and lex-positions).
#
# Effects: none.

import "lex-fix/src/v44/enums" as en

import "lex-fix/src/v44/execution_report" as er

import "lex-positions/src/position" as pos

import "lex-positions/src/fill_from_er" as ffer

import "./lifecycle" as lc

type ExecOutcome = { event :: lc.OrderEvent, fill :: List[pos.Fill] }

fn parse_exec_type(s :: Str) -> Result[en.ExecType, Str] {
  if s == "0" or s == "new" {
    Ok(ExecNew(()))
  } else {
    if s == "1" or s == "partial_fill" {
      Ok(ExecPartialFill(()))
    } else {
      if s == "2" or s == "fill" {
        Ok(ExecFill(()))
      } else {
        if s == "4" or s == "canceled" {
          Ok(ExecCanceled(()))
        } else {
          if s == "A" or s == "pending_new" {
            Ok(ExecPendingNew(()))
          } else {
            Err("unknown exec_type: " + s)
          }
        }
      }
    }
  }
}

fn parse_ord_status(s :: Str) -> Result[en.OrdStatus, Str] {
  if s == "0" or s == "new" {
    Ok(StatusNew(()))
  } else {
    if s == "1" or s == "partially_filled" {
      Ok(StatusPartiallyFilled(()))
    } else {
      if s == "2" or s == "filled" {
        Ok(StatusFilled(()))
      } else {
        if s == "4" or s == "canceled" {
          Ok(StatusCanceled(()))
        } else {
          Err("unknown ord_status: " + s)
        }
      }
    }
  }
}

fn parse_fix_side(s :: Str) -> Result[en.Side, Str] {
  if s == "buy" or s == "1" {
    Ok(Buy(()))
  } else {
    if s == "sell" or s == "2" {
      Ok(Sell(()))
    } else {
      Err("invalid side: " + s)
    }
  }
}

fn from_strings(exec_id :: Str, order_id :: Str, cl_ord_id :: Str, exec_type :: Str, ord_status :: Str, symbol :: Str, side :: Str, order_qty :: Str, cum_qty :: Str, leaves_qty :: Str, avg_px :: Str, last_px :: Str, last_qty :: Str, text :: Str) -> Result[ExecOutcome, Str] {
  match parse_exec_type(exec_type) {
    Err(e) => Err(e),
    Ok(et) => match parse_ord_status(ord_status) {
      Err(e) => Err(e),
      Ok(os) => match parse_fix_side(side) {
        Err(e) => Err(e),
        Ok(fs) => {
          let report := { exec_id: exec_id, order_id: order_id, cl_ord_id: cl_ord_id, exec_type: et, ord_status: os, symbol: symbol, side: fs, order_qty: order_qty, cum_qty: cum_qty, leaves_qty: leaves_qty, avg_px: avg_px, last_px: last_px, last_qty: last_qty, text: text }
          match lc.from_execution_report(report) {
            Err(msg) => Err(msg),
            Ok(event) => Ok({ event: event, fill: ffer.fill_from_er(report) }),
          }
        },
      },
    },
  }
}

