# DTG — One-Minute Candle Scalper EA (MT5)

A simple, focused MetaTrader 5 Expert Advisor that scalps the 1-minute timeframe.
The idea is exactly what you described:

- When the previous M1 candle **closes bullish**, place a **buy stop** at that
  candle's high. If price breaks the high within the next minute, you're long.
- When the previous M1 candle **closes bearish**, place a **sell stop** at that
  candle's low. If price breaks the low within the next minute, you're short.
- Initial stop loss is parked beyond the **opposite extreme** of the signal
  candle (the low for buys, the high for sells), with a small buffer.
- Once the trade moves a few pips into profit it ratchets the stop to
  **break-even**, and once it's clearly running it switches to a **trailing
  stop** a few pips behind price.
- Pending orders that don't fill within the new minute are cancelled — we only
  ever chase the latest signal.

The EA file lives at:

```
MT5/Experts/OneMinuteScalper.mq5
```

---

## Install / Run

1. Open MetaTrader 5 → `File → Open Data Folder`.
2. Copy `MT5/Experts/OneMinuteScalper.mq5` into `MQL5/Experts/`.
3. In MT5, open `Navigator → Expert Advisors`, right-click → **Refresh**.
4. Open a chart for the symbol you want to trade and switch the chart to
   **M1** (the strategy reads the M1 candles directly via `iOpen/iHigh/iLow/
   iClose`, so the chart timeframe is mostly cosmetic, but M1 is the natural
   one for monitoring).
5. Drag `OneMinuteScalper` onto the chart.
6. On the **Common** tab tick *Allow Algo Trading* / *Allow live trading*.
7. On the **Inputs** tab tune the parameters (see below).
8. Make sure the global `Algo Trading` button at the top of the platform is
   green.

> **Test in Strategy Tester first.** Use *Every tick based on real ticks* on a
> recent date range to get a realistic feel for spread and slippage on the M1
> timeframe before going live. Demo it on a live demo account for at least a
> few sessions before risking real money.

---

## Inputs (with sensible starting values)

### Strategy

| Input | Default | What it does |
|---|---|---|
| `InpTradeBullish` | `true` | Take long setups (bullish signal candles). |
| `InpTradeBearish` | `true` | Take short setups (bearish signal candles). |
| `InpEntryBufferPips` | `0.5` | How many pips above the high (or below the low) to place the stop entry. A small buffer reduces "wick-only" fills. Set to `0` to enter exactly at the high/low. |
| `InpUsePendingExpiry` | `true` | Cancel the pending if it doesn't fill quickly. |
| `InpPendingExpirySec` | `60` | How long the pending order is valid for (one minute by default = current candle only). |
| `InpMinCandleSizePips` | `0.8` | Skip dojis / micro-candles. |
| `InpMaxCandleSizePips` | `25` | Skip absurdly large candles where the stop would be huge (set `0` to disable). |
| `InpMaxSpreadPips` | `2.0` | Skip the trade if spread is wider than this (set `0` to disable). |

### Stop loss / take profit

| Input | Default | What it does |
|---|---|---|
| `InpSLMode` | `SL_CANDLE_EXTREME` | `SL_CANDLE_EXTREME` parks SL just beyond the signal candle's other extreme. `SL_FIXED_PIPS` uses a fixed pip distance instead. |
| `InpSLBufferPips` | `1.0` | Buffer pips beyond the candle low/high when using `SL_CANDLE_EXTREME`. |
| `InpSLFixedPips` | `8.0` | Fixed pip stop, only used in `SL_FIXED_PIPS` mode. |
| `InpMinSLPips` | `2.0` | Reject trades whose SL distance is implausibly tight. |
| `InpMaxSLPips` | `30.0` | Reject trades whose SL distance is huge (set `0` to disable). |
| `InpTakeProfitPips` | `0.0` | Optional fixed TP. `0` means no TP at all — let the trailing stop close the trade. |

### Break-even & trailing

| Input | Default | What it does |
|---|---|---|
| `InpBreakevenTriggerPips` | `3.0` | Move SL to break-even (+ buffer) when this much profit is reached. |
| `InpBreakevenBufferPips` | `0.5` | Pips locked in at BE (so you cover spread / commission). |
| `InpTrailStartPips` | `5.0` | Start the trailing stop after this much profit. |
| `InpTrailDistancePips` | `3.0` | Distance the trailing stop sits behind price. |

### Money management

| Input | Default | What it does |
|---|---|---|
| `InpLotMode` | `LOT_RISK_PERCENT` | `LOT_FIXED` uses `InpFixedLot`. `LOT_RISK_PERCENT` sizes lots so that the SL = `InpRiskPercent` of equity. |
| `InpFixedLot` | `0.01` | Lot size in fixed mode. |
| `InpRiskPercent` | `0.5` | Risk per trade in % of equity. |
| `InpMaxOpenPositions` | `1` | Max positions opened by this EA on this symbol concurrently. |

### Daily limits

| Input | Default | What it does |
|---|---|---|
| `InpDailyProfitTarget` | `1.0` | Stops opening new trades after +X% on the day. (Existing trades keep their trailing stop.) Set `0` to disable. |
| `InpDailyLossLimit` | `2.0` | Stops opening new trades after -X% on the day. Set `0` to disable. |

### Session filter

| Input | Default | What it does |
|---|---|---|
| `InpUseSessionFilter` | `false` | Restrict trading to a window. |
| `InpStartHour` / `InpStartMinute` | `7:00` | Window start (server time). |
| `InpEndHour` / `InpEndMinute` | `20:00` | Window end (server time, wraps midnight if start > end). |

### Misc

| Input | Default | What it does |
|---|---|---|
| `InpMagic` | `9001` | Magic number — change if you run more than one instance. |
| `InpComment` | `1mScalper` | Trade comment. |
| `InpVerboseLog` | `true` | Print order placement events to the Experts log. |

---

## Strategy logic, in detail

On every tick the EA:

1. Detects when a new M1 bar has opened.
2. Cancels any leftover pending orders from the previous minute.
3. Checks filters: session window, max open positions, spread, candle size.
4. Reads the **just-closed** candle (index 1).
   - Bullish (`close > open`) → `BuyStop` at `high + entry_buffer`.
   - Bearish (`close < open`) → `SellStop` at `low - entry_buffer`.
   - Doji (`close == open`) → skipped.
5. Sets the initial SL just beyond the signal candle's other extreme.
6. Sizes the lot so that hitting that SL = `InpRiskPercent` of current equity.
7. Sets pending order expiry to 60 seconds — if the high/low isn't broken
   inside the new candle, the pending dies on its own.

Once a position is filled, on every tick:

- If profit ≥ `InpBreakevenTriggerPips`, ratchet SL to entry +
  `InpBreakevenBufferPips` (so spread / commission is covered, not just zero).
- If profit ≥ `InpTrailStartPips`, switch to a trailing stop
  `InpTrailDistancePips` behind price.
- The SL only ever moves in your favor (ratchet — never loosens).

The broker's `SYMBOL_TRADE_STOPS_LEVEL` is respected on every order and every
modification, so the EA won't be rejected for placing stops too close.

---

## Recommended starting profiles

These are starting points only; tune them to the symbol and your account. All
pip values assume 5/3-digit pricing (the EA auto-detects this).

**Tight, high-frequency forex scalp (EURUSD, USDJPY, GBPUSD, low-spread broker)**

```
InpEntryBufferPips      = 0.5
InpSLBufferPips         = 1.0
InpMinCandleSizePips    = 1.0
InpMaxCandleSizePips    = 15.0
InpMaxSpreadPips        = 1.5
InpBreakevenTriggerPips = 3.0
InpBreakevenBufferPips  = 0.5
InpTrailStartPips       = 5.0
InpTrailDistancePips    = 3.0
InpRiskPercent          = 0.5
InpDailyProfitTarget    = 1.0
InpDailyLossLimit       = 2.0
```

**More room for indices / gold (XAUUSD, US500, NAS100)**

Indices and gold move in much larger increments. Treat the "pip" inputs as
points-of-the-minimum-tick scaled by 10. Reasonable starting values:

```
InpEntryBufferPips      = 1.0
InpSLBufferPips         = 2.0
InpMinCandleSizePips    = 5.0
InpMaxCandleSizePips    = 0           (disable)
InpMaxSpreadPips        = 0           (disable; gold/indices spreads vary)
InpBreakevenTriggerPips = 8.0
InpBreakevenBufferPips  = 1.0
InpTrailStartPips       = 15.0
InpTrailDistancePips    = 8.0
InpRiskPercent          = 0.25
```

---

## Honest notes about "1% per day"

A few realistic notes — not to talk you out of it, just to keep expectations
sane so the EA gets used well:

- **1% / day compounded is ~12.7× per year.** Nobody sustainably hits that on
  a 1-minute breakout strategy on a live retail account. Use it as a daily
  target to *stop trading early* (which the EA already does via
  `InpDailyProfitTarget`), not as an expectation.
- **Spread and commission are the real enemy on M1.** A 0.5 pip raw spread +
  $7/lot commission round-trip can easily eat 1.5–2 pips per trade. Run the
  EA on a low-spread / commission account (RAW / ECN) and use the
  `InpMaxSpreadPips` filter aggressively.
- **News spikes will whipsaw this strategy.** Either pause it manually around
  high-impact news, or pair it with an external news filter if you want
  fully hands-off operation.
- **Candle-extreme stops are sometimes very tight on inside-bar candles.**
  That's why `InpMinSLPips` exists — it skips trades where the SL is
  unrealistically small.
- **Backtest with real-tick data.** "Every tick" mode in MT5 Strategy Tester
  uses real spreads from history if you have it; this is essential at this
  timeframe.

---

## Possible follow-ups (easy to add)

- ATR-based dynamic SL/trail (auto-adapts to volatility).
- Higher-timeframe trend filter (e.g. only take longs when 15m EMA slope is
  up) — useful to cut the chop.
- News blackout window (skip trades N minutes around scheduled releases).
- Per-symbol parameter sets so you can attach the EA to a basket.
- Partial close at +N pips with the rest left on the trailing stop.

Tell me which of these (if any) you want and I'll bolt them on.
