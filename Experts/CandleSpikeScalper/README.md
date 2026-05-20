# Candle Spike Scalper (CSS) — MetaTrader 5 EA

A multi-timeframe pending-stop scalper that lives on the **H4, H6, H8, H12, D1 and W1** candles.

Each timeframe is treated **independently** — there is no combined bias. The EA watches the
previously-closed candle on each enabled timeframe and:

- If that candle closed **bullish** (`close > open`) → it places a **Buy Stop** just above the
  candle's high on the new candle.
- If it closed **bearish** (`close < open`) → it places a **Sell Stop** just below the candle's
  low on the new candle.
- Doji candles (`close == open`) → no trade.

Because every timeframe has its own magic number, opposing trades from different timeframes can
co-exist (e.g. long via H4 + short via H6).

The default management is aggressive scalp: when a position is in profit by `InpPartialTriggerPips`,
~90 % is closed and the remaining runner's stop is moved to break-even so it is risk-free.

## Files

```
Experts/CandleSpikeScalper/
├── CandleSpikeScalper.mq5    # the EA source
└── README.md                 # this file
```

## Install

1. Open MetaTrader 5 → `File` → `Open Data Folder`.
2. Copy the `CandleSpikeScalper` folder into `MQL5/Experts/`.
3. In the MetaEditor, open `CandleSpikeScalper.mq5` and press **F7** to compile.
4. Refresh the *Navigator* in the terminal, drag `CandleSpikeScalper` onto a chart of the symbol
   you want to trade, allow algo-trading, and configure the inputs.

The EA only trades the symbol of the chart it is attached to. Attach one instance per symbol.

## Inputs

### Timeframes
| Input | Default | What it does |
|---|---|---|
| `InpUseH4` … `InpUseW1` | `true` | Enable / disable each individual timeframe |

### Entry
| Input | Default | What it does |
|---|---|---|
| `InpOffsetPips` | `1.0` | Pips of offset above the high / below the low for the trigger |
| `InpExpirePending` | `true` | Cancel any un-triggered pending the moment a new bar of that TF appears |
| `InpUsePendingExpiry` | `true` | Also set a broker-side expiry on the pending order |
| `InpPendingExpiryBars` | `1` | Pending lifetime in bars of its own timeframe |

### Stop loss
| Input | Default | What it does |
|---|---|---|
| `InpSLMode` | `SL_FIXED_PIPS` | `SL_FIXED_PIPS` or `SL_M1_CANDLE` |
| `InpStopLossPips` | `15.0` | SL distance in pips when fixed |
| `InpM1BufferPips` | `1.0` | Extra pips beyond the M1 candle low/high when using `SL_M1_CANDLE` |
| `InpMinSLPips` | `4.0` | Safety floor on SL distance |
| `InpMaxSLPips` | `60.0` | Safety cap on SL distance |

### Take profit / partial close
| Input | Default | What it does |
|---|---|---|
| `InpPartialTriggerPips` | `12.0` | Profit (pips) at which the partial close + BE move fires |
| `InpPartialClosePct` | `90.0` | % of the position that is closed at the trigger |
| `InpMoveToBreakEven` | `true` | Move the runner's SL to break-even after partial |
| `InpBreakEvenPaddingPips` | `1.0` | Pips beyond entry for the BE stop (covers spread / commission) |
| `InpFinalTPPips` | `0.0` | Optional hard TP for the runner. `0` = no TP, let it run |

### Sizing
| Input | Default | What it does |
|---|---|---|
| `InpLotMode` | `LOT_FIXED` | `LOT_FIXED` or `LOT_RISK_PCT` |
| `InpFixedLot` | `0.10` | Fixed lot size |
| `InpRiskPercent` | `1.0` | % of account balance risked per trade (computed from real SL distance) |
| `InpMaxLot` | `5.0` | Hard cap on the computed lot size |

### Misc
| Input | Default | What it does |
|---|---|---|
| `InpMagicBase` | `73310000` | Base magic. Each TF gets `base + PeriodSeconds(tf)` |
| `InpComment` | `"CSS"` | Comment prefix on orders (e.g. `CSS\|PERIOD_H4`) |
| `InpDeviationPoints` | `20` | Max slippage on management closes (points) |
| `InpVerboseLog` | `true` | Print detailed log lines |

## How the management works

On every tick the EA loops through any open positions whose magic number belongs to it:

1. Compute current profit in pips.
2. If profit < `InpPartialTriggerPips` → do nothing.
3. Otherwise, if the position's stop loss is **not yet at / past the entry**:
   - Close `InpPartialClosePct` of the volume (rounded down to the broker's volume step).
   - If the remaining volume would fall below the broker's minimum lot, the partial is skipped
     (we just move to BE so the position is risk-free).
   - If `InpMoveToBreakEven` is `true`, move SL to `entry ± InpBreakEvenPaddingPips`.
4. Subsequent ticks see "BE already done" via the SL position and leave the runner alone.

## A few suggested presets

- **Default scalp:** SL `SL_FIXED_PIPS = 15`, `InpPartialTriggerPips = 12`, `InpPartialClosePct = 90`.
- **Tighter scalp:** SL `SL_FIXED_PIPS = 10`, `InpPartialTriggerPips = 8`.
- **M1-structure SL:** `InpSLMode = SL_M1_CANDLE`, `InpM1BufferPips = 1`,
  `InpMinSLPips = 5`, `InpMaxSLPips = 25`.
- **Risk-based sizing:** `InpLotMode = LOT_RISK_PCT`, `InpRiskPercent = 0.5–1.0`.

## Notes / caveats

- This is an explicitly **high-risk, aggressive** model. Tight stops mean a higher hit rate of
  stop-outs per signal — the edge depends on the partial close hitting often enough to outweigh
  the losers. **Always backtest on the symbols / spreads you actually trade.**
- Some brokers have a minimum stop-level distance (`SYMBOL_TRADE_STOPS_LEVEL`). If the trigger
  price is already inside that band when the new bar opens, the pending is skipped (you would
  just be chasing the spike).
- The SL-mode `SL_M1_CANDLE` uses the most-recent **closed** M1 candle at the moment the pending
  is placed. The actual fill might happen later — by design we do not chase a moving M1 candle.
- "Bullish" / "bearish" is strictly `close > open` / `close < open`; wicks are not used as the
  bias signal.
- The EA only trades the symbol of the chart it is attached to.
