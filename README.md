# lex-trade

Pre-trade order validation for the [Lex language](https://github.com/alpibrusl/lex-lang).

lex-trade is the domain layer that sits between an agent's order intent and the FIX wire. An agent produces a typed `Order`; lex-trade validates it against configurable risk limits and FIX-protocol conformance rules; the result is either `Accepted(NewOrderSingle)` — ready to hand to the exchange adapter — or `Rejected(violations)` — with every failure reason named and described, never a raw error string.

## Architecture

```
Agent emits Order
      │
      ▼
validation.validate
  ├── RiskLimit predicates (qty, symbol, side)
  ├── order_to_nos  →  NewOrderSingle
  └── lex-fix/conformance.validate_new_order
      │
      ├── Accepted(NewOrderSingle)  →  FIX transport layer
      └── Rejected(List[RejectionReason])  →  upstream agent
```

The core (`validation.lex`) is **pure**: no effects, no I/O. The effectful shell (`validation_io.lex`) wraps the same pipeline and is wired for lex-trail integration as soon as that dependency is available.

## What it ships

- **`src/order.lex`** — `Order` domain ADT; `OrderSide`, `OrderKind`; constructors and conversion helpers to `NewOrderSingle`.
- **`src/limit.lex`** — `RiskLimit` record; `default_limits`, `within_qty`, `symbol_allowed`, `side_allowed`.
- **`src/rejection.lex`** — `RejectionReason` ADT (`ExceedsMaxQty`, `SymbolNotAllowed`, `SideNotAllowed`, `FixConformanceFailure`, `InternalError`) with human-readable `describe`.
- **`src/validation.lex`** — pure validation pipeline; `ValidationResult = Accepted | Rejected`; `is_accepted`, `is_rejected`, `accepted_order`.
- **`src/validation_io.lex`** — effectful `[io]` wrapper, stub for lex-trail logging.
- **`src/routing.lex`** — smart order routing. `RoutingStrategy` (`BestPrice`/`MinCost`/`Sweep`/`DirectTo`); `select_venue` picks a destination from venue-tagged `Quote`s; `split_order` divides a parent into per-venue child orders (quantity-conserving); `validate_split` runs every child through the full pre-trade gate atomically — any rejected child fails the whole split. Venue identity is `lex-fix/src/venue`.
- **`examples/pre_trade_check.lex`** — end-to-end worked example: agent order → validation → result string.

## Usage

```lex
import "lex-trade/src/order"      as order
import "lex-trade/src/limit"      as limit
import "lex-trade/src/validation" as v

let o := order.order(
  "ORD-2026-001", "MSFT", OrderBuy, 100,
  LimitOrder("125.50"), "0", "ACCOUNT-A", "TRADER-01",
  "20260527-09:30:00.000"
)

let result := v.validate(o, limit.default_limits(), "ALGO01", "EXCH01")

match result {
  Accepted(nos) => # submit nos to exchange adapter
  Rejected(reasons) => # log reasons, surface to agent
}
```

## Risk limits

`RiskLimit` controls three gates:

| Field | Description |
|---|---|
| `max_order_qty` | Maximum shares/contracts per order (default: 10 000) |
| `max_notional_str` | Notional ceiling as a formatted string, for audit display (default: "5000000.00") |
| `allowed_symbols` | Whitelist of tickers; empty list means all symbols permitted |
| `allowed_sides` | `["buy", "sell"]` by default; restrict to `["buy"]` for long-only mandates |

## Dependencies

- **lex-fix** — FIX 4.4 protocol layer: typed `NewOrderSingle`, `conformance.validate_new_order`, enum ADTs.
- **lex-money** — monetary types available for future notional-limit enforcement; not yet wired into the validation pipeline.
- **lex-trail** (planned) — typed event logging; `validation_io.lex` is the integration point.

---

Built under the principles of [Trust Without Comprehension](https://alpibru.com/manifesto).
