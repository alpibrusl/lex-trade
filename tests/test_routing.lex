# tests for src/routing.lex — smart order routing

import "std.list" as list

import "lex-fix/src/venue" as vn

import "../src/order" as order

import "../src/limit" as limit

import "../src/routing" as rt

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

# ---- fixtures ---------------------------------------------------
fn buy_order() -> order.Order {
  order.order("ORD-100", "MSFT", OrderBuy(()), 100, LimitOrder("100.00"), "0", "ACC-A", "TRADER-1", "20260530-10:00:00.000")
}

fn sell_order() -> order.Order {
  order.order("ORD-200", "MSFT", OrderSell(()), 100, LimitOrder("100.00"), "0", "ACC-A", "TRADER-1", "20260530-10:00:00.000")
}

fn quotes() -> List[rt.Quote] {
  [{ venue: Nyse(()), bid: 9998, ask: 10002, fee: 30 }, { venue: Nasdaq(()), bid: 9999, ask: 10001, fee: 25 }, { venue: Lse(()), bid: 10000, ask: 10003, fee: 40 }]
}

# A tight limit so child orders above 50 are rejected.
fn small_limit() -> limit.RiskLimit {
  { max_order_qty: 50, max_notional_str: "0.00", allowed_symbols: [], allowed_sides: ["buy", "sell"] }
}

fn venue_is(r :: Result[vn.Venue, Str], want :: Str, label :: Str) -> Result[Unit, Str] {
  match r {
    Err(_) => fail(label),
    Ok(v) => assert_true(vn.venue_to_str(v) == want, label),
  }
}

fn child_qty_sum(children :: List[rt.ChildOrder]) -> Int {
  list.fold(children, 0, fn (acc :: Int, c :: rt.ChildOrder) -> Int {
    acc + c.order.quantity
  })
}

# ---- select_venue -----------------------------------------------
fn test_bestprice_buy_lowest_ask() -> Result[Unit, Str] {
  venue_is(rt.select_venue(buy_order(), BestPrice(()), quotes()), "NASDAQ", "buy routes to lowest ask")
}

fn test_bestprice_sell_highest_bid() -> Result[Unit, Str] {
  venue_is(rt.select_venue(sell_order(), BestPrice(()), quotes()), "LSE", "sell routes to highest bid")
}

fn test_mincost_lowest_fee() -> Result[Unit, Str] {
  venue_is(rt.select_venue(buy_order(), MinCost(()), quotes()), "NASDAQ", "MinCost routes to lowest fee")
}

fn test_sweep_first_quoted() -> Result[Unit, Str] {
  venue_is(rt.select_venue(buy_order(), Sweep([Cboe(()), Nyse(())]), quotes()), "NYSE", "sweep picks first quoted venue")
}

fn test_directto_bypasses_quotes() -> Result[Unit, Str] {
  venue_is(rt.select_venue(buy_order(), DirectTo(Lse(())), []), "LSE", "DirectTo returns the named venue")
}

fn test_bestprice_no_quotes_errs() -> Result[Unit, Str] {
  match rt.select_venue(buy_order(), BestPrice(()), []) {
    Ok(_) => fail("BestPrice with no quotes should error"),
    Err(_) => pass(),
  }
}

fn test_sweep_none_quoted_errs() -> Result[Unit, Str] {
  match rt.select_venue(buy_order(), Sweep([Cboe(()), Euronext(())]), quotes()) {
    Ok(_) => fail("Sweep with no quoted venue should error"),
    Err(_) => pass(),
  }
}

# ---- split_order ------------------------------------------------
fn test_split_conserves_quantity() -> Result[Unit, Str] {
  match rt.split_order(buy_order(), [{ venue: Nyse(()), qty: 60 }, { venue: Nasdaq(()), qty: 40 }]) {
    Err(why) => fail(why),
    Ok(children) => assert_true(list.len(children) == 2 and child_qty_sum(children) == 100, "split conserves total quantity"),
  }
}

fn test_split_child_ids_and_venue() -> Result[Unit, Str] {
  match rt.split_order(buy_order(), [{ venue: Nyse(()), qty: 60 }, { venue: Nasdaq(()), qty: 40 }]) {
    Err(why) => fail(why),
    Ok(children) => match list.head(children) {
      None => fail("expected a first child"),
      Some(c) => assert_true(c.order.id == "ORD-100-1" and c.order.quantity == 60 and vn.venue_to_str(c.venue) == "NYSE", "first child id/qty/venue"),
    },
  }
}

fn test_split_qty_mismatch_errs() -> Result[Unit, Str] {
  match rt.split_order(buy_order(), [{ venue: Nyse(()), qty: 60 }, { venue: Nasdaq(()), qty: 30 }]) {
    Ok(_) => fail("allocations not summing to order qty should error"),
    Err(_) => pass(),
  }
}

fn test_split_nonpositive_errs() -> Result[Unit, Str] {
  match rt.split_order(buy_order(), [{ venue: Nyse(()), qty: 100 }, { venue: Nasdaq(()), qty: 0 }]) {
    Ok(_) => fail("non-positive allocation should error"),
    Err(_) => pass(),
  }
}

# ---- validate_split (atomic pre-trade) --------------------------
fn test_validate_split_all_pass() -> Result[Unit, Str] {
  match rt.validate_split(buy_order(), [{ venue: Nyse(()), qty: 50 }, { venue: Nasdaq(()), qty: 50 }], small_limit(), "ALGO01", "EXCH01") {
    Err(_) => fail("all conforming children should pass"),
    Ok(children) => assert_true(list.len(children) == 2, "two validated children"),
  }
}

fn test_validate_split_atomic_failure() -> Result[Unit, Str] {
  match rt.validate_split(buy_order(), [{ venue: Nyse(()), qty: 60 }, { venue: Nasdaq(()), qty: 40 }], small_limit(), "ALGO01", "EXCH01") {
    Ok(_) => fail("a rejected child must fail the whole split"),
    Err(reasons) => assert_true(list.len(reasons) > 0, "rejection reasons surfaced"),
  }
}

fn suite() -> List[Result[Unit, Str]] {
  [test_bestprice_buy_lowest_ask(), test_bestprice_sell_highest_bid(), test_mincost_lowest_fee(), test_sweep_first_quoted(), test_directto_bypasses_quotes(), test_bestprice_no_quotes_errs(), test_sweep_none_quoted_errs(), test_split_conserves_quantity(), test_split_child_ids_and_venue(), test_split_qty_mismatch_errs(), test_split_nonpositive_errs(), test_validate_split_all_pass(), test_validate_split_atomic_failure()]
}

fn run_all() -> Int {
  list.fold(suite(), 0, fn (n :: Int, r :: Result[Unit, Str]) -> Int {
    match r {
      Ok(_) => n,
      Err(_) => n + 1,
    }
  })
}

