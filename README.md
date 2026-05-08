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
| `InpEntryBufferPips` | `1.0` | How many pips above the high (or below the low) to place the stop entry. A small buffer reduces "wick-only" fills. Set to `0` to enter exactly at the high/low. |
| `InpUsePendingExpiry` | `true` | Cancel the pending if it doesn't fill quickly. |
| `InpPendingExpirySec` | `60` | How long the pending order is valid for (one minute by default = current candle only). |
| `InpMinCandleSizePips` | `5.0` | Skip dojis / micro-candles. |
| `InpMaxCandleSizePips` | `0` | Skip absurdly large candles where the stop would be huge (`0` = disabled). |
| `InpMaxSpreadPips` | `0` | Skip the trade if spread is wider than this (`0` = disabled). |

### Stop loss / take profit

| Input | Default | What it does |
|---|---|---|
| `InpSLMode` | `SL_CANDLE_EXTREME` | `SL_CANDLE_EXTREME` parks SL just beyond the signal candle's other extreme. `SL_FIXED_PIPS` uses a fixed pip distance instead. |
| `InpSLBufferPips` | `0.5` | Buffer pips beyond the candle low/high when using `SL_CANDLE_EXTREME`. |
| `InpSLFixedPips` | `8.0` | Fixed pip stop, only used in `SL_FIXED_PIPS` mode. |
| `InpMinSLPips` | `5.0` | Reject trades whose SL distance is implausibly tight (which would size into a huge lot). |
| `InpMaxSLPips` | `20.0` | Reject trades whose SL distance is huge (`0` = disabled). Caps wide-candle outliers. |
| `InpTakeProfitPips` | `0.0` | Optional fixed TP. `0` means no TP at all — let the trailing stop close the trade. |

### Break-even & trailing

| Input | Default | What it does |
|---|---|---|
| `InpBreakevenTriggerPips` | `10.0` | Move SL to break-even (+ buffer) when this much profit is reached. |
| `InpBreakevenBufferPips` | `1.0` | Pips locked in at BE (so you cover spread / commission). |
| `InpTrailMode` | `TRAIL_ATR` | `TRAIL_FIXED_PIPS` uses fixed pip distance. `TRAIL_ATR` scales the trail with current volatility (recommended on noisy symbols like gold). |
| `InpTrailStartPips` | `20.0` | *(FIXED mode only)* Start trailing after this much profit. |
| `InpTrailDistancePips` | `15.0` | *(FIXED mode only)* Distance the trailing stop sits behind price. |
| `InpATRTimeframe` | `PERIOD_M5` | *(ATR mode)* Timeframe to read ATR from. M5 is smoother than M1 and gives more stable trail distances. |
| `InpATRPeriod` | `14` | *(ATR mode)* ATR averaging period. |
| `InpATRTrailStartMult` | `1.0` | *(ATR mode)* Start trailing once profit ≥ ATR × this. |
| `InpATRTrailDistMult` | `2.0` | *(ATR mode)* Trail distance = ATR × this. Increase to give winners more room. |

### Money management

| Input | Default | What it does |
|---|---|---|
| `InpLotMode` | `LOT_RISK_PERCENT` | `LOT_FIXED` uses `InpFixedLot`. `LOT_RISK_PERCENT` sizes lots so that the SL = `InpRiskPercent` of equity. |
| `InpFixedLot` | `0.01` | Lot size in fixed mode. |
| `InpRiskPercent` | `0.25` | Risk per trade in % of equity. |
| `InpMaxOpenPositions` | `1` | Max positions opened by this EA on this symbol concurrently. |

### Daily limits

| Input | Default | What it does |
|---|---|---|
| `InpDailyProfitTarget` | `0.25` | Stops the algo after +X% on the day. Pendings cancel and (with `InpCloseAllOnDailyHalt=true`) open positions are closed. Resets at next server day. |
| `InpDailyLossLimit` | `1.0` | Stops the algo after -X% on the day, same flatten-and-halt behaviour. |
| `InpCloseAllOnDailyHalt` | `true` | If `true`, hitting either daily limit closes all open positions immediately. If `false`, the limits only halt *new* entries and let existing trades run their trail. |

### Session filter

| Input | Default | What it does |
|---|---|---|
| `InpUseSessionFilter` | `true` | Restrict trading to a window. |
| `InpSessionUseGMT` | `true` | If `true`, the start/end times below are interpreted in **GMT** (recommended — same numbers regardless of broker). If `false`, they're interpreted in your **broker's server time**. |
| `InpBrokerGMTOffset` | `3` | Your broker's server offset from GMT, in hours. Only used when `InpSessionUseGMT = true`. Most MT5 brokers (Exness, IC Markets, FBS, RoboForex) run on **GMT+3 in summer / GMT+2 in winter**. Pepperstone, FXCM and a few others run on GMT+0. **You can find this in the broker's server name** (e.g. *Exness-MT5Real6* = GMT+3) or by comparing the clock at the top-right of MT5 to your local time. |
| `InpStartHour` / `InpStartMinute` | `13:30` | Window start. Default = NY equity open in GMT during US daylight time. |
| `InpEndHour` / `InpEndMinute` | `20:00` | Window end. Default = NY equity close in GMT during US daylight time. Wraps midnight if start > end. |

> **Why a manual offset and not auto-detect?** The MT5 Strategy Tester deliberately runs in a fixed timezone — `TimeGMT()` returns broker server time during a backtest, not real GMT. Without an explicit offset the session filter would silently apply the wrong window in your tests. Setting the offset once is a one-line operation and keeps live/tester behaviour identical.

### NY session reference (set these in `InpStartHour` / `InpEndHour`)

With `InpSessionUseGMT = true`:

| What you want | DST (≈ Mar – early Nov) | Standard time (≈ Nov – Mar) |
|---|---|---|
| **NY equity** (9:30 AM – 4:00 PM ET) | `13:30 → 20:00` GMT *(default)* | `14:30 → 21:00` GMT |
| **NY forex** (8:00 AM – 5:00 PM ET) | `12:00 → 21:00` GMT | `13:00 → 22:00` GMT |
| **NY full incl. after-hours** (4:00 AM – 8:00 PM ET) | `08:00 → 00:00` GMT | `09:00 → 01:00` GMT |

When the US switches DST in March / November, bump the hours by 1 to keep matching NY local time. Or just use the **NY forex** range — it's wide enough to comfortably cover the equity session even if you forget to adjust for DST.

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
