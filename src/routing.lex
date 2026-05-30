# lex-trade — smart order routing (venue selection + order splitting)
#
# A pure routing layer over the pre-trade gate. `select_venue` chooses a
# destination for an order under a routing strategy and a set of venue
# quotes; `split_order` divides a parent order into per-venue child
# orders; `validate_split` runs every child through the full pre-trade
# validation gate atomically — if any child is rejected, the whole split
# is rejected.
#
# Venue identity comes from lex-fix (lex-fix/src/venue). Quotes are
# venue-tagged (a List[Quote], not a Map[Venue, Quote]) because Venue is
# an ADT and the package models collections as records/lists rather than
# ADT-keyed maps. Quote prices and fees are integer minor units (cents /
# ticks / fee units) to keep comparison exact and pure; lex-marketdata
# (planned) will supply live quotes.
#
# Effects: none.

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "lex-fix/src/venue" as venue

import "./order" as order

import "./limit" as limit

import "./validation" as validation

import "./rejection" as rejection

# ---- Types ------------------------------------------------------
type Quote = { venue :: venue.Venue, bid :: Int, ask :: Int, fee :: Int }

type RoutingStrategy = BestPrice(Unit) | MinCost(Unit) | Sweep(List[venue.Venue]) | DirectTo(venue.Venue)

type Allocation = { venue :: venue.Venue, qty :: Int }

# A child order produced by splitting, tagged with its destination.
type ChildOrder = { venue :: venue.Venue, order :: order.Order }

# Internal accumulator for building child orders with unique ids.
type SplitAcc = { seq :: Int, children :: List[ChildOrder] }

# ---- Venue comparison -------------------------------------------
# Venue is an ADT; compare by its canonical wire name (NYSE, XNYS → …).
fn same_venue(a :: venue.Venue, b :: venue.Venue) -> Bool {
  venue.venue_to_str(a) == venue.venue_to_str(b)
}

fn has_quote(v :: venue.Venue, quotes :: List[Quote]) -> Bool {
  list.fold(quotes, false, fn (acc :: Bool, q :: Quote) -> Bool {
    if acc {
      true
    } else {
      same_venue(q.venue, v)
    }
  })
}

# ---- Best-quote selection ---------------------------------------
# Lowest ask (a buyer pays the ask).
fn best_ask(quotes :: List[Quote]) -> Option[Quote] {
  list.fold(quotes, None, fn (acc :: Option[Quote], q :: Quote) -> Option[Quote] {
    match acc {
      None => Some(q),
      Some(b) => if q.ask < b.ask {
        Some(q)
      } else {
        acc
      },
    }
  })
}

# Highest bid (a seller receives the bid).
fn best_bid(quotes :: List[Quote]) -> Option[Quote] {
  list.fold(quotes, None, fn (acc :: Option[Quote], q :: Quote) -> Option[Quote] {
    match acc {
      None => Some(q),
      Some(b) => if q.bid > b.bid {
        Some(q)
      } else {
        acc
      },
    }
  })
}

# Lowest fee.
fn cheapest(quotes :: List[Quote]) -> Option[Quote] {
  list.fold(quotes, None, fn (acc :: Option[Quote], q :: Quote) -> Option[Quote] {
    match acc {
      None => Some(q),
      Some(b) => if q.fee < b.fee {
        Some(q)
      } else {
        acc
      },
    }
  })
}

# First venue in the sweep list that currently has a quote.
fn first_quoted(venues :: List[venue.Venue], quotes :: List[Quote]) -> Option[venue.Venue] {
  list.fold(venues, None, fn (acc :: Option[venue.Venue], v :: venue.Venue) -> Option[venue.Venue] {
    match acc {
      Some(_) => acc,
      None => if has_quote(v, quotes) {
        Some(v)
      } else {
        None
      },
    }
  })
}

fn venue_of(q :: Option[Quote]) -> Option[venue.Venue] {
  match q {
    None => None,
    Some(quote) => Some(quote.venue),
  }
}

# ---- Public: venue selection ------------------------------------
# Choose a destination venue for `o` under `strategy`, given `quotes`.
# - BestPrice : best ask for a buy, best bid for a sell.
# - MinCost   : lowest-fee venue.
# - Sweep(vs) : first venue in vs that has a quote (the first to sweep).
# - DirectTo(v): v, bypassing routing (no quote required).
fn select_venue(o :: order.Order, strategy :: RoutingStrategy, quotes :: List[Quote]) -> Result[venue.Venue, Str] {
  match strategy {
    DirectTo(v) => Ok(v),
    BestPrice(_) => {
      let chosen := match o.side {
        OrderBuy(_) => venue_of(best_ask(quotes)),
        OrderSell(_) => venue_of(best_bid(quotes)),
      }
      match chosen {
        Some(v) => Ok(v),
        None => Err("BestPrice routing: no quotes available"),
      }
    },
    MinCost(_) => match venue_of(cheapest(quotes)) {
      Some(v) => Ok(v),
      None => Err("MinCost routing: no quotes available"),
    },
    Sweep(venues) => match first_quoted(venues, quotes) {
      Some(v) => Ok(v),
      None => Err("Sweep routing: no quoted venue in the sweep list"),
    },
  }
}

# ---- Public: order splitting ------------------------------------
# Divide `o` into per-venue child orders. The allocation quantities must
# all be positive and must sum to exactly the parent quantity. Each child
# gets a unique ClOrdID derived from the parent id (`<id>-1`, `<id>-2`…).
fn split_order(o :: order.Order, allocations :: List[Allocation]) -> Result[List[ChildOrder], Str] {
  let total := list.fold(allocations, 0, fn (acc :: Int, a :: Allocation) -> Int {
    acc + a.qty
  })
  let any_nonpositive := list.fold(allocations, false, fn (acc :: Bool, a :: Allocation) -> Bool {
    if acc {
      true
    } else {
      a.qty <= 0
    }
  })
  if list.is_empty(allocations) {
    Err("split_order: no allocations")
  } else {
    if any_nonpositive {
      Err("split_order: all allocations must be positive")
    } else {
      if total != o.quantity {
        Err(str.concat("split_order: allocations sum to ", str.concat(int.to_str(total), str.concat(" but order quantity is ", int.to_str(o.quantity)))))
      } else {
        let built := list.fold(allocations, { seq: 1, children: [] }, fn (acc :: SplitAcc, a :: Allocation) -> SplitAcc {
          let child_id := str.concat(o.id, str.concat("-", int.to_str(acc.seq)))
          let child := order.order(child_id, o.symbol, o.side, a.qty, o.kind, o.time_in_force, o.account, o.trader_id, o.timestamp)
          { seq: acc.seq + 1, children: list.concat(acc.children, [{ venue: a.venue, order: child }]) }
        })
        Ok(built.children)
      }
    }
  }
}

# ---- Public: atomic split + validation --------------------------
# Split `o` and run every child through the full pre-trade gate
# (validation.validate). The split is atomic: if the split is malformed
# or *any* child order is rejected, the whole operation fails and no
# child is routed. On success, returns the validated child orders.
fn validate_split(o :: order.Order, allocations :: List[Allocation], lim :: limit.RiskLimit, sender :: Str, target :: Str) -> Result[List[ChildOrder], List[rejection.RejectionReason]] {
  match split_order(o, allocations) {
    Err(msg) => Err([InternalError(msg)]),
    Ok(children) => {
      let rejections := list.fold(children, [], fn (acc :: List[rejection.RejectionReason], c :: ChildOrder) -> List[rejection.RejectionReason] {
        match validation.validate(c.order, lim, sender, target) {
          Accepted(_) => acc,
          Rejected(rs) => list.concat(acc, rs),
        }
      })
      if list.is_empty(rejections) {
        Ok(children)
      } else {
        Err(rejections)
      }
    },
  }
}

