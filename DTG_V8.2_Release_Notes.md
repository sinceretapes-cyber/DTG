# DTG V8.2 — Release Notes

A major refresh of V8 with new modes, smarter visuals, and several fixes from the live charts.
Drop-in upgrade — no setting changes required.

---

## 🆕 What's New

### System Presets
One simple dropdown replaces the old System Rules checkboxes. Pick a trading mode by name:

- **V8 Pro** — Original strict 3-step system with TP1 → break-even trail. *(Default — recommended.)*
- **Funded Pro** — Strict gating with **binary trade management**. Every trade is either Entry → TP2 (Win) or Entry → SL (Loss). No TP1, no break-even. Designed for funded-account requirements where partial closes complicate things.
- **V8 Unlocked** — Every system filter off. More signals, but unverified edge. *(Use at your own risk — not recommended for live trading.)*

### Bias Recalc Countdown ("Rescan")
A new row at the bottom of the dashboard counts down to the next moment your bias can change — based on the **soonest** of the 4H / 6H / 8H / 12H / Daily / Weekly candle close. The cell flashes cyan when under 15 minutes, so you know when to keep an eye on the chart.

### Multi-Currency Lot Sizing
New `Account Currency` selector — choose USD / AUD / EUR / GBP and lot sizes auto-convert using live exchange rates. No more mental math if your prop firm pays in a different currency.

### Last Trade Outcome on Chart
The most recent completed trade stays visible on the chart with a clear `W` / `1:1` / `L` label. Glance at your chart and instantly know whether your last setup played out.

### Visual Polish
- **RR boxes shrink + turn orange** the moment 1:1 is secured, so you can see at a glance that risk is off the table (V8 Pro / V8 Unlocked).
- **`1:1 ✓` label** appears at the TP1 level when secured.
- **Frozen zone label** stays anchored to the discount zone that fired the trade, so you always know which zone you're trading from.

---

## ⚡ Improvements

- **Faster** — under the hood the script makes ~50% fewer data requests. Fewer runtime errors when you stack other indicators on the same chart.
- **Smoother** — dashboard now renders only on the latest bar, reducing lag on charts with long histories.
- **Cleaner menu** — System Preset moved to the top, inputs reorganized into clear groups, redundant toggles removed.
- **Smarter dashboard** — System row hides during a live trade so your eyes go straight to entry/SL/TP levels.
- **Weekly zone** still draws on the chart for awareness but is excluded from signal eligibility — keeps signals coming from the timeframes that actually produce edge (4H/6H/8H/12H/Daily).

---

## 🛠 Fixes

- **Discount zone now refreshes correctly after 1:1 secured.** Previously the zone could appear "stuck" behind price after TP1 was hit — fixed.
- **Pre-trigger SL wicks no longer count as losses.** If price wicked through SL on the signal bar before triggering and then flipped up to trigger the trade, V8.1 was flagging it as an immediate Loss — fixed; the trigger bar is now exempt from exit checks.
- **Bias countdown formatting cleaned up** (no more `1.75h 45m` — now reads `2h 45m` cleanly).
- Several behind-the-scenes stability fixes for fresh charts and edge-case bar conditions.

---

## How to Use

**Most members:** keep the default `V8 Pro` preset. Everything works exactly as you're used to.

**Funded-account traders:** switch to `Funded Pro`. Trade either runs to TP2 or hits SL — no in-between. Aligns with how prop firms grade you.

**Backtesting / experimentation:** `V8 Unlocked` shows you what raw EM1 + bias direction produces with no filters. A red warning banner appears at the bottom of the chart whenever this preset is active, as a reminder that signals are unfiltered.

---

## Drop-in Upgrade

No settings to migrate. Just paste the new V8.2 code into your TradingView Pine Editor → Save → Add to Chart. Your existing chart layouts and alerts continue to work.
