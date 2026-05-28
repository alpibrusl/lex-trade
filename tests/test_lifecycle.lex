# Tests for src/lifecycle.lex — pure state machine.
#
# Covers the full transition graph and from_execution_report mapping.

import "std.list" as list

import "lex-fix/src/v44/execution_report" as er
import "lex-fix/src/v44/enums"            as en

import "lex-money/src/decimal" as d

import "../src/lifecycle" as lc

fn pass() -> Result[Unit, Str] { Ok(()) }
fn fail(why :: Str) -> Result[Unit, Str] { Err(why) }
fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond { pass() } else { fail(label) }
}
fn assert_ok[T](r :: Result[T, Str], label :: Str) -> Result[Unit, Str] {
  match r { Ok(_) => pass(), Err(e) => fail(label + ": " + e) }
}
fn assert_err[T](r :: Result[T, Str], label :: Str) -> Result[Unit, Str] {
  match r { Err(_) => pass(), Ok(_) => fail(label + " should be Err") }
}

fn price(c :: Int, e :: Int) -> d.Decimal { d.decimal(c, e) }

# ---- Transitions from PendingNew ------------------------------------

fn test_pending_new_ack() -> Result[Unit, Str] {
  match lc.transition(PendingNew, ExchangeAck("ORD-001")) {
    Ok(New) => pass(),
    Ok(_)   => fail("expected New"),
    Err(e)  => fail(e),
  }
}

fn test_pending_new_reject() -> Result[Unit, Str] {
  match lc.transition(PendingNew, ExchangeReject("no market")) {
    Ok(Rejected(_)) => pass(),
    Ok(_)           => fail("expected Rejected"),
    Err(e)          => fail(e),
  }
}

fn test_pending_new_fill_is_invalid() -> Result[Unit, Str] {
  assert_err(lc.transition(PendingNew, FullFill(price(1000, -2))), "fill on PendingNew")
}

# ---- Transitions from New ------------------------------------------

fn test_new_partial_fill() -> Result[Unit, Str] {
  match lc.transition(New, PartialFill(50, price(1000, -2))) {
    Ok(PartiallyFilled(50, _)) => pass(),
    Ok(_)                      => fail("expected PartiallyFilled(50, ...)"),
    Err(e)                     => fail(e),
  }
}

fn test_new_full_fill() -> Result[Unit, Str] {
  match lc.transition(New, FullFill(price(1050, -2))) {
    Ok(Filled(_)) => pass(),
    Ok(_)         => fail("expected Filled"),
    Err(e)        => fail(e),
  }
}

fn test_new_cancel_ack() -> Result[Unit, Str] {
  match lc.transition(New, CancelAck) {
    Ok(Canceled(0)) => pass(),
    Ok(_)           => fail("expected Canceled(0)"),
    Err(e)          => fail(e),
  }
}

fn test_new_duplicate_ack_is_error() -> Result[Unit, Str] {
  assert_err(lc.transition(New, ExchangeAck("ORD-002")), "duplicate ack on New")
}

# ---- Transitions from PartiallyFilled ------------------------------

fn test_partially_filled_additional_fill() -> Result[Unit, Str] {
  let state := PartiallyFilled(50, price(1000, -2))
  match lc.transition(state, PartialFill(50, price(1100, -2))) {
    Ok(PartiallyFilled(100, _)) => pass(),
    Ok(_)                       => fail("expected PartiallyFilled(100, ...)"),
    Err(e)                      => fail(e),
  }
}

fn test_partially_filled_to_filled() -> Result[Unit, Str] {
  let state := PartiallyFilled(50, price(1000, -2))
  match lc.transition(state, FullFill(price(1050, -2))) {
    Ok(Filled(_)) => pass(),
    Ok(_)         => fail("expected Filled"),
    Err(e)        => fail(e),
  }
}

fn test_partially_filled_cancel() -> Result[Unit, Str] {
  let state := PartiallyFilled(50, price(1000, -2))
  match lc.transition(state, CancelAck) {
    Ok(Canceled(0)) => pass(),
    Ok(_)           => fail("expected Canceled"),
    Err(e)          => fail(e),
  }
}

# ---- Terminal states reject all events -----------------------------

fn test_filled_rejects_events() -> Result[Unit, Str] {
  let state := Filled(price(1000, -2))
  assert_err(lc.transition(state, CancelAck), "cancel on Filled")
}

fn test_canceled_rejects_events() -> Result[Unit, Str] {
  let state := Canceled(50)
  assert_err(lc.transition(state, FullFill(price(1000, -2))), "fill on Canceled")
}

fn test_rejected_rejects_events() -> Result[Unit, Str] {
  let state := Rejected("bad order")
  assert_err(lc.transition(state, ExchangeAck("ORD-003")), "ack on Rejected")
}

# ---- is_cancelable predicate ----------------------------------------

fn test_is_cancelable() -> Result[Unit, Str] {
  let yes1 := lc.is_cancelable(New)
  let yes2 := lc.is_cancelable(PartiallyFilled(10, price(1000, -2)))
  let yes3 := lc.is_cancelable(PendingCancel)
  let no1  := lc.is_cancelable(PendingNew)
  let no2  := lc.is_cancelable(Filled(price(0, 0)))
  let no3  := lc.is_cancelable(Canceled(0))
  match assert_true(yes1 and yes2 and yes3, "cancelable states") {
    Err(e) => Err(e),
    Ok(_)  => assert_true(not no1 and not no2 and not no3, "non-cancelable states"),
  }
}

# ---- is_terminal predicate ------------------------------------------

fn test_is_terminal() -> Result[Unit, Str] {
  let t1 := lc.is_terminal(Filled(price(0, 0)))
  let t2 := lc.is_terminal(Canceled(0))
  let t3 := lc.is_terminal(Rejected("x"))
  let t4 := lc.is_terminal(Expired)
  let f1 := lc.is_terminal(New)
  let f2 := lc.is_terminal(PendingNew)
  let f3 := lc.is_terminal(PartiallyFilled(1, price(0, 0)))
  match assert_true(t1 and t2 and t3 and t4, "terminal states") {
    Err(e) => Err(e),
    Ok(_)  => assert_true(not f1 and not f2 and not f3, "non-terminal states"),
  }
}

# ---- from_execution_report ------------------------------------------

fn sample_er(exec_type :: en.ExecType) -> er.ExecutionReport {
  {
    exec_id:    "E001",
    order_id:   "ORD-001",
    cl_ord_id:  "CL-001",
    exec_type:  exec_type,
    ord_status: StatusNew,
    symbol:     "AAPL",
    side:       Buy,
    order_qty:  "100",
    cum_qty:    "0",
    leaves_qty: "100",
    avg_px:     "0",
    last_px:    None,
    last_qty:   None,
    text:       None,
  }
}

fn test_from_er_exec_new() -> Result[Unit, Str] {
  match lc.from_execution_report(sample_er(ExecNew)) {
    Ok(ExchangeAck("ORD-001")) => pass(),
    Ok(_)                      => fail("expected ExchangeAck(ORD-001)"),
    Err(e)                     => fail(e),
  }
}

fn test_from_er_exec_fill() -> Result[Unit, Str] {
  let report := {
    exec_id:    "E002",
    order_id:   "ORD-001",
    cl_ord_id:  "CL-001",
    exec_type:  ExecFill,
    ord_status: StatusFilled,
    symbol:     "AAPL",
    side:       Buy,
    order_qty:  "100",
    cum_qty:    "100",
    leaves_qty: "0",
    avg_px:     "10.50",
    last_px:    Some("10.50"),
    last_qty:   Some("100"),
    text:       None,
  }
  match lc.from_execution_report(report) {
    Ok(FullFill(_)) => pass(),
    Ok(_)           => fail("expected FullFill"),
    Err(e)          => fail(e),
  }
}

fn test_from_er_exec_canceled() -> Result[Unit, Str] {
  match lc.from_execution_report(sample_er(ExecCanceled)) {
    Ok(CancelAck) => pass(),
    Ok(_)         => fail("expected CancelAck"),
    Err(e)        => fail(e),
  }
}

fn test_from_er_pending_new_is_err() -> Result[Unit, Str] {
  match lc.from_execution_report(sample_er(ExecPendingNew)) {
    Err(_) => pass(),
    Ok(_)  => fail("ExecPendingNew should return Err"),
  }
}

# ---- Suite ----------------------------------------------------------

fn suite() -> List[Result[Unit, Str]] {
  [
    test_pending_new_ack(),
    test_pending_new_reject(),
    test_pending_new_fill_is_invalid(),
    test_new_partial_fill(),
    test_new_full_fill(),
    test_new_cancel_ack(),
    test_new_duplicate_ack_is_error(),
    test_partially_filled_additional_fill(),
    test_partially_filled_to_filled(),
    test_partially_filled_cancel(),
    test_filled_rejects_events(),
    test_canceled_rejects_events(),
    test_rejected_rejects_events(),
    test_is_cancelable(),
    test_is_terminal(),
    test_from_er_exec_new(),
    test_from_er_exec_fill(),
    test_from_er_exec_canceled(),
    test_from_er_pending_new_is_err(),
  ]
}

fn run_all() -> Int {
  list.fold(suite(), 0, fn (acc :: Int, r :: Result[Unit, Str]) -> Int {
    match r { Ok(_) => acc, Err(_) => acc + 1 }
  })
}
