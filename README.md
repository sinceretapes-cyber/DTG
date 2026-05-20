# DTG — Bar-by-Bar Breakout EA (MT5)

A deliberately simple MetaTrader 5 Expert Advisor. The strategy in one
sentence:

> On every new bar, look at the candle that just closed. If it was bullish,
> place a buy stop at its high (+ a few pips). If it was bearish, place a
> sell stop at its low (- a few pips). When the next bar opens (i.e. our
> candle has closed), close the position at market regardless of P&L.
> Repeat forever.

Position lifetime is **one candle, max**. There is no trailing stop, no
break-even, no trend filter, no take profit. The only safety net is a
catastrophic SL in case price spikes hard against you mid-candle.

The EA file lives at `MT5/Experts/OneMinuteScalper.mq5`.

---

## Install

1. MT5 → `File → Open Data Folder` → navigate into `MQL5/Experts/`.
2. Copy `OneMinuteScalper.mq5` into that folder (or paste its contents
   into MetaEditor and save). On Mac, the bulletproof method is:
   - In MT5 press `F4` → MetaEditor opens.
   - `File → New File → Expert Advisor (template) → Continue → Continue → Finish`
     and call it `OneMinuteScalper`.
   - Wipe the generated template (`Cmd+A`, `Delete`).
   - Paste the contents of `OneMinuteScalper.mq5`.
   - `Cmd+S`, then `F7` to compile. The Errors pane should show
     `0 errors, 0 warnings`.
3. In MT5, refresh `Navigator → Expert Advisors`. Drag `OneMinuteScalper`
   onto a chart of the symbol you want to trade.
4. Set the **chart timeframe to whatever bar size you want to trade** —
   M1, M5, M15. The EA reads `_Period`, so the chart timeframe IS the
   strategy timeframe.
5. On the EA's Common tab, tick **Allow Algo Trading**. Make sure the
   global Algo Trading button at the top of MT5 is green.

---

## Inputs

### Strategy

| Input | Default | What it does |
|---|---|---|
| `InpTradeBullish` | `true` | Take longs after bullish bars. |
| `InpTradeBearish` | `true` | Take shorts after bearish bars. |
| `InpEntryBufferPips` | `1.0` | Pips above the previous high (or below the previous low) at which the stop entry is parked. `0` = at the exact high/low. A small buffer reduces wick-only fills. |

### Stop Loss

| Input | Default | What it does |
|---|---|---|
| `InpStopLossPips` | `30.0` | Catastrophic SL distance in pips. The EA exits at bar close, but a fast adverse spike could move further than the timeframe's normal range — this catches that. **Tune to your timeframe and symbol.** Suggested starting points: M1 gold `30`, M5 gold `60-100`, M1 EURUSD `15`, M5 EURUSD `25`. |

### Money Management

| Input | Default | What it does |
|---|---|---|
| `InpLotMode` | `LOT_RISK_PERCENT` | `LOT_FIXED` uses `InpFixedLot`. `LOT_RISK_PERCENT` sizes the lot so that hitting `InpStopLossPips` = `InpRiskPercent` of equity. |
| `InpFixedLot` | `0.01` | Lot size in fixed mode. |
| `InpRiskPercent` | `0.25` | Risk per trade as % of equity. With `InpStopLossPips=30` and `InpRiskPercent=0.25`, a $1k account risks $2.50 per trade and uses ~0.08 lots on gold. |

### Filters

| Input | Default | What it does |
|---|---|---|
| `InpMaxSpreadPips` | `10.0` | Skip placing a new pending if spread is wider than this. **Important** on gold to avoid the weekend gap-open scenario where spread blows out to 50+ pips. `0` disables the check. |

### Trading Window

Restricts new entries to a specific window each day. **Existing positions still close at the next bar regardless** — the window only gates whether new pending orders are placed.

The times use `TimeLocal()`, i.e. **your PC's clock** — exactly what you read off your computer's taskbar / menubar. No broker / GMT conversion needed.

| Input | Default | What it does |
|---|---|---|
| `InpUseTimeWindow` | `true` | Master switch for the window filter. |
| `InpStartHour` | `16` | Window start hour (PC local time, 0-23). |
| `InpStartMinute` | `30` | Window start minute. |
| `InpEndHour` | `17` | Window end hour. |
| `InpEndMinute` | `30` | Window end minute. Wraps midnight if start > end. |

Default = **16:30 → 17:30 PC local time**, i.e. one hour each afternoon.

### Misc

| Input | Default | What it does |
|---|---|---|
| `InpMagic` | `9001` | Magic number — change if you run more than one instance. |
| `InpComment` | `barRider` | Trade comment. |
| `InpVerboseLog` | `true` | Print order placements / closes / skips to the Experts log. |

---

## Strategy logic, in detail

### One bar at a time

The EA acts only at bar boundaries. On each new bar:

1. **Close any of our open positions at market.** That position belongs to
   the previous bar; the previous bar has just closed; therefore the
   position closes — regardless of whether it's in profit or drawdown.
2. **Cancel any of our pending orders.** They were valid for the bar we
   just left; they don't carry over.
3. **Read the just-closed bar (index 1).**
   - `close > open` (bullish) → place a `BuyStop` at `high + EntryBuffer`.
   - `close < open` (bearish) → place a `SellStop` at `low - EntryBuffer`.
   - `close == open` (doji) → skip.
4. The pending order has a catastrophic `InpStopLossPips` SL attached (used
   only if a spike runs past it before bar close).

### Lifecycle of a single trade

```
bar N-1: bullish close
─────────────────────────────────────────────────────────────────
bar N opens
  EA places BuyStop at bar N-1's high + buffer
  Some time inside bar N price breaks the high → fill
  Position is open with the catastrophic SL parked far below
bar N closes / bar N+1 opens
  EA closes the position at market on the very first tick of bar N+1
  P&L = (close-of-bar-N - fill-price) × lots, regardless of sign
```

If price never broke the previous high during bar N, the pending was
cancelled at the start of bar N+1 and no trade was taken.

### Fully timeframe-agnostic

The EA reads `_Period`, which is the chart's timeframe. So:

- Drop it on **M1** chart → trades each minute.
- Drop it on **M5** chart → trades each 5-minute bar.
- Drop it on **M15** chart → trades each 15-minute bar.
- … and so on.

Bigger timeframes generate fewer, larger trades; smaller timeframes more
trades but smaller per-trade size.

---

## Honest notes

- The EA places a trade on every bar that has a clear directional close
  (everything except dojis). It will trade through low-volatility periods,
  news spikes, and rollover unless you stop it manually or layer on a
  filter.
- Bar-close exit means you're capped to **one bar of profit** even if a
  trend is starting. There is no trailing stop in this version. If you
  want to ride trends past a single bar, that's a different strategy
  (the `v1` of this EA had that behaviour and is in git history if you
  ever want to revive it).
- Spread + commission scales with trade frequency. On M1 with a 1-pip
  spread/commission cost per round-trip, you're paying that on every bar.
  Run on a low-spread / ECN account.
- Backtest with **Every tick based on real ticks** to get realistic spread
  behaviour. Synthetic ticks under-estimate spread cost.

---

## Quick troubleshooting

| Symptom | Likely cause / fix |
|---|---|
| EA loaded but no trades | Algo Trading not enabled (toolbar + EA Common tab). Or all bars are doji-close. Or spread permanently > `InpMaxSpreadPips`. Check the Journal. |
| Lots are way bigger than expected | `InpLotMode` is `LOT_RISK_PERCENT` and `InpStopLossPips` is set very small, sizing the lot huge. Either widen the SL or drop the risk %. |
| Lots are 0 / "invalid volume" | Account too small for your risk %, or broker minimum is bigger than the calculated lot. Use `LOT_FIXED` with `InpFixedLot=0.01` to verify. |
| Pendings keep getting "invalid stops" | Broker has an unusually high `STOPS_LEVEL`. Increase `InpEntryBufferPips` and `InpStopLossPips`. |
| Spread filter rejects everything | Drop `InpMaxSpreadPips` and re-test. On wide-spread brokers (or during off-hours) gold spreads can sit at 5-15 pips routinely. |
| One trade then nothing | Check `Inputs` tab — left-over values from previous runs are notoriously sticky in MT5's tester. Manually retype values if needed. The Journal prints all inputs at startup; verify the build tag matches the source. |

---

## Diagnostics in the Journal

At startup the EA prints lines like:

```
BarRider init: TF=PERIOD_M1 digits=2 pip=0.01 magic=9001 build=2026-05-08-v5
Inputs: EntryBuf=1.0 SLPips=30.0 LotMode=1 Risk=0.2500% FixedLot=0.01 MaxSpread=10.0
Inputs: TradeBull=true TradeBear=true
```

If `build=2026-05-08-v5` doesn't appear, you're running an older compile —
recompile in MetaEditor (`F7`).

During trading you'll see:

```
BuyStop placed: lot=0.08 entry=4825.71 sl=4825.41 slPips=30.0
Closed #142 at bar end (P/L 12.40)
SellStop placed: lot=0.08 entry=4823.10 sl=4823.40 slPips=30.0
Closed #143 at bar end (P/L -8.20)
...
```

That's the whole life of a trade in two log lines.
