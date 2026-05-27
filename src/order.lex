# lex-trade — Order domain ADT
#
# A typed domain-level order, independent of FIX wire encoding.
# Constructors and accessors for the core order record, plus
# conversion helpers to build a NewOrderSingle for the FIX layer.
#
# Effects: none.

import "std.str"  as str
import "std.list" as list

import "lex-fix/src/v44/enums"            as en
import "lex-fix/src/v44/new_order_single" as nos

# ---- Side -------------------------------------------------------

type OrderSide = OrderBuy | OrderSell

# ---- Order kind (with embedded price strings) -------------------

type OrderKind =
    MarketOrder
  | LimitOrder(Str)
  | StopOrder(Str)
  | StopLimitOrder(Str, Str)

# ---- Core domain record -----------------------------------------

type Order = {
  id           :: Str,
  symbol       :: Str,
  side         :: OrderSide,
  quantity     :: Int,
  kind         :: OrderKind,
  time_in_force :: Str,
  account      :: Str,
  trader_id    :: Str,
  timestamp    :: Str,
}

# ---- Constructor ------------------------------------------------

fn order(
  id            :: Str,
  symbol        :: Str,
  side          :: OrderSide,
  quantity      :: Int,
  kind          :: OrderKind,
  time_in_force :: Str,
  account       :: Str,
  trader_id     :: Str,
  timestamp     :: Str
) -> Order {
  {
    id:            id,
    symbol:        symbol,
    side:          side,
    quantity:      quantity,
    kind:          kind,
    time_in_force: time_in_force,
    account:       account,
    trader_id:     trader_id,
    timestamp:     timestamp,
  }
}

# ---- Conversion helpers -----------------------------------------

fn order_to_fix_side(s :: OrderSide) -> en.Side {
  match s {
    OrderBuy  => Buy,
    OrderSell => Sell,
  }
}

fn order_to_ord_type(k :: OrderKind) -> en.OrdType {
  match k {
    MarketOrder        => Market,
    LimitOrder(_)      => Limit,
    StopOrder(_)       => Stop,
    StopLimitOrder(_, _) => StopLimit,
  }
}

fn order_price(k :: OrderKind) -> Option[Str] {
  match k {
    MarketOrder          => None,
    LimitOrder(p)        => Some(p),
    StopOrder(_)         => None,
    StopLimitOrder(p, _) => Some(p),
  }
}

fn tif_from_str(s :: Str) -> en.TimeInForce {
  if s == "1" { Gtc }
  else { if s == "3" { Ioc }
  else { if s == "4" { Fok }
  else { if s == "6" { AtClose }
  else { Day } } } }
}

fn order_to_nos(o :: Order, sender :: Str, target :: Str) -> nos.NewOrderSingle {
  {
    cl_ord_id:      o.id,
    symbol:         o.symbol,
    side:           order_to_fix_side(o.side),
    order_qty:      o.quantity,
    ord_type:       order_to_ord_type(o.kind),
    price:          order_price(o.kind),
    time_in_force:  tif_from_str(o.time_in_force),
    transact_time:  o.timestamp,
    sender_comp_id: sender,
    target_comp_id: target,
    account:        Some(o.account),
  }
}
