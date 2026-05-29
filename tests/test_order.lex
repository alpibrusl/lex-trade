# tests for src/order.lex

import "std.list" as list

import "lex-fix/src/v44/enums" as en

import "../src/order" as order

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

fn test_order_to_fix_side_buy() -> Result[Unit, Str] {
  let s := order.order_to_fix_side(OrderBuy(()))
  match s {
    Buy(_) => pass(),
    Sell(_) => fail("expected Buy"),
  }
}

fn test_order_to_fix_side_sell() -> Result[Unit, Str] {
  let s := order.order_to_fix_side(OrderSell(()))
  match s {
    Sell(_) => pass(),
    Buy(_) => fail("expected Sell"),
  }
}

fn test_order_to_ord_type_market() -> Result[Unit, Str] {
  let t := order.order_to_ord_type(MarketOrder(()))
  match t {
    Market(_) => pass(),
    Limit(_) => fail("expected Market"),
    Stop(_) => fail("expected Market"),
    StopLimit(_) => fail("expected Market"),
  }
}

fn test_order_to_ord_type_limit() -> Result[Unit, Str] {
  let t := order.order_to_ord_type(LimitOrder("125.50"))
  match t {
    Limit(_) => pass(),
    Market(_) => fail("expected Limit"),
    Stop(_) => fail("expected Limit"),
    StopLimit(_) => fail("expected Limit"),
  }
}

fn test_order_price_limit() -> Result[Unit, Str] {
  let p := order.order_price(LimitOrder("125.50"))
  match p {
    None => fail("expected Some"),
    Some(v) => assert_true(v == "125.50", "price should be 125.50"),
  }
}

fn test_order_price_market() -> Result[Unit, Str] {
  let p := order.order_price(MarketOrder(()))
  match p {
    None => pass(),
    Some(_) => fail("expected None for market order"),
  }
}

fn test_order_to_nos() -> Result[Unit, Str] {
  let o := order.order("ORD-001", "MSFT", OrderBuy(()), 100, LimitOrder("125.50"), "0", "ACCOUNT-A", "TRADER-01", "20260527-09:30:00.000")
  let n := order.order_to_nos(o, "ALGO01", "EXCH01")
  assert_true(n.cl_ord_id == "ORD-001", "cl_ord_id")
}

fn suite() -> List[Result[Unit, Str]] {
  [test_order_to_fix_side_buy(), test_order_to_fix_side_sell(), test_order_to_ord_type_market(), test_order_to_ord_type_limit(), test_order_price_limit(), test_order_price_market(), test_order_to_nos()]
}

fn run_all() -> Int {
  list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
}

