# DTG VWAP-BB Mean Reversion Scalper — Strategy

> Read this in full before changing any input. Every filter exists because
> removing it materially worsens live results. The defaults bias the EA
> toward **selectivity**, not frequency.

---

## 1. Thesis

Gold (XAUUSD) tends to **consolidate during the Asian session** (00:00 –
06:00 UTC). London / New York desks that drive the trend are flat. With
limited fundamental flow, the market behaves like a noise process pinned
to a slowly-drifting fair value. Two reasonable estimators of that fair
value during this window:

1. **Anchored VWAP** from the Asian open — volume-weighted mean price
   since the anchor.
2. **20-period Bollinger Band middle** on M5 — a simple moving average
   bracketed by 2σ envelopes.

When price wanders out to the 2σ envelope **and** beyond −1σ of VWAP
**and** a fast momentum oscillator (RSI(7) on M1) has flushed to its
extreme and is starting to recover **and** the last M5 candle closes
back toward the mean — we have a multi-confirmation mean-reversion
signal. Targets are fixed reversion levels (VWAP midline, then BB
midline / VWAP +0.5σ in trade direction).

This is **not** a trend-following or breakout setup. The whole edge is
*betting against the noise excursion*. The same setup taken during
London/NY hours, or during high-volatility regimes, produces large losers
that wipe out weeks of small wins.

---

## 2. Why each filter exists

| Filter                       | What it kills                                                       |
| ---------------------------- | -------------------------------------------------------------------- |
| Asian session window         | Prevents trading directional London/NY flow                          |
| M15 EMA50 ≈ EMA200 (±0.3%)   | Refuses to fade an active intraday trend                             |
| H1 ATR ≤ 1.2× 20-day median  | Filters NFP / FOMC carry-over weeks                                  |
| M5 ATR ∈ [25, 80] points     | Below 25 pts: market is dead, slippage > edge. Above 80: trending    |
| Lower BB(2σ) touch on M5     | Confirms the noise excursion is statistically meaningful             |
| Price ≤ VWAP −1σ             | Confirms divergence from session fair value                          |
| M1 RSI(7) cross-back from <25 | Momentum has flushed and is now rotating — classic exhaustion        |
| Last M5 close bullish (long) | "Engulfing-ish" confirmation; reversion has begun                    |
| Spread ≤ 25 pts AND ≤ 1.5× median | Avoids opening a 50-pt-SL trade with a 30-pt spread             |
| News filter (USD/EUR HIGH, NFP, FOMC) | Eliminates the worst tail-risk environments              |
| Day-of-week (Fri PM, Sun open) | Weekend gap risk and Monday-open gap risk                          |
| Max 1 trade/side per session | Stops "averaging in" on a failing setup (most blow-up pattern)       |
| Max 2 concurrent total       | Caps absolute downside if both sides are wrong at once               |

---

## 3. What we explicitly do NOT do

- **No grid recovery.** Adding to a losing position turns a 1% loss
  into a 10% loss.
- **No martingale.** Doubling lot after a loser turns a 4% drawdown
  into a 50% drawdown.
- **No "hedging" neutraliser.** Opening an offsetting position locks in
  the loss while adding spread cost and swap.
- **No stealth SL.** Broker-side SL is non-negotiable; if MT5 disconnects
  the trade is still protected.
- **No skipping the news filter for "more trades".** The expectation is
  ~1–3 trades/day on normal Asian sessions, 0 on NFP / FOMC days.
- **No mid-build parameter optimisation.** Optimisation is a separate
  workflow on real-tick history with walk-forward validation.

---

## 4. When this EA underperforms

By design the EA will under-perform a benchmark in these regimes:

- **Trend days.** EMA divergence widens, trend-day kill switches fire
  at small losses or breakeven. We pay 1–3 small kill losses to avoid
  one catastrophic loss.
- **NFP / FOMC weeks.** Most trades blocked by the news filter; rolling
  PnL flat.
- **Holiday weeks.** Volatility filter rejects too-low ATR; rolling
  PnL flat.
- **Sudden regime shifts** (geopolitical shocks, central-bank surprises).
  Vol-spike kill closes positions for a small loss; lots may shrink due
  to rolling-PF protection.

A typical month: ~50–70 trades, 55–65% win rate, profit factor 1.1–1.4
live, 5–10% returns at 1% risk, 15–25% max drawdown. **Half of those
months will be the lower end of those ranges.** The drawdown numbers
are not optional — anyone projecting smoother equity curves is wrong.

---

## 5. Position sizing

The lot is **computed from the actual stop distance** (not the max SL).
A long with a 25-point stop at 1% risk on $10 000 equity produces
roughly 4× the lot of the same trade with a 50-point stop. This is
intentional: it keeps per-trade dollar risk constant regardless of
volatility.

The position sizing function:

1. Reads `SYMBOL_TRADE_TICK_SIZE`, `SYMBOL_TRADE_TICK_VALUE`, `SYMBOL_POINT`.
2. If `SYMBOL_TRADE_TICK_VALUE` is zero (common bug on some brokers in
   non-USD account currencies), derives value-per-point via a
   USD→account-currency cross.
3. Computes raw lot = `(equity × risk_fraction) / (sl_points × value_per_point)`.
4. Floors to `SYMBOL_VOLUME_STEP`. **Never rounds up.**
5. Returns 0 if the floored lot is below `SYMBOL_VOLUME_MIN` — we
   skip the trade rather than over-risk.

If rolling-30 trade PF drops below 1.0 the lot is halved automatically.
Below 0.8 the EA disables itself and writes an alert.

---

## 6. SL / TP rationale

- **SL** is the recent swing extreme (lowest low for longs, highest high
  for shorts) **plus** a 0.3× ATR buffer. Anchoring to structure beats
  fixed-distance stops on mean-reversion setups.
- A 50-point absolute SL cap discards any trade where structure-based
  stops drift past the strategy's tolerance — that's a vol-regime change
  signal.
- **TP1** at VWAP midline closes half and moves the remaining stop to
  breakeven + 1 point. This converts a winner into a "free option" on
  the rest of the move.
- **TP2** at the BB midline (or VWAP +0.5σ as fallback) closes the
  remaining half. We do **not** trail — mean reversion has fixed
  targets, not open-ended runners.

---

## 7. Realistic performance expectations

| Metric                  | Expected range (live)    |
| ----------------------- | -------------------------- |
| Win rate                | 55 – 65 %                  |
| Reward : Risk           | 0.7 – 1.0                  |
| Profit factor           | 1.10 – 1.40                |
| Monthly return @ 1 % risk | 5 – 10 %                 |
| Max drawdown            | 15 – 25 %                  |
| Trades / day (avg)      | 1 – 3                      |
| Trades / month (avg)    | 30 – 60                    |
| Losing months / year    | 2 – 4 (expected)           |

Aggressive sizing **inside** these guardrails is fine. Aggressive
*loosening* of the guardrails will move the strategy from "boring
positive expectancy" to "violently negative expectancy" — the regime
filters are what create the edge, not the entry signal alone.
