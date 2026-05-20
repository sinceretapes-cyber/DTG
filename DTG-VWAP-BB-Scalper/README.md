# DTG VWAP-BB Mean Reversion Scalper

An MT5 (MQL5) Expert Advisor that mean-reverts **XAUUSD** during the **Asian
session** using an **Anchored VWAP** (with ±1σ / ±2σ bands) and **Bollinger
Bands**, plus a stack of strict regime / news / volatility / risk filters.

The EA is part of the "Day Trading Gold" (DTG) ecosystem but is **standalone**
— it does NOT depend on the DTG V8 indicator suite.

> Read [STRATEGY.md](STRATEGY.md) before changing inputs. The default settings
> reflect a deliberate trade-off between selectivity and frequency; weakening
> a filter to "see more trades" typically destroys live edge.

---

## 1. Install

1. Open MetaTrader 5 → **File → Open Data Folder** → `MQL5/`.
2. Copy the contents of this repository into the `MQL5` folder so that:
   - `MQL5/Experts/DTG-VWAP-BB-Scalper/DTG_VWAP_BB_Scalper.mq5`
   - `MQL5/Experts/DTG-VWAP-BB-Scalper/Include/DTG_*.mqh`
   - `MQL5/Files/calendar_static.csv` (optional — see §5)
3. In MetaEditor, open `DTG_VWAP_BB_Scalper.mq5` and press **F7** to compile.
   The build must finish with **0 errors / 0 warnings**.
4. Attach to an XAUUSD M5 chart and enable **Algo Trading**.

The EA auto-detects symbol suffixes — `XAUUSD`, `XAUUSD.m`, `XAUUSD.r`,
`GOLD`, `GOLD.x` all work without changing inputs. Use `InpSymbolOverride`
only if your broker uses an exotic name.

---

## 2. Broker requirements

The strategy is sensitive to spread and execution quality. Recommended:

| Item                | Requirement                                           |
| ------------------- | ----------------------------------------------------- |
| Account type        | ECN / Raw spread (commission-based)                   |
| XAUUSD avg spread   | ≤ $0.25 (25 points) outside news windows              |
| Execution           | Market execution, deviation 30 points or tighter      |
| Hedging mode        | Either netting or hedging accounts are supported      |
| Symbol contract     | Standard 100 oz contract (1 lot = 100 oz)             |
| VPS                 | Strongly recommended — co-location with broker        |
| Server clock        | Auto UTC offset detection works; set manually in tester via `InpBrokerToUtcOffsetMin` |

The position sizing routine handles non-USD account currencies safely
(uses `SYMBOL_TRADE_TICK_SIZE` / `SYMBOL_TRADE_TICK_VALUE` and falls back
to a USD→account-currency cross derivation if the broker reports zero).

---

## 3. Recommended inputs by account size

| Account size  | RiskPerTradePct | MaxTradesPerDay | MaxSpreadPoints |
| ------------- | --------------- | --------------- | --------------- |
| $1 000        | 0.75 %          | 3               | 25              |
| $5 000–10 000 | 1.00 % (default)| 4 (default)     | 25              |
| $25 000+      | 1.00 %          | 4               | 20              |
| Prop firm     | 0.50 %          | 2               | 20              |

Prop-firm note: set `InpMinHoldSeconds = 60` (default) to satisfy
hold-time requirements; some firms also disallow trading within ±5 min
of any rollover — set the Friday cut-off and Sunday block hours
appropriately.

---

## 4. State machine

```
IDLE
  → SCANNING            (in session + filters passing)
  → SETUP_DETECTED      (long/short setup conditions met)
  → ENTRY_PLACED        (OrderSend executed)
  → IN_TRADE_TP1_PENDING
  → IN_TRADE_TP2_PENDING (TP1 hit, BE set, half closed)
  → COOLDOWN            (all positions closed)
  → SCANNING
```

A watchdog forces the state back to `IDLE` if a non-terminal state
persists longer than `DTG_WATCHDOG_BARS` M5 bars without progress.

Every state transition is logged with timestamp, equity, spread and M5 ATR.

---

## 5. News filter & static calendar fallback

In live trading the EA uses the native MQL5 economic calendar
(`CalendarValueHistory`). It blocks trades within:

- **±15 min** of any HIGH-impact event in the configured currencies
  (default `USD, EUR`)
- **±60 min** of Non-Farm Payrolls (NFP)
- **±90 min** of FOMC rate decisions

The MT5 strategy tester does **not** load the live calendar. Provide a
`Files/calendar_static.csv` file using the format documented in the file
header. The EA loads it automatically when running under
`MQLInfoInteger(MQL_TESTER)` and `InpUseStaticCsvInTester = true`.

---

## 6. Kill switches

The EA closes any open position **immediately** if any of these fire:

| Switch                     | Trigger                                                 |
| -------------------------- | -------------------------------------------------------- |
| Trend-day kill             | `|EMA50−EMA200|/EMA200` > `InpTrendKillPct` (default 0.5%) |
| Volatility-spike kill      | M5 ATR > entry-time ATR × `InpVolSpikeMult` (default 2)  |
| VWAP-break kill (longs)    | M5 close < VWAP −`InpVwapBreakSigma`σ or below entry SL  |
| VWAP-break kill (shorts)   | Mirror image                                             |
| Daily-loss cap             | Realised+unrealised PnL ≤ −`InpDailyLossCapPct` of day-start equity |
| Weekly DD cap              | Drawdown from week-start equity ≥ `InpWeeklyDDCapPct`    |
| Running DD cap             | Drawdown from peak equity ≥ `InpMaxRunningDDPct`         |
| Time stop                  | Past `InpAsianEndHourUTC + InpTimeStopGraceMinutes`      |
| Equity-curve protection    | Rolling-30 trade PF ≤ 0.8 → EA disabled, manual review   |

The daily / weekly / running DD caps **halt new entries** and force-close
existing positions immediately when tripped.

---

## 7. Files & logs

- `Files/DTG_VWAP_BB_State.bin` — rolling-30 trade PF state (persistent).
- `Files/DTG_VWAP_BB_YYYYMMDD.log` — daily summary (trades, rejections, P&L).
- All state transitions, filter rejections and trade events also go to the
  MetaTrader **Experts** log.

Set `InpLogLevel = DTG_LOG_DEBUG` to see per-tick filter rejection reasons.
Leave it at `DTG_LOG_INFO` for normal live trading.

---

## 8. Smoke-test preset

A reasonable first back-test:

| Field         | Value                                  |
| ------------- | -------------------------------------- |
| Symbol        | XAUUSD                                 |
| Period        | M5                                     |
| Date range    | 2023.01.02 → 2023.01.31                |
| Modeling      | Every tick based on real ticks         |
| Spread        | Current / 20 points                    |
| Deposit       | 10 000 USD                             |
| Leverage      | 1:100                                  |

Defaults aim for ~1–3 trades per Asian session on a normal week — fewer
during NFP / FOMC weeks (by design).

---

## 9. Known limitations

- The MT5 economic calendar **does not back-fill historical events**, so the
  static CSV fallback is the only way to get news filtering in backtests.
- Anchored VWAP uses M1 tick-volume; on FX/metal pairs real volume is
  unreliable. Backtests in tick mode reproduce live results closely;
  M1-OHLC mode will be less accurate.
- No grid recovery, no martingale, no hedging neutraliser — **by design**.
  See [STRATEGY.md §3](STRATEGY.md).
- The EA does not optimise itself. Use the strategy tester's optimiser only
  with **walk-forward validation** on real-tick data.

---

## 10. Manual position interference

If you close a position manually, the EA detects this via `OnTrade()` and
flags the trade as resolved. It will not auto-reopen the same side during
the current session (one-per-side rule). To fully reset, remove the EA
from the chart, delete `Files/DTG_VWAP_BB_State.bin` if you also want to
clear the rolling-30 PF state, then re-attach.

---

## 11. Support & changelog

See [CHANGELOG.md](CHANGELOG.md). v0.1.0 is the first-pass build per spec.
