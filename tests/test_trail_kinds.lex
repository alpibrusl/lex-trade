# tests for src/trail_kinds.lex

import "std.list" as list

import "../src/trail_kinds" as kinds

fn pass() -> Result[Unit, Str] {
  Ok(())
}

fn fail(why :: Str) -> Result[Unit, Str] {
  Err(why)
}

fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond {
    pass()
  } else {
    fail(label)
  }
}

fn test_validated_kind() -> Result[Unit, Str] {
  assert_true(kinds.order_validated() == "trade.order.validated", "validated kind")
}

fn test_accepted_kind() -> Result[Unit, Str] {
  assert_true(kinds.order_accepted() == "trade.order.accepted", "accepted kind")
}

fn test_rejected_kind() -> Result[Unit, Str] {
  assert_true(kinds.order_rejected() == "trade.order.rejected", "rejected kind")
}

fn test_kinds_are_distinct() -> Result[Unit, Str] {
  let v := kinds.order_validated()
  let a := kinds.order_accepted()
  let r := kinds.order_rejected()
  assert_true(v != a and a != r and v != r, "all three kinds are distinct")
}

fn suite() -> List[Result[Unit, Str]] {
  [test_validated_kind(), test_accepted_kind(), test_rejected_kind(), test_kinds_are_distinct()]
}

fn run_all() -> Int {
  list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
}

