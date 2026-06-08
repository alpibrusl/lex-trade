# lex-trade

Pre-trade order validation for Lex. The gate between an agent's intent and the exchange.

An agent produces a typed `Order`. lex-trade validates it against risk limits, FIX-protocol conformance, position limits, margin, and price tolerance. The result is either `Accepted(NewOrderSingle)` — ready for the exchange adapter — or `Rejected(violations)` — with every failure reason named and typed.

The core validation pipeline is **pure** (no effects). The effectful wrapper logs each decision to `lex-trail` and persists a reconstruction record so validations can be replayed deterministically.

---

## The gate

```
Agent Order
    │
    ▼
validation.validate
  ├── RiskLimit gates (max_order_qty, allowed_symbols, allowed_sides)
  ├── lex-risk/margin.pre_trade_check
  ├── lex-positions/exposure.within_notional
  ├── price_check (tolerance vs. reference price)
  └── lex-fix/conformance.validate_new_order
      │
      ├── Accepted(NewOrderSingle)  →  exchange transport
      └── Rejected(List[RejectionReason])  →  agent
```

---

## Modules

- **`order.lex`** — `Order` domain type, `OrderSide` (`OrderBuy`/`OrderSell`), `OrderKind` (`MarketOrder`/`LimitOrder`/`StopOrder`/`StopLimitOrder`).
- **`limit.lex`** — `RiskLimit` (`max_order_qty`, `allowed_symbols`, `allowed_sides`); `default_limits`.
- **`rejection.lex`** — `RejectionReason` ADT with human-readable `describe`: `ExceedsMaxQty`, `SymbolNotAllowed`, `SideNotAllowed`, `FixConformanceFailure`, `PositionViolation`, `PriceToleranceBreached`, `MarginLimitBreached`.
- **`validation.lex`** — pure pipeline; `validate(order, limits, sender, target) -> ValidationResult`.
- **`validation_io.lex`** — `[sql, time]` wrapper; appends `trade.order.validated` and `trade.order.accepted|rejected` events to `lex-trail`.
- **`lifecycle.lex`** — `OrderState` ADT (`PendingNew`/`New`/`PartiallyFilled`/`Filled`/`PendingCancel`/`Canceled`/`ExchangeRejected`) and state-machine transitions driven by `ExecutionReport` events.
- **`cancel.lex`** / **`replace.lex`** — cancel and cancel/replace validation; enforces FIX immutability rules (Side and Symbol may not change on a replace).
- **`position_check.lex`** — pre-trade position/notional limit check against the live position book.
- **`price_check.lex`** — price-tolerance gate (order price vs. reference price).
- **`reconstruct.lex`** — persists full decision inputs so validation can be replayed.
- **`routing.lex`** — `RoutingStrategy` and multi-venue child-order splitting (internal; `lex-sor` exposes this publicly).

---

## Usage

```lex
import "lex-trade/src/order"      as order
import "lex-trade/src/limit"      as limit
import "lex-trade/src/validation" as v

let o := order.order("ORD-001", "MSFT", OrderBuy(()), 100,
           LimitOrder("125.50"), "0", "ACC-A", "TRADER-01", "20260601-09:30:00.000")

match v.validate(o, limit.default_limits(), "ALGO01", "EXCH01") {
  Accepted(nos) => # hand nos to exchange adapter
  Rejected(reasons) => # list.map(reasons, rejection.describe) for display
}
```

---

## In the stack

```
lex-money · lex-fix · lex-positions
    ↓
lex-trade  ←  pre-trade gate
    ↓
lex-sor · lex-finance · lex-oms
```

---

## Install

```toml
[dependencies]
"lex-trade" = { git = "https://github.com/alpibrusl/lex-trade" }
```
