# lex-trade — trade reconstruction store
#
# Writes a self-contained record alongside every lex-trail event produced
# by validate_log_and_record (in validation_io.lex). reconstruct/2 reads
# the record back and rebuilds the inputs that produced the validation
# decision; replay/1 re-runs validate with those inputs to prove
# determinism.
#
# Schema lives in the same SQLite db as the lex-trail events:
#   reconstruct      — one row per validated order (scalar fields)
#   reconstruct_list — one row per list-valued field item (allowed_symbols,
#                      allowed_sides, violations)
#
# Effects: write_reconstruct / reconstruct -> [sql]; everything else pure.

import "std.list" as list

import "std.str" as str

import "std.int" as int

import "std.sql" as sql

import "lex-money/src/decimal" as d

import "./order" as order

import "./limit" as limit

import "./validation" as v

import "./rejection" as rejection

type TradeReconstruction = { entry_id :: Str, order_inputs :: order.Order, limits_snapshot :: limit.RiskLimit, ref_price :: Option[d.Decimal], sender :: Str, target :: Str, result_tag :: Str, violations :: List[Str], algo_sig_id :: Str, recorded_at_ms :: Int }

# ---- Schema ---------------------------------------------------------
fn init_reconstruct(db :: Db) -> [sql] Result[Unit, Str] {
  exec_rc_stmts(db, ["CREATE TABLE IF NOT EXISTS reconstruct (entry_id TEXT NOT NULL PRIMARY KEY, order_id TEXT NOT NULL, symbol TEXT NOT NULL, side TEXT NOT NULL, quantity INTEGER NOT NULL, order_type TEXT NOT NULL, price TEXT NOT NULL DEFAULT '', stop_price TEXT NOT NULL DEFAULT '', time_in_force TEXT NOT NULL, account TEXT NOT NULL, trader_id TEXT NOT NULL, order_ts TEXT NOT NULL, sender TEXT NOT NULL, target TEXT NOT NULL, max_order_qty INTEGER NOT NULL, ref_price_set INTEGER NOT NULL DEFAULT 0, ref_price_coeff INTEGER NOT NULL DEFAULT 0, ref_price_exp INTEGER NOT NULL DEFAULT 0, result_tag TEXT NOT NULL, algo_sig_id TEXT NOT NULL, recorded_at_ms INTEGER NOT NULL)", "CREATE TABLE IF NOT EXISTS reconstruct_list (entry_id TEXT NOT NULL, list_name TEXT NOT NULL, item TEXT NOT NULL)", "CREATE INDEX IF NOT EXISTS idx_rcl ON reconstruct_list(entry_id, list_name)"])
}

fn exec_rc_stmts(db :: Db, stmts :: List[Str]) -> [sql] Result[Unit, Str] {
  match list.head(stmts) {
    None => Ok(()),
    Some(stmt) => match sql.exec(db, stmt, []) {
      Err(e) => Err(e.message),
      Ok(_) => exec_rc_stmts(db, list.tail(stmts)),
    },
  }
}

# ---- OrderKind helpers ----------------------------------------------
fn order_type_str(k :: order.OrderKind) -> Str
  examples {
    order_type_str(MarketOrder(())) => "Market",
    order_type_str(LimitOrder("100.00")) => "Limit",
    order_type_str(StopOrder("99.00")) => "Stop",
    order_type_str(StopLimitOrder("100.00", "95.00")) => "StopLimit"
  }
{
  match k {
    MarketOrder(_) => "Market",
    LimitOrder(_) => "Limit",
    StopOrder(_) => "Stop",
    StopLimitOrder(_, _) => "StopLimit",
  }
}

fn order_price_str(k :: order.OrderKind) -> Str
  examples {
    order_price_str(MarketOrder(())) => "",
    order_price_str(LimitOrder("100.00")) => "100.00"
  }
{
  match k {
    MarketOrder(_) => "",
    LimitOrder(p) => p,
    StopOrder(p) => p,
    StopLimitOrder(p, _) => p,
  }
}

fn order_stop_price_str(k :: order.OrderKind) -> Str
  examples {
    order_stop_price_str(MarketOrder(())) => "",
    order_stop_price_str(StopLimitOrder("100.00", "95.00")) => "95.00"
  }
{
  match k {
    StopLimitOrder(_, sp) => sp,
    _ => "",
  }
}

fn order_kind_from_parts(order_type :: Str, price_str :: Str, stop_str :: Str) -> order.OrderKind
  examples {
    order_kind_from_parts("Market", "", "") => MarketOrder(()),
    order_kind_from_parts("Limit", "100.00", "") => LimitOrder("100.00"),
    order_kind_from_parts("Stop", "99.00", "") => StopOrder("99.00"),
    order_kind_from_parts("StopLimit", "100.00", "95.00") => StopLimitOrder("100.00", "95.00")
  }
{
  if order_type == "Stop" {
    if str.is_empty(price_str) {
      MarketOrder(())
    } else {
      StopOrder(price_str)
    }
  } else {
    if order_type == "StopLimit" {
      if str.is_empty(price_str) {
        MarketOrder(())
      } else {
        if str.is_empty(stop_str) {
          MarketOrder(())
        } else {
          StopLimitOrder(price_str, stop_str)
        }
      }
    } else {
      if order_type == "Limit" {
        if str.is_empty(price_str) {
          MarketOrder(())
        } else {
          LimitOrder(price_str)
        }
      } else {
        MarketOrder(())
      }
    }
  }
}

fn side_str_rc(s :: order.OrderSide) -> Str
  examples {
    side_str_rc(OrderBuy(())) => "buy",
    side_str_rc(OrderSell(())) => "sell"
  }
{
  match s {
    OrderBuy(_) => "buy",
    OrderSell(_) => "sell",
  }
}

fn side_from_str(s :: Str) -> order.OrderSide
  examples {
    side_from_str("buy") => OrderBuy(()),
    side_from_str("sell") => OrderSell(())
  }
{
  if s == "buy" {
    OrderBuy(())
  } else {
    OrderSell(())
  }
}

# ---- ValidationResult helpers ---------------------------------------
fn result_tag(result :: v.ValidationResult) -> Str
  examples {
    result_tag(Rejected([InternalError("x")])) => "Rejected"
  }
{
  match result {
    Accepted(_) => "Accepted",
    Rejected(_) => "Rejected",
  }
}

fn violations_of(result :: v.ValidationResult) -> List[Str] {
  match result {
    Accepted(_) => [],
    Rejected(vs) => list.map(vs, rejection.describe),
  }
}

# ---- Row helpers ----------------------------------------------------
fn get_str[R](row :: R, col :: Str) -> Str {
  match sql.get_str(row, col) {
    Some(s) => s,
    None => "",
  }
}

fn get_int[R](row :: R, col :: Str) -> Int {
  match sql.get_int(row, col) {
    Some(n) => n,
    None => 0,
  }
}

fn decode_list_item[R](row :: R) -> Str {
  match sql.get_str(row, "item") {
    Some(s) => s,
    None => "",
  }
}

# ---- List item store -----------------------------------------------
fn insert_list_items(db :: Db, entry_id :: Str, list_name :: Str, items :: List[Str]) -> [sql] Unit {
  let __r := list.fold(items, (), fn (acc :: Unit, item :: Str) -> [sql] Unit {
    let __ins := sql.exec(db, "INSERT INTO reconstruct_list(entry_id, list_name, item) VALUES (?, ?, ?)", [PStr(entry_id), PStr(list_name), PStr(item)])
    ()
  })
  ()
}

fn fetch_list_items(db :: Db, entry_id :: Str, list_name :: Str) -> [sql] List[Str] {
  match sql.query(db, "SELECT item FROM reconstruct_list WHERE entry_id = ? AND list_name = ? ORDER BY rowid ASC", [PStr(entry_id), PStr(list_name)]) {
    Err(_) => [],
    Ok(rows) => list.map(rows, decode_list_item),
  }
}

# ---- Write ----------------------------------------------------------
# Store the full decision record. Calls init_reconstruct internally so
# the caller does not need to set up the schema separately.
fn write_reconstruct(db :: Db, entry_id :: Str, o :: order.Order, lim :: limit.RiskLimit, ref_price :: Option[d.Decimal], sender :: Str, target :: Str, result :: v.ValidationResult, algo_sig_id :: Str, recorded_at_ms :: Int) -> [sql] Unit {
  let __init := init_reconstruct(db)
  let price_str := order_price_str(o.kind)
  let stop_str := order_stop_price_str(o.kind)
  let ref_set := match ref_price {
    None => 0,
    Some(_) => 1,
  }
  let ref_coeff := match ref_price {
    None => 0,
    Some(rp) => rp.coefficient,
  }
  let ref_exp := match ref_price {
    None => 0,
    Some(rp) => rp.exponent,
  }
  let __ins := sql.exec(db, "INSERT OR IGNORE INTO reconstruct(entry_id,order_id,symbol,side,quantity,order_type,price,stop_price,time_in_force,account,trader_id,order_ts,sender,target,max_order_qty,ref_price_set,ref_price_coeff,ref_price_exp,result_tag,algo_sig_id,recorded_at_ms) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)", [PStr(entry_id), PStr(o.id), PStr(o.symbol), PStr(side_str_rc(o.side)), PInt(o.quantity), PStr(order_type_str(o.kind)), PStr(price_str), PStr(stop_str), PStr(o.time_in_force), PStr(o.account), PStr(o.trader_id), PStr(o.timestamp), PStr(sender), PStr(target), PInt(lim.max_order_qty), PInt(ref_set), PInt(ref_coeff), PInt(ref_exp), PStr(result_tag(result)), PStr(algo_sig_id), PInt(recorded_at_ms)])
  let __sym := insert_list_items(db, entry_id, "allowed_symbols", lim.allowed_symbols)
  let __sid := insert_list_items(db, entry_id, "allowed_sides", lim.allowed_sides)
  let __vio := insert_list_items(db, entry_id, "violations", violations_of(result))
  ()
}

# ---- Read -----------------------------------------------------------
# Reconstruct the full decision record from the store. Returns Err if no
# record exists for the given entry_id.
fn reconstruct(db :: Db, entry_id :: Str) -> [sql] Result[TradeReconstruction, Str] {
  let allowed_symbols := fetch_list_items(db, entry_id, "allowed_symbols")
  let allowed_sides := fetch_list_items(db, entry_id, "allowed_sides")
  let violations := fetch_list_items(db, entry_id, "violations")
  match sql.query(db, "SELECT order_id,symbol,side,quantity,order_type,price,stop_price,time_in_force,account,trader_id,order_ts,sender,target,max_order_qty,ref_price_set,ref_price_coeff,ref_price_exp,result_tag,algo_sig_id,recorded_at_ms FROM reconstruct WHERE entry_id=?", [PStr(entry_id)]) {
    Err(e) => Err(e.message),
    Ok(rows) => match list.head(rows) {
      None => Err(str.concat("reconstruct: no record for entry_id=", entry_id)),
      Some(row) => {
        let order_id := get_str(row, "order_id")
        let symbol := get_str(row, "symbol")
        let side := side_from_str(get_str(row, "side"))
        let quantity := get_int(row, "quantity")
        let order_type := get_str(row, "order_type")
        let price_str := get_str(row, "price")
        let stop_str := get_str(row, "stop_price")
        let tif := get_str(row, "time_in_force")
        let account := get_str(row, "account")
        let trader_id := get_str(row, "trader_id")
        let order_ts := get_str(row, "order_ts")
        let sender := get_str(row, "sender")
        let target := get_str(row, "target")
        let max_qty := get_int(row, "max_order_qty")
        let ref_set := get_int(row, "ref_price_set")
        let ref_coeff := get_int(row, "ref_price_coeff")
        let ref_exp := get_int(row, "ref_price_exp")
        let rtag := get_str(row, "result_tag")
        let algo_sig := get_str(row, "algo_sig_id")
        let ts_ms := get_int(row, "recorded_at_ms")
        let kind := order_kind_from_parts(order_type, price_str, stop_str)
        let o := order.order(order_id, symbol, side, quantity, kind, tif, account, trader_id, order_ts)
        let lim := { max_order_qty: max_qty, max_notional_str: "0.00", allowed_symbols: allowed_symbols, allowed_sides: allowed_sides }
        let rp := if ref_set == 0 {
          None
        } else {
          Some({ coefficient: ref_coeff, exponent: ref_exp })
        }
        Ok({ entry_id: entry_id, order_inputs: o, limits_snapshot: lim, ref_price: rp, sender: sender, target: target, result_tag: rtag, violations: violations, algo_sig_id: algo_sig, recorded_at_ms: ts_ms })
      },
    },
  }
}

# ---- Replay ---------------------------------------------------------
# Re-run validate with stored inputs. Pure: same inputs → same result,
# every time. If results_match returns false, a non-determinism bug exists
# in the validation pipeline.
fn replay(rec :: TradeReconstruction) -> v.ValidationResult {
  v.validate(rec.order_inputs, rec.limits_snapshot, rec.sender, rec.target)
}

# Compare the stored result tag to the replayed result's tag. A mismatch
# means the validation pipeline is non-deterministic.
fn results_match(rec :: TradeReconstruction, replay_result :: v.ValidationResult) -> Bool
  examples {
    results_match({ entry_id: "e", order_inputs: order.order("id", "SYM", OrderBuy(()), 1, MarketOrder(()), "0", "A", "T", "ts"), limits_snapshot: { max_order_qty: 100, max_notional_str: "0.00", allowed_symbols: [], allowed_sides: ["buy"] }, ref_price: None, sender: "S", target: "T", result_tag: "Rejected", violations: ["too big"], algo_sig_id: "sig", recorded_at_ms: 0 }, Rejected([InternalError("x")])) => true
  }
{
  rec.result_tag == result_tag(replay_result)
}

