//+------------------------------------------------------------------+
//|                                          OneMinuteScalper.mq5    |
//|                                                              DTG |
//|       1-minute candle breakout scalper with break-even + trail   |
//+------------------------------------------------------------------+
#property copyright "DTG"
#property link      ""
#property version   "1.00"
#property strict
#property description "Enters a stop order at the previous M1 candle high/low based"
#property description "on whether the candle closed bullish or bearish. Uses an initial"
#property description "stop loss beyond the signal candle, then breakeven and trailing."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//--- Enumerations
enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed lot
   LOT_RISK_PERCENT = 1  // % risk of equity per trade
  };

enum ENUM_SL_MODE
  {
   SL_CANDLE_EXTREME = 0, // Stop loss at signal-candle low/high (+ buffer)
   SL_FIXED_PIPS     = 1  // Fixed pip stop loss
  };

enum ENUM_TRAIL_MODE
  {
   TRAIL_FIXED_PIPS = 0, // Trail at a fixed pip distance behind price
   TRAIL_ATR        = 1  // Trail at ATR * multiplier (adapts to volatility)
  };

//--- Strategy inputs
// Defaults below are tuned for XAUUSD (gold) on M1 and for backtesting.
// For EURUSD / FX use the FX profile in README.md.
// Daily limits are 0 by default (off) so backtests aren't halted; set them
// back to 1.0 / 2.0 (or your own values) when going to demo / live.
input group                "=== Strategy ==="
input bool                 InpTradeBullish        = true;   // Trade bullish setups (buy stop)
input bool                 InpTradeBearish        = true;   // Trade bearish setups (sell stop)
input double               InpEntryBufferPips     = 1.0;    // Entry buffer beyond candle (pips)
input bool                 InpUsePendingExpiry    = true;   // Cancel pending if not filled fast
input int                  InpPendingExpirySec    = 60;     // Pending order expiry (seconds)
input double               InpMinCandleSizePips   = 5.0;    // Minimum signal candle range (pips)
input double               InpMaxCandleSizePips   = 0;      // Maximum signal candle range (pips, 0 = off)
input double               InpMaxSpreadPips       = 10;     // Max allowed spread (pips, 0 = off) — protects against gap-open spread blowups

//--- Stop loss / Take profit
// SL_FIXED_PIPS is the recommended default for gold: every trade gets a
// predictable tight SL regardless of how wide the signal candle was, so
// no signals are rejected for being "too wide" and lot sizing is stable.
// Switch to SL_CANDLE_EXTREME if you want SL parked just past the signal
// candle's opposite extreme (more natural on tighter FX pairs).
input group                "=== Stop Loss / Take Profit ==="
input ENUM_SL_MODE         InpSLMode              = SL_FIXED_PIPS;     // Stop loss mode
input double               InpSLFixedPips         = 12.0;   // Fixed SL (pips), used in SL_FIXED_PIPS mode
input double               InpSLBufferPips        = 0.5;    // SL buffer beyond candle extreme (pips, used in SL_CANDLE_EXTREME mode)
input double               InpMinSLPips           = 5.0;    // Minimum acceptable SL distance (pips)
input double               InpMaxSLPips           = 0;      // Max acceptable SL distance (pips, 0 = off)
input double               InpTakeProfitPips      = 0.0;    // Take profit (pips, 0 = none / let trail close)

//--- Exit logic
// Primary exit is "opposite candle close": stay in the trade as long as
// each new M1 candle closes in your direction; close at market on the first
// opposite-direction close. Optional partial close locks in some profit at
// a fixed pip milestone before the rest of the position rides the trend.
input group                "=== Exit Logic ==="
input bool                 InpExitOnOppositeCandle = true;  // Close on first opposite-direction M1 candle close
input double               InpPartialProfitPips    = 0;     // Pips of profit to trigger partial close (0 = off)
input double               InpPartialClosePct      = 30;    // % of position to close at the partial milestone

//--- Break-even & trailing (off by default — opposite-candle is the exit)
// Both BE and trailing are gated by their *Trigger / *Start values being > 0.
// Set them to non-zero to layer them on top of the opposite-candle exit.
input group                "=== Break-even & Trailing (optional) ==="
input double               InpBreakevenTriggerPips = 0;     // Move SL to BE after this profit (pips, 0 = off)
input double               InpBreakevenBufferPips  = 1.0;   // Lock-in pips at break-even
input ENUM_TRAIL_MODE      InpTrailMode            = TRAIL_ATR; // How to trail the stop
input double               InpTrailStartPips       = 0;     // [FIXED mode] Start trailing (pips, 0 = off)
input double               InpTrailDistancePips    = 15.0;  // [FIXED mode] Trail distance behind price (pips)
input ENUM_TIMEFRAMES      InpATRTimeframe         = PERIOD_M5; // [ATR mode] Timeframe for ATR
input int                  InpATRPeriod            = 14;    // [ATR mode] ATR period
input double               InpATRTrailStartMult    = 0;     // [ATR mode] Start trailing (ATR mult, 0 = off)
input double               InpATRTrailDistMult     = 2.0;   // [ATR mode] Trail distance = ATR * this

//--- Money management
input group                "=== Money Management ==="
input ENUM_LOT_MODE        InpLotMode              = LOT_RISK_PERCENT; // Lot sizing mode
input double               InpFixedLot             = 0.01;  // Fixed lot size
input double               InpRiskPercent          = 0.05;  // Risk % per trade
input int                  InpMaxOpenPositions     = 1;     // Max simultaneous positions

//--- Daily limits
// When a limit is hit: pendings are cancelled. If InpCloseAllOnDailyHalt is
// true, all open positions are also closed immediately. New trades are then
// halted until the next server day rolls over.
// Both limits default to 0 (off) — the EA runs continuously. Set them to
// non-zero to re-enable.
input group                "=== Daily Limits ==="
input double               InpDailyProfitTarget    = 0;     // Halt + flatten after +X% (0 = off)
input double               InpDailyLossLimit       = 0;     // Halt + flatten after -X% (0 = off)
input bool                 InpCloseAllOnDailyHalt  = true;  // Close open positions when a daily limit is hit

//--- Session filter
// Defaults below = New York equity session in GMT:
//   13:30 GMT - 20:00 GMT during US daylight time (Mar - early Nov)
//   Add 1 hour outside DST (14:30 - 21:00 GMT) — see README.
// IMPORTANT: in the Strategy Tester, TimeGMT() is unreliable. The EA
// instead computes GMT as: GMT = TimeCurrent() - InpBrokerGMTOffset * 3600.
// Set InpBrokerGMTOffset to your broker's server offset from GMT in hours
// (e.g. 3 for GMT+3, common for Exness / IC Markets / FBS in summer).
// You can find your broker's offset in their MT5 server name (e.g.
// "Exness-MT5Real6" runs on GMT+3 in EEST), or by comparing the time at
// the top-right of MT5 to your local clock.
input group                "=== Session Filter ==="
input bool                 InpUseSessionFilter     = false; // Restrict to a trading window
input bool                 InpSessionUseGMT        = true;  // true = times below are GMT; false = broker server time
input int                  InpBrokerGMTOffset      = 3;     // Broker server's GMT offset in hours (only used when InpSessionUseGMT=true)
input int                  InpStartHour            = 13;    // Start hour
input int                  InpStartMinute          = 30;    // Start minute
input int                  InpEndHour              = 20;    // End hour
input int                  InpEndMinute            = 0;     // End minute

//--- Misc
input group                "=== Misc ==="
input long                 InpMagic                = 9001;  // Magic number
input string               InpComment              = "1mScalper"; // Trade comment
input bool                 InpVerboseLog           = true;  // Verbose logging

//--- Globals
CTrade        trade;
CPositionInfo posInfo;
COrderInfo    ordInfo;
CSymbolInfo   sym;

double   g_pip            = 0.0;   // pip size in price terms
int      g_digits         = 0;
datetime g_lastBarTime    = 0;
datetime g_currentDay     = 0;
double   g_dayStartEquity = 0.0;
bool     g_dailyHalt      = false;
int      g_atrHandle      = INVALID_HANDLE;
ulong    g_partialedTickets[];   // tickets that have already had their partial close fired

//+------------------------------------------------------------------+
//| Init / deinit                                                    |
//+------------------------------------------------------------------+
int OnInit()
  {
   if(!sym.Name(_Symbol))
     {
      Print("OneMinuteScalper: failed to bind symbol info");
      return(INIT_FAILED);
     }
   sym.RefreshRates();
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);

   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   // 1 pip = 10 points on 5/3-digit FX symbols, 1 pip = 1 point on 4/2-digit
   g_pip = (g_digits == 3 || g_digits == 5) ? point * 10.0 : point;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   g_atrHandle = iATR(_Symbol, InpATRTimeframe, InpATRPeriod);
   if(g_atrHandle == INVALID_HANDLE)
     {
      Print("OneMinuteScalper: failed to create ATR indicator handle");
      return(INIT_FAILED);
     }

   g_currentDay     = 0;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dailyHalt      = false;
   g_lastBarTime    = (datetime)iTime(_Symbol, PERIOD_M1, 0);

   PrintFormat("OneMinuteScalper init: digits=%d pip=%.*f magic=%I64d build=2026-05-08-v2",
               g_digits, g_digits, g_pip, InpMagic);
   PrintFormat("Inputs A: RiskPct=%.4f FixedLot=%.2f LotMode=%d MaxOpenPos=%d",
               InpRiskPercent, InpFixedLot, (int)InpLotMode, InpMaxOpenPositions);
   PrintFormat("Inputs B: DailyProfit=%.4f DailyLoss=%.4f CloseAllOnHalt=%s",
               InpDailyProfitTarget, InpDailyLossLimit,
               InpCloseAllOnDailyHalt ? "true" : "false");
   PrintFormat("Inputs C: MaxSpread=%.1f MinCandle=%.1f SLMode=%d SLFixed=%.1f",
               InpMaxSpreadPips, InpMinCandleSizePips,
               (int)InpSLMode, InpSLFixedPips);
   PrintFormat("Inputs D: ExitOnOpp=%s SessionFilter=%s BE=%.1f TrailStart=%.1f ATRStartMult=%.2f",
               InpExitOnOppositeCandle ? "true" : "false",
               InpUseSessionFilter     ? "true" : "false",
               InpBreakevenTriggerPips, InpTrailStartPips, InpATRTrailStartMult);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   if(g_atrHandle != INVALID_HANDLE)
     {
      IndicatorRelease(g_atrHandle);
      g_atrHandle = INVALID_HANDLE;
     }
  }

//+------------------------------------------------------------------+
//| Read the most recent completed ATR value (price units)           |
//+------------------------------------------------------------------+
double GetCurrentATR()
  {
   if(g_atrHandle == INVALID_HANDLE) return 0.0;
   double buf[];
   // Index 1 = last completed bar's ATR (more stable than the live forming bar)
   if(CopyBuffer(g_atrHandle, 0, 1, 1, buf) <= 0) return 0.0;
   return buf[0];
  }

//+------------------------------------------------------------------+
//| Tick handler                                                     |
//+------------------------------------------------------------------+
void OnTick()
  {
   sym.RefreshRates();

   RolloverDayIfNeeded();
   CheckDailyLimits();
   ManageOpenPositions();

   datetime barTime = (datetime)iTime(_Symbol, PERIOD_M1, 0);
   if(barTime != g_lastBarTime)
     {
      g_lastBarTime = barTime;
      OnNewM1Bar();
     }

   ExpirePendingOrders();
  }

//+------------------------------------------------------------------+
//| Called once per fresh M1 bar open                                |
//+------------------------------------------------------------------+
void OnNewM1Bar()
  {
   if(g_dailyHalt) return;

   // Always cancel previous pending orders so we only chase the newest signal
   CancelOurPendingOrders();

   double op = iOpen (_Symbol, PERIOD_M1, 1);
   double cl = iClose(_Symbol, PERIOD_M1, 1);
   double hi = iHigh (_Symbol, PERIOD_M1, 1);
   double lo = iLow  (_Symbol, PERIOD_M1, 1);
   if(op <= 0 || cl <= 0 || hi <= 0 || lo <= 0) return;

   // Opposite-candle exit: if the just-closed candle's direction is against
   // any of our open positions, close them at market BEFORE we evaluate the
   // new signal. Runs even outside session so trades aren't stranded.
   if(InpExitOnOppositeCandle)
      ExitPositionsAgainstCandle(op, cl);

   if(!IsWithinSession()) return;
   if(CountOpenPositions() >= InpMaxOpenPositions) return;
   if(!IsSpreadAcceptable()) return;

   double rangePips = (hi - lo) / g_pip;
   if(rangePips < InpMinCandleSizePips) return;
   if(InpMaxCandleSizePips > 0 && rangePips > InpMaxCandleSizePips) return;

   if(cl > op && InpTradeBullish)
      PlaceBuyStop(hi, lo);
   else if(cl < op && InpTradeBearish)
      PlaceSellStop(lo, hi);
  }

//+------------------------------------------------------------------+
//| Close positions whose direction is opposite to the just-closed   |
//| M1 candle. Doji (open == close) → hold.                          |
//+------------------------------------------------------------------+
void ExitPositionsAgainstCandle(double candleOpen, double candleClose)
  {
   bool bearishClose = (candleClose < candleOpen);
   bool bullishClose = (candleClose > candleOpen);
   if(!bearishClose && !bullishClose) return;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic()  != InpMagic) continue;

      bool shouldClose = false;
      if(posInfo.PositionType() == POSITION_TYPE_BUY  && bearishClose) shouldClose = true;
      if(posInfo.PositionType() == POSITION_TYPE_SELL && bullishClose) shouldClose = true;
      if(!shouldClose) continue;

      ulong tk = posInfo.Ticket();
      if(InpVerboseLog)
        {
         PrintFormat("Exit %s on opposite-candle close (ticket %I64u)",
                     posInfo.PositionType() == POSITION_TYPE_BUY ? "BUY" : "SELL", tk);
        }
      if(!trade.PositionClose(tk))
        {
         PrintFormat("Close failed on ticket %I64u: %d %s",
                     tk, trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Place a Buy Stop above the signal candle high                    |
//+------------------------------------------------------------------+
void PlaceBuyStop(double signalHigh, double signalLow)
  {
   double price = NormalizeDouble(signalHigh + InpEntryBufferPips * g_pip, g_digits);

   double sl;
   if(InpSLMode == SL_CANDLE_EXTREME)
      sl = NormalizeDouble(signalLow - InpSLBufferPips * g_pip, g_digits);
   else
      sl = NormalizeDouble(price - InpSLFixedPips * g_pip, g_digits);

   double tp = (InpTakeProfitPips > 0)
               ? NormalizeDouble(price + InpTakeProfitPips * g_pip, g_digits)
               : 0.0;

   if(!ApplyBrokerStopConstraints(ORDER_TYPE_BUY_STOP, price, sl, tp)) return;

   double slDistPips = (price - sl) / g_pip;
   if(slDistPips < InpMinSLPips) return;
   if(InpMaxSLPips > 0 && slDistPips > InpMaxSLPips) return;

   double lot = CalcLotSize(slDistPips);
   if(lot <= 0) return;

   // Always use GTC; client-side ExpirePendingOrders() and the per-bar cancel
   // in OnNewM1Bar() handle expiry. Broker-side expiration timestamps are
   // rejected by some brokers (e.g. Exness) for sub-day expiries.
   if(!trade.BuyStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment))
     {
      if(InpVerboseLog)
         PrintFormat("BuyStop failed: %d %s",
                     trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
   else if(InpVerboseLog)
     {
      PrintFormat("BuyStop placed: lot=%.2f price=%.*f sl=%.*f tp=%.*f slPips=%.1f",
                  lot, g_digits, price, g_digits, sl, g_digits, tp, slDistPips);
     }
  }

//+------------------------------------------------------------------+
//| Place a Sell Stop below the signal candle low                    |
//+------------------------------------------------------------------+
void PlaceSellStop(double signalLow, double signalHigh)
  {
   double price = NormalizeDouble(signalLow - InpEntryBufferPips * g_pip, g_digits);

   double sl;
   if(InpSLMode == SL_CANDLE_EXTREME)
      sl = NormalizeDouble(signalHigh + InpSLBufferPips * g_pip, g_digits);
   else
      sl = NormalizeDouble(price + InpSLFixedPips * g_pip, g_digits);

   double tp = (InpTakeProfitPips > 0)
               ? NormalizeDouble(price - InpTakeProfitPips * g_pip, g_digits)
               : 0.0;

   if(!ApplyBrokerStopConstraints(ORDER_TYPE_SELL_STOP, price, sl, tp)) return;

   double slDistPips = (sl - price) / g_pip;
   if(slDistPips < InpMinSLPips) return;
   if(InpMaxSLPips > 0 && slDistPips > InpMaxSLPips) return;

   double lot = CalcLotSize(slDistPips);
   if(lot <= 0) return;

   if(!trade.SellStop(lot, price, _Symbol, sl, tp, ORDER_TIME_GTC, 0, InpComment))
     {
      if(InpVerboseLog)
         PrintFormat("SellStop failed: %d %s",
                     trade.ResultRetcode(), trade.ResultRetcodeDescription());
     }
   else if(InpVerboseLog)
     {
      PrintFormat("SellStop placed: lot=%.2f price=%.*f sl=%.*f tp=%.*f slPips=%.1f",
                  lot, g_digits, price, g_digits, sl, g_digits, tp, slDistPips);
     }
  }

//+------------------------------------------------------------------+
//| Adjust price/sl/tp so they respect broker stops level            |
//+------------------------------------------------------------------+
bool ApplyBrokerStopConstraints(ENUM_ORDER_TYPE type,
                                double &price, double &sl, double &tp)
  {
   long stopsLvlPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double pt   = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   double bid  = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask  = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double minD = stopsLvlPts * pt;

   if(type == ORDER_TYPE_BUY_STOP)
     {
      if(price < ask + minD) price = NormalizeDouble(ask + minD + pt, g_digits);
      if(sl > 0 && price - sl < minD) sl = NormalizeDouble(price - minD - pt, g_digits);
      if(tp > 0 && tp - price < minD) tp = NormalizeDouble(price + minD + pt, g_digits);
     }
   else if(type == ORDER_TYPE_SELL_STOP)
     {
      if(price > bid - minD) price = NormalizeDouble(bid - minD - pt, g_digits);
      if(sl > 0 && sl - price < minD) sl = NormalizeDouble(price + minD + pt, g_digits);
      if(tp > 0 && price - tp < minD) tp = NormalizeDouble(price - minD - pt, g_digits);
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Lot size calculator                                              |
//+------------------------------------------------------------------+
double CalcLotSize(double slPips)
  {
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0) stepLot = 0.01;

   double lot = InpFixedLot;
   if(InpLotMode == LOT_RISK_PERCENT)
     {
      double equity = AccountInfoDouble(ACCOUNT_EQUITY);
      double riskMoney = equity * InpRiskPercent / 100.0;

      double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
      double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
      if(tickSize <= 0 || tickValue <= 0)
         lot = InpFixedLot;
      else
        {
         double moneyPerPipPerLot = tickValue * (g_pip / tickSize);
         if(moneyPerPipPerLot <= 0 || slPips <= 0)
            lot = InpFixedLot;
         else
            lot = riskMoney / (slPips * moneyPerPipPerLot);
        }
     }

   lot = MathFloor(lot / stepLot) * stepLot;
   lot = MathMax(minLot, MathMin(maxLot, lot));

   // Normalize to typical 2 decimals (broker step rounding above is the source of truth)
   int volDigits = 2;
   if(stepLot >= 1.0)        volDigits = 0;
   else if(stepLot >= 0.1)   volDigits = 1;
   return NormalizeDouble(lot, volDigits);
  }

//+------------------------------------------------------------------+
//| Open positions management: BE + trailing                         |
//+------------------------------------------------------------------+
void ManageOpenPositions()
  {
   ProcessPartialCloses();

   double pt          = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stopsLvlPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist     = stopsLvlPts * pt;
   double bid         = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask         = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   // Compute trailing thresholds once per tick, in price units.
   // FIXED mode: use the *Pips inputs.
   // ATR mode:   use ATR * multipliers.
   double trailStartPrice = 0.0;
   double trailDistPrice  = 0.0;
   if(InpTrailMode == TRAIL_ATR)
     {
      double atr = GetCurrentATR();
      if(atr > 0)
        {
         trailStartPrice = atr * InpATRTrailStartMult;
         trailDistPrice  = atr * InpATRTrailDistMult;
        }
      else
        {
         // Fallback to fixed inputs if ATR isn't ready yet (warm-up)
         trailStartPrice = InpTrailStartPips    * g_pip;
         trailDistPrice  = InpTrailDistancePips * g_pip;
        }
     }
   else
     {
      trailStartPrice = InpTrailStartPips    * g_pip;
      trailDistPrice  = InpTrailDistancePips * g_pip;
     }

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic()  != InpMagic) continue;

      double entry = posInfo.PriceOpen();
      double sl    = posInfo.StopLoss();
      double tp    = posInfo.TakeProfit();
      ulong  tk    = posInfo.Ticket();

      if(posInfo.PositionType() == POSITION_TYPE_BUY)
        {
         double profitPrice = bid - entry;
         double newSL = sl;

         // Break-even ratchet (always pip-based — predictable threshold)
         if(InpBreakevenTriggerPips > 0 && profitPrice >= InpBreakevenTriggerPips * g_pip)
           {
            double bePrice = NormalizeDouble(entry + InpBreakevenBufferPips * g_pip, g_digits);
            if(bePrice > newSL) newSL = bePrice;
           }

         // Trailing stop
         if(trailStartPrice > 0 && trailDistPrice > 0 && profitPrice >= trailStartPrice)
           {
            double trailSL = NormalizeDouble(bid - trailDistPrice, g_digits);
            if(trailSL > newSL) newSL = trailSL;
           }

         if(newSL > 0 && bid - newSL < minDist)
            newSL = NormalizeDouble(bid - minDist - pt, g_digits);

         // Only ratchet up
         if(newSL > 0 && newSL > sl + pt * 0.5)
            trade.PositionModify(tk, newSL, tp);
        }
      else if(posInfo.PositionType() == POSITION_TYPE_SELL)
        {
         double profitPrice = entry - ask;
         double newSL = sl;

         if(InpBreakevenTriggerPips > 0 && profitPrice >= InpBreakevenTriggerPips * g_pip)
           {
            double bePrice = NormalizeDouble(entry - InpBreakevenBufferPips * g_pip, g_digits);
            if(newSL == 0 || bePrice < newSL) newSL = bePrice;
           }

         if(trailStartPrice > 0 && trailDistPrice > 0 && profitPrice >= trailStartPrice)
           {
            double trailSL = NormalizeDouble(ask + trailDistPrice, g_digits);
            if(newSL == 0 || trailSL < newSL) newSL = trailSL;
           }

         if(newSL > 0 && newSL - ask < minDist)
            newSL = NormalizeDouble(ask + minDist + pt, g_digits);

         // Only ratchet down
         bool moveDown = (sl == 0) || (newSL < sl - pt * 0.5);
         if(newSL > 0 && moveDown)
            trade.PositionModify(tk, newSL, tp);
        }
     }
  }

//+------------------------------------------------------------------+
//| Pending orders helpers                                           |
//+------------------------------------------------------------------+
int CountOpenPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(posInfo.SelectByIndex(i))
         if(posInfo.Symbol() == _Symbol && posInfo.Magic() == InpMagic) n++;
   return n;
  }

void CancelOurPendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(ordInfo.SelectByIndex(i))
         if(ordInfo.Symbol() == _Symbol && ordInfo.Magic() == InpMagic)
            trade.OrderDelete(ordInfo.Ticket());
  }

void ExpirePendingOrders()
  {
   if(!InpUsePendingExpiry) return;
   datetime now = TimeCurrent();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(ordInfo.SelectByIndex(i))
         if(ordInfo.Symbol() == _Symbol && ordInfo.Magic() == InpMagic)
            if(ordInfo.TimeSetup() + InpPendingExpirySec <= now)
               trade.OrderDelete(ordInfo.Ticket());
  }

//+------------------------------------------------------------------+
//| Partial-close tracking & execution                               |
//+------------------------------------------------------------------+
bool IsTicketPartialed(ulong ticket)
  {
   int n = ArraySize(g_partialedTickets);
   for(int i = 0; i < n; i++)
      if(g_partialedTickets[i] == ticket) return true;
   return false;
  }

void MarkTicketPartialed(ulong ticket)
  {
   int n = ArraySize(g_partialedTickets);
   ArrayResize(g_partialedTickets, n + 1);
   g_partialedTickets[n] = ticket;
  }

void ProcessPartialCloses()
  {
   if(InpPartialProfitPips <= 0) return;
   if(InpPartialClosePct  <= 0 || InpPartialClosePct >= 100) return;

   double bid    = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask    = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double step   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   if(step <= 0) step = 0.01;

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic()  != InpMagic) continue;

      ulong tk = posInfo.Ticket();
      if(IsTicketPartialed(tk)) continue;

      double entry      = posInfo.PriceOpen();
      double profitPips = 0.0;
      if(posInfo.PositionType() == POSITION_TYPE_BUY)
         profitPips = (bid - entry) / g_pip;
      else
         profitPips = (entry - ask) / g_pip;

      if(profitPips < InpPartialProfitPips) continue;

      double currentVol = posInfo.Volume();
      double closeVol   = currentVol * (InpPartialClosePct / 100.0);
      closeVol = MathFloor(closeVol / step) * step;
      double remaining = currentVol - closeVol;

      // Both legs must satisfy broker minimum lot, otherwise skip
      if(closeVol < minLot) continue;
      if(remaining > 0 && remaining < minLot) continue;

      if(trade.PositionClosePartial(tk, closeVol))
        {
         MarkTicketPartialed(tk);
         if(InpVerboseLog)
            PrintFormat("Partial close %.2f lots on ticket %I64u at +%.1f pips",
                        closeVol, tk, profitPips);
        }
     }
  }

//+------------------------------------------------------------------+
//| Daily tracking                                                   |
//+------------------------------------------------------------------+
void RolloverDayIfNeeded()
  {
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   datetime today = StringToTime(StringFormat("%04d.%02d.%02d", dt.year, dt.mon, dt.day));
   if(today != g_currentDay)
     {
      g_currentDay     = today;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_dailyHalt      = false;
     }
  }

void CheckDailyLimits()
  {
   if(g_dailyHalt) return;
   if(g_dayStartEquity <= 0) return;
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   double pct = (equity - g_dayStartEquity) / g_dayStartEquity * 100.0;

   bool   hit         = false;
   string hitReason   = "";
   if(InpDailyProfitTarget > 0 && pct >= InpDailyProfitTarget)
     {
      hit = true;
      hitReason = StringFormat("Daily profit target reached: +%.2f%%", pct);
     }
   else if(InpDailyLossLimit > 0 && pct <= -MathAbs(InpDailyLossLimit))
     {
      hit = true;
      hitReason = StringFormat("Daily loss limit hit: %.2f%%", pct);
     }
   if(!hit) return;

   PrintFormat("%s. Halting new trades.", hitReason);
   g_dailyHalt = true;
   CancelOurPendingOrders();
   if(InpCloseAllOnDailyHalt)
     {
      Print("Closing all open positions per InpCloseAllOnDailyHalt=true");
      CloseAllOurPositions();
     }
  }

void CloseAllOurPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic()  != InpMagic) continue;
      if(!trade.PositionClose(posInfo.Ticket()))
        {
         PrintFormat("Close failed for ticket %I64u: %d %s",
                     posInfo.Ticket(),
                     trade.ResultRetcode(),
                     trade.ResultRetcodeDescription());
        }
     }
  }

//+------------------------------------------------------------------+
//| Filters                                                          |
//+------------------------------------------------------------------+
bool IsWithinSession()
  {
   if(!InpUseSessionFilter) return true;
   // Convert to GMT manually if requested. We do NOT use TimeGMT() because
   // it returns broker server time in the Strategy Tester, defeating the
   // purpose. TimeCurrent() always returns the simulated server time
   // correctly, so subtracting the broker's offset gives real GMT in both
   // live and tester contexts.
   datetime t = TimeCurrent();
   if(InpSessionUseGMT)
      t -= (datetime)(InpBrokerGMTOffset * 3600);
   MqlDateTime dt;
   TimeToStruct(t, dt);
   int cur   = dt.hour * 60 + dt.min;
   int start = InpStartHour * 60 + InpStartMinute;
   int end   = InpEndHour   * 60 + InpEndMinute;
   if(start <= end) return (cur >= start && cur < end);
   return (cur >= start || cur < end); // wraps midnight
  }

bool IsSpreadAcceptable()
  {
   if(InpMaxSpreadPips <= 0) return true;
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double spreadPips = (ask - bid) / g_pip;
   return (spreadPips <= InpMaxSpreadPips);
  }
//+------------------------------------------------------------------+
