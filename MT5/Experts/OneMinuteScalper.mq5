//+------------------------------------------------------------------+
//|                                          OneMinuteScalper.mq5    |
//|                                                              DTG |
//|                                                                  |
//| Strategy (rewritten 2026-05-08):                                 |
//|  - Trades on the chart's current timeframe (M1 / M5 / whatever). |
//|  - On each new bar, look at the just-closed candle:              |
//|      * Bullish (close > open) → place BuyStop at high + buffer.  |
//|      * Bearish (close < open) → place SellStop at low - buffer.  |
//|      * Doji → skip.                                              |
//|  - Pending order is valid only for the currently-forming candle. |
//|  - When the bar closes (i.e. the next bar opens), the position   |
//|    is closed at market regardless of P&L. One position per bar.  |
//|  - A wide catastrophic SL exists only as protection if a giant   |
//|    spike runs against you mid-candle. Normal exit is bar close.  |
//+------------------------------------------------------------------+
#property copyright "DTG"
#property link      ""
#property version   "2.00"
#property strict
#property description "Bar-by-bar breakout: enter on previous candle break, exit at bar close."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>

//--- Enumerations
enum ENUM_LOT_MODE
  {
   LOT_FIXED        = 0, // Fixed lot
   LOT_RISK_PERCENT = 1  // % risk of equity per trade
  };

//--- Strategy inputs
input group                "=== Strategy ==="
input bool                 InpTradeBullish      = true;   // Trade bullish setups (buy)
input bool                 InpTradeBearish      = true;   // Trade bearish setups (sell)
input double               InpEntryBufferPips   = 1.0;    // Entry buffer beyond candle (pips)

//--- Stop loss
// Catastrophic protection only — the position normally exits at bar close.
// This guards against an adverse spike inside the candle that runs further
// than the timeframe's normal range. For M1 gold, 30 is generous; for M5
// or higher, raise to 60-100. For FX M1, 15-20 is plenty.
input group                "=== Stop Loss ==="
input double               InpStopLossPips      = 30.0;   // Catastrophic SL (pips)

//--- Money management
input group                "=== Money Management ==="
input ENUM_LOT_MODE        InpLotMode           = LOT_RISK_PERCENT; // Lot sizing mode
input double               InpFixedLot          = 0.01;   // Fixed lot size
input double               InpRiskPercent       = 0.25;   // Risk % per trade

//--- Filters
input group                "=== Filters ==="
input double               InpMaxSpreadPips     = 10.0;   // Skip new entries if spread > this (0 = off)

//--- Trading window
// Restrict NEW entries to a time window. Existing positions still close at
// the next bar regardless. Times use TimeLocal() = your PC's clock, so set
// them in the same hours you'd read off your computer's taskbar / menubar.
// Example: 16:30 -> 17:30 means only place entries between 4:30pm and 5:30pm
// of your local PC time. Wraps midnight if start > end.
input group                "=== Trading Window ==="
input bool                 InpUseTimeWindow     = true;   // Restrict new entries to a time window
input int                  InpStartHour         = 16;     // Start hour (PC local time, 0-23)
input int                  InpStartMinute       = 30;     // Start minute
input int                  InpEndHour           = 17;     // End hour
input int                  InpEndMinute         = 30;     // End minute

//--- Misc
input group                "=== Misc ==="
input long                 InpMagic             = 9001;   // Magic number
input string               InpComment           = "barRider"; // Trade comment
input bool                 InpVerboseLog        = true;   // Verbose logging

//--- Globals
CTrade        trade;
CPositionInfo posInfo;
COrderInfo    ordInfo;

double   g_pip         = 0.0;
int      g_digits      = 0;
datetime g_lastBarTime = 0;

//+------------------------------------------------------------------+
int OnInit()
  {
   g_digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   // 1 pip = 10 points on 5/3-digit FX symbols, 1 pip = 1 point otherwise
   g_pip = (g_digits == 3 || g_digits == 5) ? point * 10.0 : point;

   trade.SetExpertMagicNumber(InpMagic);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(50);

   g_lastBarTime = (datetime)iTime(_Symbol, _Period, 0);

   PrintFormat("BarRider init: TF=%s digits=%d pip=%.*f magic=%I64d build=2026-05-09-v6",
               EnumToString(_Period), g_digits, g_digits, g_pip, InpMagic);
   PrintFormat("Inputs: EntryBuf=%.1f SLPips=%.1f LotMode=%d Risk=%.4f%% FixedLot=%.2f MaxSpread=%.1f",
               InpEntryBufferPips, InpStopLossPips,
               (int)InpLotMode, InpRiskPercent, InpFixedLot, InpMaxSpreadPips);
   PrintFormat("Inputs: TradeBull=%s TradeBear=%s",
               InpTradeBullish ? "true" : "false",
               InpTradeBearish ? "true" : "false");
   PrintFormat("Inputs: TimeWindow=%s %02d:%02d - %02d:%02d (PC local time)",
               InpUseTimeWindow ? "true" : "false",
               InpStartHour, InpStartMinute, InpEndHour, InpEndMinute);
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason) { }

//+------------------------------------------------------------------+
//| Tick handler — only acts on bar transitions                      |
//+------------------------------------------------------------------+
void OnTick()
  {
   datetime now = (datetime)iTime(_Symbol, _Period, 0);
   if(now == g_lastBarTime) return;
   g_lastBarTime = now;
   OnNewBar();
  }

//+------------------------------------------------------------------+
//| Called once per fresh bar                                        |
//+------------------------------------------------------------------+
void OnNewBar()
  {
   // The previous bar just closed. Close any positions we own — they
   // belong to that bar and exit at its close, regardless of P&L.
   CloseAllOurPositions();

   // Drop any pending orders that didn't fill during the previous bar.
   CancelOurPendingOrders();

   // Read the just-closed bar (index 1)
   double op = iOpen (_Symbol, _Period, 1);
   double cl = iClose(_Symbol, _Period, 1);
   double hi = iHigh (_Symbol, _Period, 1);
   double lo = iLow  (_Symbol, _Period, 1);
   if(op <= 0 || cl <= 0 || hi <= 0 || lo <= 0) return;

   // Trading-window filter (PC local time). Existing positions still close
   // at every bar regardless — this only gates NEW entries.
   if(!IsWithinTradingWindow())
     {
      if(InpVerboseLog) Print("Skip: outside trading window");
      return;
     }

   // Spread filter (skip placing new entries if spread is abnormally wide)
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

   if(cl > op && InpTradeBullish)
      PlaceBuyStop(hi);
   else if(cl < op && InpTradeBearish)
      PlaceSellStop(lo);
   else if(InpVerboseLog && cl == op)
      Print("Doji bar — skipped");
  }

//+------------------------------------------------------------------+
//| True if the current PC local time is inside the configured       |
//| trading window. Wraps midnight if start > end.                   |
//+------------------------------------------------------------------+
bool IsWithinTradingWindow()
  {
   if(!InpUseTimeWindow) return true;
   MqlDateTime dt;
   TimeToStruct(TimeLocal(), dt);
   int cur   = dt.hour * 60 + dt.min;
   int start = InpStartHour * 60 + InpStartMinute;
   int end   = InpEndHour   * 60 + InpEndMinute;
   if(start <= end) return (cur >= start && cur < end);
   return (cur >= start || cur < end); // wraps midnight
  }

//+------------------------------------------------------------------+
//| Place a Buy Stop above the previous bar's high                   |
//+------------------------------------------------------------------+
void PlaceBuyStop(double prevHigh)
  {
   double price = NormalizeDouble(prevHigh + InpEntryBufferPips * g_pip, g_digits);
   double sl    = NormalizeDouble(price - InpStopLossPips    * g_pip, g_digits);

   if(!ApplyBrokerStopConstraints(ORDER_TYPE_BUY_STOP, price, sl)) return;

   double slPips = (price - sl) / g_pip;
   if(slPips <= 0) return;

   double lot = CalcLotSize(slPips);
   if(lot <= 0) return;

   if(!trade.BuyStop(lot, price, _Symbol, sl, 0.0,
                     ORDER_TIME_GTC, 0, InpComment))
     {
      PrintFormat("BuyStop failed: %d %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
     }
   if(InpVerboseLog)
      PrintFormat("BuyStop placed: lot=%.2f entry=%.*f sl=%.*f slPips=%.1f",
                  lot, g_digits, price, g_digits, sl, slPips);
  }

//+------------------------------------------------------------------+
//| Place a Sell Stop below the previous bar's low                   |
//+------------------------------------------------------------------+
void PlaceSellStop(double prevLow)
  {
   double price = NormalizeDouble(prevLow - InpEntryBufferPips * g_pip, g_digits);
   double sl    = NormalizeDouble(price + InpStopLossPips    * g_pip, g_digits);

   if(!ApplyBrokerStopConstraints(ORDER_TYPE_SELL_STOP, price, sl)) return;

   double slPips = (sl - price) / g_pip;
   if(slPips <= 0) return;

   double lot = CalcLotSize(slPips);
   if(lot <= 0) return;

   if(!trade.SellStop(lot, price, _Symbol, sl, 0.0,
                      ORDER_TIME_GTC, 0, InpComment))
     {
      PrintFormat("SellStop failed: %d %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
     }
   if(InpVerboseLog)
      PrintFormat("SellStop placed: lot=%.2f entry=%.*f sl=%.*f slPips=%.1f",
                  lot, g_digits, price, g_digits, sl, slPips);
  }

//+------------------------------------------------------------------+
//| Respect broker stops level                                       |
//+------------------------------------------------------------------+
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

//+------------------------------------------------------------------+
//| Close every position this EA owns on this symbol                 |
//+------------------------------------------------------------------+
void CloseAllOurPositions()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if(posInfo.Magic()  != InpMagic) continue;
      ulong tk = posInfo.Ticket();
      double profit = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
      if(!trade.PositionClose(tk))
        {
         PrintFormat("Close failed #%I64u: %d %s",
                     tk, trade.ResultRetcode(), trade.ResultRetcodeDescription());
        }
      else if(InpVerboseLog)
        {
         PrintFormat("Closed #%I64u at bar end (P/L %.2f)", tk, profit);
        }
     }
  }

//+------------------------------------------------------------------+
//| Cancel every pending order this EA owns on this symbol           |
//+------------------------------------------------------------------+
void CancelOurPendingOrders()
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      if(!ordInfo.SelectByIndex(i)) continue;
      if(ordInfo.Symbol() != _Symbol) continue;
      if(ordInfo.Magic()  != InpMagic) continue;
      trade.OrderDelete(ordInfo.Ticket());
     }
  }
//+------------------------------------------------------------------+
