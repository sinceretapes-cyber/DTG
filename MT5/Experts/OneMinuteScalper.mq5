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
input double               InpMaxSpreadPips       = 0;      // Max allowed spread (pips, 0 = off)

//--- Stop loss / Take profit
input group                "=== Stop Loss / Take Profit ==="
input ENUM_SL_MODE         InpSLMode              = SL_CANDLE_EXTREME; // Stop loss mode
input double               InpSLBufferPips        = 2.0;    // SL buffer beyond candle extreme (pips)
input double               InpSLFixedPips         = 8.0;    // Fixed SL (pips), used in SL_FIXED_PIPS mode
input double               InpMinSLPips           = 5.0;    // Minimum acceptable SL distance (pips)
input double               InpMaxSLPips           = 0;      // Max acceptable SL distance (pips, 0 = off)
input double               InpTakeProfitPips      = 0.0;    // Take profit (pips, 0 = none / let trail close)

//--- Break-even & trailing
input group                "=== Break-even & Trailing ==="
input double               InpBreakevenTriggerPips = 8.0;   // Move SL to BE after this profit (pips)
input double               InpBreakevenBufferPips  = 1.0;   // Lock-in pips at break-even
input double               InpTrailStartPips       = 15.0;  // Start trailing after this profit (pips)
input double               InpTrailDistancePips    = 8.0;   // Trail distance behind price (pips)

//--- Money management
input group                "=== Money Management ==="
input ENUM_LOT_MODE        InpLotMode              = LOT_RISK_PERCENT; // Lot sizing mode
input double               InpFixedLot             = 0.01;  // Fixed lot size
input double               InpRiskPercent          = 0.25;  // Risk % per trade
input int                  InpMaxOpenPositions     = 1;     // Max simultaneous positions

//--- Daily limits
// Note: 0 / 0 here disables the daily halt so backtests run uninterrupted.
// For demo/live use, suggest 1.0 (profit target) and 2.0 (loss limit).
input group                "=== Daily Limits ==="
input double               InpDailyProfitTarget    = 0;     // Halt new trades after +X% (0 = off)
input double               InpDailyLossLimit       = 0;     // Halt new trades after -X% (0 = off)

//--- Session filter
input group                "=== Session Filter ==="
input bool                 InpUseSessionFilter     = false; // Restrict to a trading window (server time)
input int                  InpStartHour            = 7;     // Start hour
input int                  InpStartMinute          = 0;     // Start minute
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

   g_currentDay     = 0;
   g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   g_dailyHalt      = false;
   g_lastBarTime    = (datetime)iTime(_Symbol, PERIOD_M1, 0);

   PrintFormat("OneMinuteScalper init: digits=%d pip=%.*f magic=%I64d",
               g_digits, g_digits, g_pip, InpMagic);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { }

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
   if(!IsWithinSession()) return;

   // Always cancel previous pending orders so we only chase the newest signal
   CancelOurPendingOrders();

   if(CountOpenPositions() >= InpMaxOpenPositions) return;
   if(!IsSpreadAcceptable()) return;

   double op = iOpen (_Symbol, PERIOD_M1, 1);
   double cl = iClose(_Symbol, PERIOD_M1, 1);
   double hi = iHigh (_Symbol, PERIOD_M1, 1);
   double lo = iLow  (_Symbol, PERIOD_M1, 1);
   if(op <= 0 || cl <= 0 || hi <= 0 || lo <= 0) return;

   double rangePips = (hi - lo) / g_pip;
   if(rangePips < InpMinCandleSizePips) return;
   if(InpMaxCandleSizePips > 0 && rangePips > InpMaxCandleSizePips) return;

   if(cl > op && InpTradeBullish)
      PlaceBuyStop(hi, lo);
   else if(cl < op && InpTradeBearish)
      PlaceSellStop(lo, hi);
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
   double pt          = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   long   stopsLvlPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double minDist     = stopsLvlPts * pt;
   double bid         = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask         = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

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
         double profitPips = (bid - entry) / g_pip;
         double newSL = sl;

         if(InpBreakevenTriggerPips > 0 && profitPips >= InpBreakevenTriggerPips)
           {
            double bePrice = NormalizeDouble(entry + InpBreakevenBufferPips * g_pip, g_digits);
            if(bePrice > newSL) newSL = bePrice;
           }

         if(InpTrailStartPips > 0 && InpTrailDistancePips > 0 &&
            profitPips >= InpTrailStartPips)
           {
            double trailSL = NormalizeDouble(bid - InpTrailDistancePips * g_pip, g_digits);
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
         double profitPips = (entry - ask) / g_pip;
         double newSL = sl;

         if(InpBreakevenTriggerPips > 0 && profitPips >= InpBreakevenTriggerPips)
           {
            double bePrice = NormalizeDouble(entry - InpBreakevenBufferPips * g_pip, g_digits);
            if(newSL == 0 || bePrice < newSL) newSL = bePrice;
           }

         if(InpTrailStartPips > 0 && InpTrailDistancePips > 0 &&
            profitPips >= InpTrailStartPips)
           {
            double trailSL = NormalizeDouble(ask + InpTrailDistancePips * g_pip, g_digits);
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

   if(InpDailyProfitTarget > 0 && pct >= InpDailyProfitTarget)
     {
      PrintFormat("Daily profit target reached: %.2f%%. Halting new trades.", pct);
      g_dailyHalt = true;
      CancelOurPendingOrders();
     }
   else if(InpDailyLossLimit > 0 && pct <= -MathAbs(InpDailyLossLimit))
     {
      PrintFormat("Daily loss limit hit: %.2f%%. Halting new trades.", pct);
      g_dailyHalt = true;
      CancelOurPendingOrders();
     }
  }

//+------------------------------------------------------------------+
//| Filters                                                          |
//+------------------------------------------------------------------+
bool IsWithinSession()
  {
   if(!InpUseSessionFilter) return true;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
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
