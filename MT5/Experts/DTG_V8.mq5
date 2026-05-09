//+------------------------------------------------------------------+
//|                                                       DTG_V8.mq5 |
//|                                                              DTG |
//|        Public V8 (EM1-only) — MT5 Expert Advisor port            |
//+------------------------------------------------------------------+
//
// Direct port of the DTG V8.2 Public (EM1-only) Pine indicator into a
// fully autonomous MT5 EA. The strategy logic is preserved 1:1; only
// the execution layer changes (broker pending orders + tick-driven
// TP1 management instead of Pine's bar-by-bar simulated state machine).
//
// User customisations vs. the V8 Pine source:
//   • EM1 entry model only (no EM2/EM3/EM4)
//   • Journal-only: no on-chart dashboard / RR boxes / labels
//   • TP1 → partial close (default 50%) AND move SL to break-even
//     (V8 Pro is BE-only; we layer partial close on top)
//   • Daily lockout fires on TP1 hit ("1 trade a day after 1:1")
//     V8 Pro fires it on TP2 — user explicitly chose tighter behaviour
//   • Daily lockout flag persists across MT5 restarts via MQL5\Files\
//
// 3-step system gate (unchanged from V8 Public):
//   Step 1 — Bias: 4H+6H+8H+12H+D+W candle-direction sum, |sum| >= 2
//   Step 2 — Zone tap: at least one signal-eligible discount zone
//            (4H/6H/8H/12H/Daily; weekly excluded) tapped during the
//            trading window (H4 candles 3-5 of the broker day)
//   Step 3 — EM1 pattern fires on the just-closed chart bar with
//            EMA8/EMA20 slope confirmation
//
// Recommended chart timeframes: M15 or M30 (per the V8 alert guide).
// Smaller TFs only honoured for XAU/XAG per the V8 source.
//+------------------------------------------------------------------+
#property copyright "DTG"
#property link      ""
#property version   "1.00"
#property strict
#property description "DTG V8 Public — EM1 + multi-TF bias + discount zones, journal-only"

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//============================ INPUTS ===============================
enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed lot
   LOT_RISK_PERCENT = 1  // % risk of equity per trade
  };

input group                "=== Signal ==="
input bool                 InpEnableLong         = true;     // Allow long signals
input bool                 InpEnableShort        = true;     // Allow short signals
input int                  InpSpreadBufferPips   = 3;        // Spread buffer (pips, V8 default 3)

input group                "=== System Rules (V8 Pro) ==="
input bool                 InpRequireZoneTap     = true;     // Require Step-2 zone tap before signal
input bool                 InpWindowOnly         = true;     // Signals only inside H4 window (candles 3-5)
input bool                 InpZoneTapsInWindow   = true;     // Step-2 taps only count inside the window
input bool                 InpOneTradePerDay     = true;     // Lock the day after 1:1 secured

input group                "=== TP / Risk Management ==="
input ENUM_LOT_MODE        InpLotMode            = LOT_RISK_PERCENT; // Lot sizing mode
input double               InpFixedLot           = 0.01;     // Fixed lot (LOT_FIXED only)
input double               InpRiskPercent        = 1.0;      // Risk % of equity per trade
input double               InpPartialClosePct    = 50.0;     // % to close at TP1 (0 = BE-only, no partial)
input bool                 InpMoveSLToBEOnTP1    = true;     // Move SL to entry when TP1 is hit

input group                "=== Filters ==="
input double               InpMaxSpreadPips      = 0.0;      // Max spread to allow new entries (0 = off)

input group                "=== Misc ==="
input long                 InpMagic              = 8200;     // Magic number
input string               InpComment            = "DTG_V8"; // Trade comment
input bool                 InpVerboseLog         = true;     // Verbose journal logging

//============================ GLOBALS ==============================
CTrade        trade;
CPositionInfo posInfo;
COrderInfo    ordInfo;

double   g_pip          = 0.0;       // 1 pip in price units (FX-adjusted)
int      g_digits       = 0;
double   g_spreadTick   = 0.0;       // V8 spread_tick — XAU=mintick*100, XAG=*1000, FX=*10, else g_pip (1 pip)
bool     g_isXAU        = false;
bool     g_isXAG        = false;
bool     g_isFX         = false;
bool     g_isCrypto     = false;
bool     g_isIndex      = false;
bool     g_isOil        = false;
datetime g_lastBarTime  = 0;         // last seen open-time of the chart's current bar

int      g_hEMA8        = INVALID_HANDLE;
int      g_hEMA20       = INVALID_HANDLE;

// Per-HTF zone state (persisted across bars on the chart TF).
// Index mapping: 0=4H, 1=6H, 2=8H, 3=12H, 4=D, 5=W.
bool     g_locked  [6];              // zone locked-out (invalidated)
bool     g_dashStk [6];              // sticky-touched (cleared on lock/rollover/bias-mismatch)
double   g_lastZT  [6];              // last seen zone-top  (for change detection)
double   g_lastZB  [6];              // last seen zone-bot
datetime g_lastHTFOpen[6];           // last seen HTF open time (for new-candle rollover)

bool     g_stepTwoMet      = false;
int      g_stepTwoBias     = 0;
bool     g_dailyProfitTaken = false; // set true on TP1 hit when InpOneTradePerDay
datetime g_currentBrokerDay = 0;     // 00:00 broker time of the current day

// Live trade state — mirrors Pine's TradeState UDT.
// 'entry/sl/tp1/tp2' captured at signal fire so we can manage TP1
// partial-close + BE move from tick events without round-tripping the
// broker for the original levels. dir: +1 buy, -1 sell, 0 idle.
struct TradeState
  {
   int      dir;
   double   entry;
   double   sl;
   double   tp1;
   double   tp2;
   datetime barTime;
   bool     tp1hit;
  };
TradeState g_trade;

string   g_persistFile = "";         // file path under MQL5\Files\

//============================ INIT/DEINIT ==========================
int OnInit()
  {
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   g_pip = (g_digits == 3 || g_digits == 5) ? point * 10.0 : point;

   // Symbol-class detection (mirrors V8 §6/§7).
   string sym = _Symbol;
   string SYM = sym; StringToUpper(SYM);
   g_isXAU    = (StringFind(SYM, "XAU") >= 0);
   g_isXAG    = (StringFind(SYM, "XAG") >= 0);
   g_isCrypto = (StringFind(SYM, "BTC") >= 0 || StringFind(SYM, "ETH") >= 0 ||
                 StringFind(SYM, "SOL") >= 0 || StringFind(SYM, "XRP") >= 0);
   g_isIndex  = (StringFind(SYM, "US30")   >= 0 || StringFind(SYM, "NAS100") >= 0 ||
                 StringFind(SYM, "SPX500") >= 0 || StringFind(SYM, "US500")  >= 0 ||
                 StringFind(SYM, "DE40")   >= 0 || StringFind(SYM, "UK100")  >= 0 ||
                 StringFind(SYM, "JP225")  >= 0 || StringFind(SYM, "AUS200") >= 0);
   g_isOil    = (StringFind(SYM, "USOIL") >= 0 || StringFind(SYM, "UKOIL") >= 0 ||
                 StringFind(SYM, "WTI")   >= 0 || StringFind(SYM, "BRENT") >= 0 ||
                 StringFind(SYM, "BCO")   >= 0);
   long calcMode = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_CALC_MODE);
   g_isFX = (calcMode == SYMBOL_CALC_MODE_FOREX || calcMode == SYMBOL_CALC_MODE_FOREX_NO_LEVERAGE);

   double mintick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(mintick <= 0) mintick = point;
   // Pine sets spread_tick = 0 for indices/oil/crypto, which silently
   // disables the buffer there. We default to g_pip instead so the
   // "Spread Buffer" input keeps its meaning across all asset classes.
   g_spreadTick = g_isXAU ? mintick * 100.0 :
                  g_isXAG ? mintick * 1000.0 :
                  g_isFX  ? mintick * 10.0   : g_pip;

   // CTrade boilerplate (same recipe as OneMinuteScalper).
   trade.SetExpertMagicNumber(InpMagic);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);

   // Per-HTF zone state — clean slate. Real values populate on first bar.
   for(int i = 0; i < 6; i++)
     {
      g_locked[i]       = false;
      g_dashStk[i]      = false;
      g_lastZT[i]       = 0.0;
      g_lastZB[i]       = 0.0;
      g_lastHTFOpen[i]  = 0;
     }

   ResetTradeState();

   g_hEMA8  = iMA(_Symbol, _Period, 8,  0, MODE_EMA, PRICE_CLOSE);
   g_hEMA20 = iMA(_Symbol, _Period, 20, 0, MODE_EMA, PRICE_CLOSE);
   if(g_hEMA8 == INVALID_HANDLE || g_hEMA20 == INVALID_HANDLE)
     {
      Print("Failed to create EMA handles — aborting init.");
      return(INIT_FAILED);
     }

   g_currentBrokerDay = BrokerDayStart(TimeCurrent());
   g_lastBarTime      = (datetime)iTime(_Symbol, _Period, 0);

   // Daily-lockout persistence — single file per (symbol, magic).
   // Lives under <Terminal>\MQL5\Files\. Skipped under tester.
   g_persistFile = StringFormat("DTG_V8_%s_%I64d.csv", _Symbol, InpMagic);
   LoadDailyLockState();

   // If we're attaching mid-trade (chart restart, EA reload), recover what
   // we can from broker state: position levels reveal entry/sl/tp2, and tp1
   // is the geometric midpoint of entry/tp2 (always true for V8's 1:2 RR).
   ReattachToLivePosition();

   PrintFormat("DTG V8 init: TF=%s digits=%d pip=%.*f spreadTick=%.*f magic=%I64d",
               EnumToString(_Period), g_digits, g_digits, g_pip, g_digits, g_spreadTick, InpMagic);
   PrintFormat("Symbol class: XAU=%s XAG=%s FX=%s Crypto=%s Index=%s Oil=%s",
               g_isXAU ? "Y" : "N", g_isXAG ? "Y" : "N", g_isFX ? "Y" : "N",
               g_isCrypto ? "Y" : "N", g_isIndex ? "Y" : "N", g_isOil ? "Y" : "N");
   PrintFormat("Rules: ZoneTap=%s WindowOnly=%s TapsInWin=%s OneTradeDay=%s PartialClose=%.0f%% MoveSL→BE=%s",
               InpRequireZoneTap   ? "Y" : "N", InpWindowOnly   ? "Y" : "N",
               InpZoneTapsInWindow ? "Y" : "N", InpOneTradePerDay ? "Y" : "N",
               InpPartialClosePct, InpMoveSLToBEOnTP1 ? "Y" : "N");
   if(g_dailyProfitTaken)
      PrintFormat("Daily lockout RESTORED from %s — no new entries today.", g_persistFile);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_hEMA8  != INVALID_HANDLE) IndicatorRelease(g_hEMA8);
   if(g_hEMA20 != INVALID_HANDLE) IndicatorRelease(g_hEMA20);
  }

//============================ TICK ROUTER ==========================
// Two cadences:
//   • Per-tick — manage TP1 partial-close + BE move on the live position.
//   • Per-new-bar — daily reset, HTF state update, signal evaluation,
//                   pending-order placement / cancellation.
void OnTick()
  {
   // Live-position management runs every tick — TP1 may be touched mid-bar
   // and we want to react before the broker's TP=tp2 takes the whole lot.
   ManageLivePosition();

   datetime nowBar = (datetime)iTime(_Symbol, _Period, 0);
   if(nowBar == g_lastBarTime) return;
   g_lastBarTime = nowBar;
   OnNewBar();
  }

//============================ NEW-BAR PIPELINE =====================
void OnNewBar()
  {
   // 1) Daily reset (broker-server day rollover detection).
   datetime today = BrokerDayStart(TimeCurrent());
   if(today != g_currentBrokerDay)
     {
      g_currentBrokerDay = today;
      g_stepTwoMet  = false;
      g_stepTwoBias = 0;
      g_dailyProfitTaken = false;
      SaveDailyLockState();
      if(InpVerboseLog) Print("Daily reset — Step2 cleared, lockout cleared.");
     }

   // 2) Update HTF zone state (lock/unlock, sticky-touch, rollover).
   UpdateZoneState();

   // 3) If we already have a live position, skip new-signal evaluation.
   //    Triggered+managed positions don't get new pending orders stacked.
   if(HasLivePosition()) return;

   // 4) If a pending stop-order is still open (rolled over from prior bar),
   //    delete it. Pine's "Active → Invalid" rule = pending lives for ONE
   //    chart-TF bar only.
   CancelOurPendingOrders();

   // 5) Daily lockout — no new entries after 1:1 secured.
   if(InpOneTradePerDay && g_dailyProfitTaken) return;

   // 6) Spread filter.
   if(InpMaxSpreadPips > 0)
     {
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double sp  = (ask - bid) / g_pip;
      if(sp > InpMaxSpreadPips)
        {
         if(InpVerboseLog) PrintFormat("Skip: spread %.1f pips > max %.1f", sp, InpMaxSpreadPips);
         return;
        }
     }

   // 7) Compute Step-1 bias and Step-2 zone-tap state.
   int bias6[6];
   double htfO[6], htfH[6], htfL[6], htfC[6];
   if(!FetchHTFData(htfO, htfH, htfL, htfC, bias6)) return;

   int sumBias = bias6[0] + bias6[1] + bias6[2] + bias6[3] + bias6[4] + bias6[5];
   int overallBias = (sumBias >=  2) ? 1 : (sumBias <= -2) ? -1 : 0;

   // 8) Update step-2 from any newly-touched signal-eligible zone.
   bool inWindow = IsInTradingWindow();
   bool tapInWindow = InpZoneTapsInWindow ? inWindow : true;
   bool sigTouchAny = false;
   for(int z = 0; z < 5; z++)         // 5 = 4H..D, exclude weekly
      if(g_dashStk[z]) { sigTouchAny = true; break; }
   if(sigTouchAny && overallBias != 0 && tapInWindow)
     {
      g_stepTwoMet  = true;
      g_stepTwoBias = overallBias;
     }
   bool anyDashSignalable = sigTouchAny;
   if(g_stepTwoMet && !anyDashSignalable)
     {
      g_stepTwoMet = false;
      g_stepTwoBias = 0;
     }

   // 9) Step-3: EM1 detection on the just-closed chart bar.
   bool em1Buy=false, em1Sell=false;
   DetectEM1(em1Buy, em1Sell, overallBias, inWindow);
   if(!em1Buy && !em1Sell) return;
   if(em1Buy  && !InpEnableLong)  return;
   if(em1Sell && !InpEnableShort) return;

   // 10) System gate.
   bool stepTwoValid = InpRequireZoneTap
                       ? (g_stepTwoMet && g_stepTwoBias == overallBias && overallBias != 0 && anyDashSignalable)
                       : (overallBias != 0);
   if(!stepTwoValid) return;

   // 11) FIRE — compute V8 entry/SL/TP1/TP2 from bar-1 high/low and place
   //     a stop pending order with 1-bar expiration.
   FireSignal(em1Buy);
  }

//============================ HTF / BIAS / WINDOW ==================
// Returns prior-bar (shift=1) OHLC of the six monitored TFs and each
// candle's direction (+1 bullish / -1 bearish / 0 doji).
// 1:1 mapping with Pine's request.security(... [open[1], close[1], ...]).
bool FetchHTFData(double &op[], double &hi[], double &lo[], double &cl[], int &bias[])
  {
   ENUM_TIMEFRAMES tfs[6] = { PERIOD_H4, PERIOD_H6, PERIOD_H8, PERIOD_H12, PERIOD_D1, PERIOD_W1 };
   ArrayResize(op, 6); ArrayResize(hi, 6); ArrayResize(lo, 6); ArrayResize(cl, 6); ArrayResize(bias, 6);
   for(int i = 0; i < 6; i++)
     {
      op[i] = iOpen (_Symbol, tfs[i], 1);
      hi[i] = iHigh (_Symbol, tfs[i], 1);
      lo[i] = iLow  (_Symbol, tfs[i], 1);
      cl[i] = iClose(_Symbol, tfs[i], 1);
      if(op[i] <= 0 || cl[i] <= 0 || hi[i] <= 0 || lo[i] <= 0)
        {
         if(InpVerboseLog)
            PrintFormat("HTF data not ready (TF=%s shift=1) — wait.", EnumToString(tfs[i]));
         return false;
        }
      bias[i] = (cl[i] > op[i]) ? 1 : (cl[i] < op[i]) ? -1 : 0;
     }
   return true;
  }

// V8 trading window: H4 candles 3-5 of the broker day. We compute the H4
// index of the currently-forming chart bar directly instead of running
// Pine's running counter. Same result, less state.
bool IsInTradingWindow()
  {
   if(!InpWindowOnly) return true;
   datetime barOpen = (datetime)iTime(_Symbol, _Period, 0);
   if(barOpen == 0) return false;
   datetime dayStart = BrokerDayStart(barOpen);
   long secondsIntoDay = (long)(barOpen - dayStart);
   int h4Index = (int)(secondsIntoDay / (4 * 3600)); // 0..5
   // Pine 1-indexed [3,5] == zero-indexed [2,4] == 08:00 to 20:00 broker time.
   return (h4Index >= 2 && h4Index <= 4) && (PeriodSeconds(_Period) <= 4 * 3600);
  }

// Broker-server midnight of the day containing 't'.
datetime BrokerDayStart(datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
  }

//============================ DISCOUNT ZONES =======================
// Fib 50%-75% of the prior HTF candle's range, sloped by candle direction.
// Identical to Pine's f_discountZone. zt = top, zb = bottom.
void DiscountZone(double lo, double hi, int candleBias, double &zt, double &zb)
  {
   zt = 0.0; zb = 0.0;
   double rng = hi - lo;
   if(rng <= 0) return;
   if(candleBias == 1)
     {
      zt = hi - 0.5  * rng;
      zb = hi - 0.75 * rng;
     }
   else if(candleBias == -1)
     {
      zb = lo + 0.5  * rng;
      zt = lo + 0.75 * rng;
     }
  }

// Update the six per-TF zone trackers (lock, sticky-touch, rollover) and
// fold the result into the dashboard sticky-flag array g_dashStk[].
void UpdateZoneState()
  {
   ENUM_TIMEFRAMES tfs[6] = { PERIOD_H4, PERIOD_H6, PERIOD_H8, PERIOD_H12, PERIOD_D1, PERIOD_W1 };
   double op[6], hi[6], lo[6], cl[6];
   int bias[6];
   if(!FetchHTFData(op, hi, lo, cl, bias))
      return;

   int sumBias = bias[0] + bias[1] + bias[2] + bias[3] + bias[4] + bias[5];
   int overallBias = (sumBias >=  2) ? 1 : (sumBias <= -2) ? -1 : 0;

   // Touch detection uses the just-closed bar's range (shift=1) — by the
   // time OnNewBar fires, bar 0 has just opened and has zero range, so we
   // cannot use it for the same-bar touch test Pine performs at bar close.
   double curHigh = iHigh(_Symbol, _Period, 1);
   double curLow  = iLow (_Symbol, _Period, 1);
   double cl1     = iClose(_Symbol, _Period, 1);
   double cl2     = iClose(_Symbol, _Period, 2);

   for(int i = 0; i < 6; i++)
     {
      datetime htfOpen = (datetime)iTime(_Symbol, tfs[i], 0);
      bool newCandle = (htfOpen != g_lastHTFOpen[i]);
      g_lastHTFOpen[i] = htfOpen;

      double zt, zb;
      DiscountZone(lo[i], hi[i], bias[i], zt, zb);

      // Rollover on either: new HTF candle OR the computed zone moved
      // (matches Pine's ta.change()-based detection).
      bool zoneChanged = (MathAbs(zt - g_lastZT[i]) > _Point * 0.5) ||
                         (MathAbs(zb - g_lastZB[i]) > _Point * 0.5);
      if(newCandle || zoneChanged)
        {
         g_locked[i]  = false;
         g_dashStk[i] = false;
        }
      g_lastZT[i] = zt;
      g_lastZB[i] = zb;

      // Invalidation: chart-TF closes [2] AND [1] both beyond the zone in
      // bias-against direction (uses chart timeframe, same as Pine).
      // Skip if cl1/cl2 are not yet populated (early-history guard).
      if(zt > 0 && zb > 0 && cl1 > 0 && cl2 > 0)
        {
         double upper = MathMax(zt, zb);
         double lower = MathMin(zt, zb);
         if(bias[i] == 1 && cl1 < lower && cl2 < lower)
           {
            g_locked[i]  = true;
            g_dashStk[i] = false;
           }
         if(bias[i] == -1 && cl1 > upper && cl2 > upper)
           {
            g_locked[i]  = true;
            g_dashStk[i] = false;
           }
        }

      // bias-aligned + not-locked predicate (Pine's m_*).
      bool matches = (overallBias != 0 && bias[i] == overallBias && !g_locked[i]);

      // Touch this bar — sticky-on while bias-aligned.
      if(matches && zt > 0 && zb > 0)
        {
         double upper = MathMax(zt, zb);
         double lower = MathMin(zt, zb);
         if(curLow <= upper && curHigh >= lower)
            g_dashStk[i] = true;
        }
      // Bias mismatch / lock immediately clears the sticky flag.
      if(!matches)
         g_dashStk[i] = false;
     }
  }

//============================ EM1 PATTERN DETECTION ================
// 3-candle reversal on closed chart bars [3]→[2]→[1] with EMA8/EMA20
// slope confirmation. Direct port of Pine §9.
//
// Buy: bearish[3] → bullish[2] → bullish[1] with HH+HL on [1] vs [2]
//      AND pct_change > 0.006 (EMA8 above EMA20)
// Sell mirror.
void DetectEM1(bool &buy, bool &sell, int overallBias, bool inWindow)
  {
   buy = false; sell = false;

   double o1 = iOpen (_Symbol, _Period, 1), c1 = iClose(_Symbol, _Period, 1);
   double o2 = iOpen (_Symbol, _Period, 2), c2 = iClose(_Symbol, _Period, 2);
   double o3 = iOpen (_Symbol, _Period, 3), c3 = iClose(_Symbol, _Period, 3);
   double h1 = iHigh (_Symbol, _Period, 1), h2 = iHigh(_Symbol, _Period, 2);
   double l1 = iLow  (_Symbol, _Period, 1), l2 = iLow (_Symbol, _Period, 2);
   if(o1 <= 0 || o2 <= 0 || o3 <= 0) return;

   // EMA slope filter — replicate Pine's pct_change exactly. Read EMA at
   // shift=1 (the just-closed bar — what Pine's [1] references).
   double bufE8[1], bufE20[1];
   if(CopyBuffer(g_hEMA8,  0, 1, 1, bufE8)  <= 0) return;
   if(CopyBuffer(g_hEMA20, 0, 1, 1, bufE20) <= 0) return;
   double e8  = bufE8[0];
   double e20 = bufE20[0];
   double trendAvg  = (e8 + e20) * 0.5;
   if(trendAvg == 0.0) return;
   double pctChange = 100.0 * (e8 - e20) / trendAvg;

   // V8 asset-class filter (mirrors filt_common_*):
   //   • Non-XAU/XAG charts must be on TF >= 15min.
   //   • XAU/XAG charts on sub-15min TF additionally require H4 candle
   //     direction to match (mult >= 0 for buy, <= 0 for sell).
   int    tfMin    = PeriodSeconds(_Period) / 60;
   bool   xauxag   = (g_isXAU || g_isXAG);
   bool   intradayTF = (PeriodSeconds(_Period) < PeriodSeconds(PERIOD_D1)) &&
                       (xauxag || tfMin >= 15);
   if(!intradayTF) return;

   bool windowOk = inWindow || !InpWindowOnly;
   if(!windowOk) return;

   double op4h = iOpen (_Symbol, PERIOD_H4, 1);
   double cl4h = iClose(_Symbol, PERIOD_H4, 1);
   int    mult = (cl4h > op4h) ? 1 : (cl4h < op4h) ? -1 : 0;

   bool buLTF_X = xauxag && tfMin < 15;
   bool beLTF_X = xauxag && tfMin < 15;

   bool fcb = (overallBias ==  1) && (!buLTF_X || mult >= 0);
   bool fcs = (overallBias == -1) && (!beLTF_X || mult <= 0);

   if(fcb)
     {
      bool b1 = c3 < o3;            // bar [3] bearish
      bool b2 = c2 > o2;            // bar [2] bullish
      bool b3 = c1 > o1;            // bar [1] bullish
      bool b4 = h1 > h2 && l1 > l2; // HH+HL on [1] vs [2]
      buy = b1 && b2 && b3 && b4 && pctChange > 0.006;
     }
   if(fcs)
     {
      bool s1 = c3 > o3;
      bool s2 = c2 < o2;
      bool s3 = c1 < o1;
      bool s4 = l1 < l2 && h1 < h2;
      sell = s1 && s2 && s3 && s4 && pctChange < -0.006;
     }
  }

//============================ SIGNAL FIRE ==========================
// Compute V8's entry/SL/TP1/TP2 from bar-1 high/low and place a stop
// pending order with expiration = open of the bar AFTER the current bar.
// That mirrors Pine's "Active for 1 bar then Invalid" lifecycle exactly:
// the order is alive only while the current chart bar is forming.
void FireSignal(bool isBuy)
  {
   double h1 = iHigh(_Symbol, _Period, 1);
   double l1 = iLow (_Symbol, _Period, 1);

   double sp = g_spreadTick;
   double entry, sl;
   if(isBuy)
     {
      entry = NormalizeDouble(h1 + InpSpreadBufferPips * sp, g_digits);
      sl    = NormalizeDouble(l1 - 3.0 * sp,                 g_digits);
     }
   else
     {
      entry = NormalizeDouble(l1 - InpSpreadBufferPips * sp, g_digits);
      sl    = NormalizeDouble(h1 + 3.0 * sp,                 g_digits);
     }
   if(MathAbs(entry - sl) <= 0)
     {
      if(InpVerboseLog) Print("FireSignal: degenerate entry/SL distance, skipped.");
      return;
     }

   ENUM_ORDER_TYPE type = isBuy ? ORDER_TYPE_BUY_STOP : ORDER_TYPE_SELL_STOP;
   if(!ApplyBrokerStopConstraints(type, entry, sl)) return;

   double tp1 = NormalizeDouble(2.0 * entry - sl,           g_digits);
   double tp2 = NormalizeDouble(3.0 * entry - 2.0 * sl,     g_digits);

   double slDist = MathAbs(entry - sl);
   double slPips = slDist / g_pip;
   if(slPips <= 0) return;
   double lot = CalcLotSize(slPips);
   if(lot <= 0) return;

   // Pine's "Active for 1 bar" → order expires when the next chart bar opens.
   datetime barOpen   = (datetime)iTime(_Symbol, _Period, 0);
   datetime expireAt  = barOpen + (datetime)PeriodSeconds(_Period);

   bool ok = false;
   if(isBuy)
      ok = trade.BuyStop (lot, entry, _Symbol, sl, tp2, ORDER_TIME_SPECIFIED, expireAt, InpComment);
   else
      ok = trade.SellStop(lot, entry, _Symbol, sl, tp2, ORDER_TIME_SPECIFIED, expireAt, InpComment);

   if(!ok)
     {
      PrintFormat("Pending failed: %d %s — entry=%.*f sl=%.*f tp2=%.*f lot=%.2f",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription(),
                  g_digits, entry, g_digits, sl, g_digits, tp2, lot);
      return;
     }

   // Mirror trade state so OnTick can manage TP1 once the position fills.
   g_trade.dir     = isBuy ? 1 : -1;
   g_trade.entry   = entry;
   g_trade.sl      = sl;
   g_trade.tp1     = tp1;
   g_trade.tp2     = tp2;
   g_trade.barTime = barOpen;
   g_trade.tp1hit  = false;

   PrintFormat("V8 %s SIGNAL — lot=%.2f entry=%.*f SL=%.*f TP1=%.*f TP2=%.*f slPips=%.1f exp=%s",
               isBuy ? "BUY" : "SELL", lot,
               g_digits, entry, g_digits, sl, g_digits, tp1, g_digits, tp2,
               slPips, TimeToString(expireAt, TIME_DATE | TIME_MINUTES));
  }

//============================ POSITION MANAGEMENT ==================
// Per-tick management of the live position:
//  1) Detect TP1 first-touch → partial-close InpPartialClosePct AND move
//     SL to entry (break-even).
//  2) On TP1 hit → set g_dailyProfitTaken (the "1 trade after 1:1" rule).
//  3) TP2 and SL exits are handled natively by the broker (TP=tp2 set on
//     position) — we just observe completion via PositionsTotal == 0 and
//     log it.
// The broker's TP=tp2 stays unchanged through TP1; only SL moves to BE.
void ManageLivePosition()
  {
   if(g_trade.dir == 0) return;             // no live state to manage
   if(!HasLivePosition())                   // position closed (TP2 / SL hit)
     {
      if(InpVerboseLog)
         PrintFormat("Position closed (TP2 or SL) — bias=%s tp1hit=%s",
                     g_trade.dir == 1 ? "BUY" : "SELL",
                     g_trade.tp1hit ? "Y" : "N");
      ResetTradeState();
      return;
     }

   if(g_trade.tp1hit) return;               // already split + BE'd

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   bool hitTP1 = false;
   if(g_trade.dir == 1)                     // long: bid must reach tp1
      hitTP1 = (bid >= g_trade.tp1);
   else                                     // short: ask must reach tp1
      hitTP1 = (ask <= g_trade.tp1);

   if(!hitTP1) return;

   // Partial close (rounded down to volume step). Skip if 0% selected.
   if(InpPartialClosePct > 0.0 && InpPartialClosePct < 100.0)
     {
      double curVol = SelectOurPositionVolume();
      double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
      double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      if(step <= 0) step = 0.01;
      double partial = curVol * (InpPartialClosePct / 100.0);
      partial = MathFloor(partial / step) * step;
      // If after step-flooring we'd close all OR less than min lot, skip
      // the partial and just move SL to BE — better than blowing out the
      // whole position by accident on a small starting lot.
      if(partial >= minLot && (curVol - partial) >= minLot)
        {
         ulong tk = SelectOurPositionTicket();
         if(tk != 0 && trade.PositionClosePartial(tk, partial))
            PrintFormat("TP1 partial close: %.2f of %.2f at %.*f",
                        partial, curVol, g_digits, g_trade.tp1);
         else if(tk != 0)
            PrintFormat("TP1 partial close FAILED: %d %s",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
      else if(InpVerboseLog)
        {
         PrintFormat("TP1: partial %.2f (of %.2f) below min/step constraints — BE only.",
                     partial, curVol);
        }
     }

   // Move SL to break-even (entry). Keep TP at tp2 unchanged.
   if(InpMoveSLToBEOnTP1)
     {
      ulong tk = SelectOurPositionTicket();
      if(tk != 0)
        {
         double newSL = NormalizeDouble(g_trade.entry, g_digits);
         double curTP = posInfo.TakeProfit();   // already populated by SelectOurPositionTicket
         if(!trade.PositionModify(tk, newSL, curTP))
            PrintFormat("BE move FAILED: %d %s",
                        trade.ResultRetcode(), trade.ResultRetcodeDescription());
         else
            PrintFormat("SL → BE at entry %.*f (TP unchanged %.*f)",
                        g_digits, newSL, g_digits, curTP);
        }
     }

   g_trade.tp1hit = true;

   // 1-trade-per-day rule: TP1 hit = day done.
   if(InpOneTradePerDay)
     {
      g_dailyProfitTaken = true;
      SaveDailyLockState();
      if(InpVerboseLog) Print("1:1 secured — daily lockout engaged.");
     }
  }

//============================ POSITION HELPERS =====================
bool HasLivePosition()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
         return true;
     }
   return false;
  }

ulong SelectOurPositionTicket()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic)
         return posInfo.Ticket();
     }
   return 0;
  }

double SelectOurPositionVolume()
  {
   if(SelectOurPositionTicket() == 0) return 0.0;
   return posInfo.Volume();
  }

void ResetTradeState()
  {
   g_trade.dir     = 0;
   g_trade.entry   = 0.0;
   g_trade.sl      = 0.0;
   g_trade.tp1     = 0.0;
   g_trade.tp2     = 0.0;
   g_trade.barTime = 0;
   g_trade.tp1hit  = false;
  }

// On EA reload mid-trade: rebuild g_trade from broker state. tp2 = position
// TP, entry = position open, sl = position SL. tp1 = (entry+tp2)/2 because
// V8's geometry guarantees TP2-entry = 2*(entry-sl) → tp1 = midpoint.
// If SL is already at entry, infer tp1hit=true (BE move already happened).
void ReattachToLivePosition()
  {
   if(!HasLivePosition()) return;
   ulong tk = SelectOurPositionTicket();
   if(tk == 0) return;
   double openP = posInfo.PriceOpen();
   double slP   = posInfo.StopLoss();
   double tpP   = posInfo.TakeProfit();
   long ptype = posInfo.PositionType();
   int dir = (ptype == POSITION_TYPE_BUY) ? 1 : -1;

   g_trade.dir     = dir;
   g_trade.entry   = openP;
   g_trade.sl      = slP;
   g_trade.tp2     = tpP;
   g_trade.tp1     = (openP + tpP) * 0.5;
   g_trade.barTime = (datetime)posInfo.Time();
   // SL == entry within a tick → BE move already happened on prior session.
   g_trade.tp1hit  = (MathAbs(slP - openP) < SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 1.5);
   PrintFormat("Reattached to live position #%I64u dir=%s entry=%.*f sl=%.*f tp2=%.*f tp1hit=%s",
               tk, dir == 1 ? "BUY" : "SELL",
               g_digits, openP, g_digits, slP, g_digits, tpP,
               g_trade.tp1hit ? "Y" : "N");
  }

void CancelOurPendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!ordInfo.SelectByIndex(i)) continue;
      if(ordInfo.Symbol() != _Symbol) continue;
      if(ordInfo.Magic()  != InpMagic) continue;
      ulong tk = ordInfo.Ticket();
      if(trade.OrderDelete(tk))
        {
         if(InpVerboseLog) PrintFormat("Pending #%I64u cancelled (bar rolled).", tk);
        }
     }
   // No live pending → clear mirror state so a fresh signal can be evaluated.
   if(!HasLivePosition()) ResetTradeState();
  }

//============================ STOPS / LOTS =========================
// Bring price+sl onto the broker-allowed side of SYMBOL_TRADE_STOPS_LEVEL.
// Same pattern as OneMinuteScalper.
bool ApplyBrokerStopConstraints(ENUM_ORDER_TYPE type, double &price, double &sl)
  {
   long stopsLvlPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double pt   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD = stopsLvlPts * pt;

   if(type == ORDER_TYPE_BUY_STOP)
     {
      if(price < ask + minD) price = NormalizeDouble(ask + minD + pt, g_digits);
      if(price - sl < minD)  sl    = NormalizeDouble(price - minD - pt, g_digits);
     }
   else if(type == ORDER_TYPE_SELL_STOP)
     {
      if(price > bid - minD) price = NormalizeDouble(bid - minD - pt, g_digits);
      if(sl - price < minD)  sl    = NormalizeDouble(price + minD + pt, g_digits);
     }
   return true;
  }

double CalcLotSize(double slPips)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = 0.01;

   double lot = InpFixedLot;
   if(InpLotMode == LOT_RISK_PERCENT)
     {
      double equity    = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskMoney = equity * InpRiskPercent / 100.0;
      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize <= 0 || tickValue <= 0 || slPips <= 0) return 0.0;
      double moneyPerPipPerLot = tickValue * (g_pip / tickSize);
      if(moneyPerPipPerLot <= 0) return 0.0;
      lot = riskMoney / (slPips * moneyPerPipPerLot);
     }

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));
   int volDigits = (stepLot >= 1.0) ? 0 : (stepLot >= 0.1 ? 1 : 2);
   return NormalizeDouble(lot, volDigits);
  }

//============================ DAILY-LOCKOUT PERSISTENCE ============
// One-line CSV: "<YYYY-MM-DD>,<0|1>".
// File path: <Terminal>\MQL5\Files\DTG_V8_<symbol>_<magic>.csv
// Skipped under tester (each tester run starts fresh anyway).
void LoadDailyLockState()
  {
   if(MQLInfoInteger(MQL_TESTER)) return;
   if(!FileIsExist(g_persistFile)) return;
   int h = FileOpen(g_persistFile, FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE) return;
   string line = FileReadString(h);
   FileClose(h);
   string parts[];
   if(StringSplit(line, ',', parts) != 2) return;
   string storedDay = parts[0];
   int    storedFlag = (int)StringToInteger(parts[1]);
   string today = TimeToString(g_currentBrokerDay, TIME_DATE);  // "yyyy.mm.dd"
   StringReplace(today, ".", "-");                              // → "yyyy-mm-dd"
   if(storedDay == today && storedFlag == 1)
      g_dailyProfitTaken = true;
  }

void SaveDailyLockState()
  {
   if(MQLInfoInteger(MQL_TESTER)) return;
   int h = FileOpen(g_persistFile, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      PrintFormat("Daily-lock persist FAILED: cannot open %s (err=%d)", g_persistFile, GetLastError());
      return;
     }
   string today = TimeToString(g_currentBrokerDay, TIME_DATE);
   StringReplace(today, ".", "-");
   FileWriteString(h, StringFormat("%s,%d", today, g_dailyProfitTaken ? 1 : 0));
   FileClose(h);
  }
//+------------------------------------------------------------------+
