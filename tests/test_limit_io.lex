# tests for src/limit_io.lex
#
# All tests use an in-memory SQLite database. The db is not explicitly closed
# since in-memory connections are ephemeral — resources are reclaimed when
# the variable goes out of scope.
#
# Effect set: [sql, fs_write].

import "std.list" as list
import "std.sql"  as sql

import "../src/limit"    as limit
import "../src/limit_io" as lio

fn pass() -> Result[Unit, Str] { Ok(()) }
fn fail(why :: Str) -> Result[Unit, Str] { Err(why) }
fn assert_true(cond :: Bool, label :: Str) -> Result[Unit, Str] {
  if cond { pass() } else { fail(label) }
}

fn open_db() -> [sql, fs_write] Result[Db, Str] {
  match sql.open(":memory:") {
    Err(e) => Err(e.message),
    Ok(db) => match lio.init(db) {
      Err(e) => Err(e),
      Ok(_)  => Ok(db),
    },
  }
}

# ---- fetch default when not stored ------------------------------

fn test_fetch_returns_default_when_missing() -> [sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(e) => fail(e),
    Ok(db) => match lio.fetch_limits(db, "ACCOUNT-UNKNOWN") {
      Err(e)  => fail(e),
      Ok(lim) => assert_true(lim.max_order_qty == 10000, "default max_order_qty"),
    },
  }
}

fn test_fetch_default_has_buy_and_sell() -> [sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(e) => fail(e),
    Ok(db) => match lio.fetch_limits(db, "ACCOUNT-UNKNOWN") {
      Err(e)  => fail(e),
      Ok(lim) => assert_true(list.len(lim.allowed_sides) == 2, "default has buy and sell"),
    },
  }
}

# ---- store and fetch roundtrip ----------------------------------

fn test_store_and_fetch_qty() -> [sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(e) => fail(e),
    Ok(db) => {
      let lim := {
        max_order_qty:    500,
        max_notional_str: "250000.00",
        allowed_symbols:  ["MSFT", "AAPL"],
        allowed_sides:    ["buy"],
      }
      match lio.store_limits(db, "ACCOUNT-A", lim) {
        Err(e) => fail(e),
        Ok(_)  => match lio.fetch_limits(db, "ACCOUNT-A") {
          Err(e)  => fail(e),
          Ok(got) => assert_true(got.max_order_qty == 500, "max_order_qty stored"),
        },
      }
    },
  }
}

fn test_store_and_fetch_notional() -> [sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(e) => fail(e),
    Ok(db) => {
      let lim := {
        max_order_qty:    500,
        max_notional_str: "250000.00",
        allowed_symbols:  [],
        allowed_sides:    ["buy", "sell"],
      }
      match lio.store_limits(db, "ACCOUNT-A2", lim) {
        Err(e) => fail(e),
        Ok(_)  => match lio.fetch_limits(db, "ACCOUNT-A2") {
          Err(e)  => fail(e),
          Ok(got) => assert_true(got.max_notional_str == "250000.00", "max_notional_str stored"),
        },
      }
    },
  }
}

fn test_allowed_symbols_roundtrip() -> [sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(e) => fail(e),
    Ok(db) => {
      let lim := {
        max_order_qty:    1000,
        max_notional_str: "1000000.00",
        allowed_symbols:  ["MSFT", "GOOG", "AAPL"],
        allowed_sides:    ["buy", "sell"],
      }
      match lio.store_limits(db, "ACCOUNT-B", lim) {
        Err(e) => fail(e),
        Ok(_)  => match lio.fetch_limits(db, "ACCOUNT-B") {
          Err(e)  => fail(e),
          Ok(got) => assert_true(list.len(got.allowed_symbols) == 3, "3 allowed symbols"),
        },
      }
    },
  }
}

fn test_empty_symbols_means_all_allowed() -> [sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(e) => fail(e),
    Ok(db) => {
      let lim := {
        max_order_qty:    1000,
        max_notional_str: "1000000.00",
        allowed_symbols:  [],
        allowed_sides:    ["buy", "sell"],
      }
      match lio.store_limits(db, "ACCOUNT-C", lim) {
        Err(e) => fail(e),
        Ok(_)  => match lio.fetch_limits(db, "ACCOUNT-C") {
          Err(e)  => fail(e),
          Ok(got) => assert_true(list.is_empty(got.allowed_symbols), "empty symbols preserved"),
        },
      }
    },
  }
}

# ---- store overwrites existing ----------------------------------

fn test_store_overwrites() -> [sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(e) => fail(e),
    Ok(db) => {
      let lim1 := {
        max_order_qty: 100, max_notional_str: "100000.00",
        allowed_symbols: [], allowed_sides: ["buy", "sell"],
      }
      let lim2 := {
        max_order_qty: 999, max_notional_str: "999999.00",
        allowed_symbols: [], allowed_sides: ["buy"],
      }
      match lio.store_limits(db, "ACCOUNT-D", lim1) {
        Err(e) => fail(e),
        Ok(_)  => match lio.store_limits(db, "ACCOUNT-D", lim2) {
          Err(e) => fail(e),
          Ok(_)  => match lio.fetch_limits(db, "ACCOUNT-D") {
            Err(e)  => fail(e),
            Ok(got) => assert_true(got.max_order_qty == 999, "second store overwrites first"),
          },
        },
      }
    },
  }
}

# ---- remove falls back to defaults ------------------------------

fn test_remove_reverts_to_defaults() -> [sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(e) => fail(e),
    Ok(db) => {
      let lim := {
        max_order_qty: 50, max_notional_str: "50000.00",
        allowed_symbols: ["MSFT"], allowed_sides: ["buy"],
      }
      match lio.store_limits(db, "ACCOUNT-E", lim) {
        Err(e) => fail(e),
        Ok(_)  => match lio.remove_limits(db, "ACCOUNT-E") {
          Err(e) => fail(e),
          Ok(_)  => match lio.fetch_limits(db, "ACCOUNT-E") {
            Err(e)  => fail(e),
            Ok(got) => assert_true(got.max_order_qty == 10000, "removed account gets default"),
          },
        },
      }
    },
  }
}

# ---- isolation: two accounts are independent --------------------

fn test_two_accounts_independent() -> [sql, fs_write] Result[Unit, Str] {
  match open_db() {
    Err(e) => fail(e),
    Ok(db) => {
      let limA := {
        max_order_qty: 100, max_notional_str: "100000.00",
        allowed_symbols: [], allowed_sides: ["buy", "sell"],
      }
      let limB := {
        max_order_qty: 999, max_notional_str: "999999.00",
        allowed_symbols: [], allowed_sides: ["buy", "sell"],
      }
      match lio.store_limits(db, "ACCT-X", limA) {
        Err(e) => fail(e),
        Ok(_)  => match lio.store_limits(db, "ACCT-Y", limB) {
          Err(e) => fail(e),
          Ok(_)  => match lio.fetch_limits(db, "ACCT-X") {
            Err(e)  => fail(e),
            Ok(got) => assert_true(got.max_order_qty == 100, "ACCT-X not affected by ACCT-Y"),
          },
        },
      }
    },
  }
}

# ---- suite -------------------------------------------------------

fn suite() -> [sql, fs_write] List[Result[Unit, Str]] {
  [
    test_fetch_returns_default_when_missing(),
    test_fetch_default_has_buy_and_sell(),
    test_store_and_fetch_qty(),
    test_store_and_fetch_notional(),
    test_allowed_symbols_roundtrip(),
    test_empty_symbols_means_all_allowed(),
    test_store_overwrites(),
    test_remove_reverts_to_defaults(),
    test_two_accounts_independent(),
  ]
}

fn run_all() -> [sql, fs_write] Int {
  list.fold(suite(), 0,
    fn (n :: Int, r :: Result[Unit, Str]) -> Int {
      match r { Ok(_) => n, Err(_) => n + 1 }
    })
}
