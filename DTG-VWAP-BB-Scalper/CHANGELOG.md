# Changelog

All notable changes to the DTG VWAP-BB Mean Reversion Scalper EA are
documented here. The project follows [Semantic Versioning](https://semver.org/).

## [0.1.0] — 2026-05-12

First-pass production build per the DTG VWAP-BB Scalper spec.

### Added
- `DTG_VWAP_BB_Scalper.mq5` main EA entry point with state machine,
  per-tick orchestration, and watchdog.
- `Include/DTG_Config.mqh` — all inputs, enums and named constants
  (no inline literals elsewhere). Input groups: General, Session,
  Strategy, Entry filters, Risk management, Trade management, Kill
  switches, News filter, Debugging.
- `Include/DTG_State.mqh` — `ENUM_DTG_STATE`, `DTGTradeContext`,
  `DTGSessionBook`, `DTGRollingPF`.
- `Include/DTG_Logger.mqh` — structured logger, per-state-transition
  log, filter-rejection counters, daily summary file writer.
- `Include/DTG_Indicators.mqh` — BB / ATR(M5,H1) / EMA(M15)
  fast+slow / RSI(M1) handles; defensive single-value reads;
  session-anchored VWAP with ±1σ / ±2σ bands computed from M1
  tick-volume-weighted variance; rolling 20-day H1 ATR median;
  RSI cross-back detector; M5 swing extreme.
- `Include/DTG_Filters.mqh` — broker→UTC offset (quantised to 15 min,
  manual override in tester); session window; day-of-week guard;
  rolling 30-minute median spread; M5/H1 ATR volatility gate;
  M15 EMA flat-regime gate.
- `Include/DTG_News.mqh` — MQL5 native economic calendar wrapper
  (`CalendarValueHistory`); HIGH-impact / NFP / FOMC windowing
  (±15 / ±60 / ±90 min defaults); static CSV fallback for the
  strategy tester.
- `Include/DTG_Risk.mqh` — XAUUSD-safe lot sizing (handles non-USD
  account currencies via USD→account cross fallback); daily / weekly /
  running-DD caps; one-trade-per-side-per-day book-keeping; rolling-30
  trade profit-factor protection persisted to
  `Files/DTG_VWAP_BB_State.bin`.
- `Include/DTG_Setup.mqh` — long/short setup detection with the four
  confirmation gates (BB touch, VWAP −1σ break, M1 RSI cross-back,
  M5 confirming candle).
- `Include/DTG_Execution.mqh` — `CTrade`-based order send / modify /
  partial-close / close with retry logic (50 ms / 200 ms / 500 ms
  backoff, max 3 retries) and broker stops-level enforcement;
  symbol-suffix auto-detection.
- `Include/DTG_Management.mqh` — TP1 partial + breakeven move; TP2
  full close; trend / vol-spike / VWAP-break kill switches; time
  stop (session end + grace) force-close.
- `Files/calendar_static.csv` — static calendar template for the
  strategy tester with format documentation.

### Known limitations
- The MT5 live calendar does not back-fill historical events; static
  CSV is the only news-filter source in backtests.
- Anchored VWAP uses M1 tick-volume because real volume on metal
  pairs is unreliable.
- Parameter optimisation is intentionally out of scope for this
  build — to be done in a follow-up phase on real-tick history with
  walk-forward validation.
