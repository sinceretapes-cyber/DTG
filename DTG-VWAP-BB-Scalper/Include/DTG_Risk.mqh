//+------------------------------------------------------------------+
//|                                                     DTG_Risk.mqh |
//| Position sizing, daily/weekly/running DD caps, equity-curve      |
//| protection (rolling-30 trade profit factor).                      |
//+------------------------------------------------------------------+
#ifndef DTG_RISK_MQH
#define DTG_RISK_MQH

#property strict

#include "DTG_Config.mqh"
#include "DTG_State.mqh"
#include "DTG_Logger.mqh"

//+------------------------------------------------------------------+
//| Persistent session book + rolling PF state                       |
//+------------------------------------------------------------------+
DTGSessionBook g_book;
DTGRollingPF   g_pf_book;

//+------------------------------------------------------------------+
//| Helper — start-of-day / start-of-week UTC                         |
//+------------------------------------------------------------------+
datetime DTG_StartOfDayUtc(const datetime t_utc)
  {
   MqlDateTime mdt;
   TimeToStruct(t_utc, mdt);
   mdt.hour = 0; mdt.min = 0; mdt.sec = 0;
   return StructToTime(mdt);
  }
datetime DTG_StartOfWeekUtc(const datetime t_utc)
  {
   MqlDateTime mdt;
   TimeToStruct(t_utc, mdt);
   int dow = mdt.day_of_week; // 0=Sun..6=Sat
   datetime sod = DTG_StartOfDayUtc(t_utc);
   // Week starts Monday 00:00 UTC.
   int back_days = (dow == 0) ? 6 : (dow - 1);
   return sod - back_days * 86400;
  }

//+------------------------------------------------------------------+
//| Persist / restore rolling PF state to a binary file              |
//+------------------------------------------------------------------+
void DTG_Risk_SavePF()
  {
   int h = FileOpen(DTG_PERSIST_FILE, FILE_WRITE | FILE_BIN | FILE_COMMON_OFF);
   if(h == INVALID_HANDLE)
     {
      DTG_LOG_W("RISK", StringFormat("Save PF state failed err=%d", GetLastError()));
      return;
     }
   FileWriteInteger(h, g_pf_book.size, INT_VALUE);
   for(int i = 0; i < g_pf_book.size; ++i)
     {
      FileWriteDouble(h, g_pf_book.profits[i]);
      FileWriteDouble(h, g_pf_book.losses[i]);
     }
   FileClose(h);
  }

void DTG_Risk_LoadPF()
  {
   g_pf_book.size = 0;
   ArrayResize(g_pf_book.profits, DTG_EQ_PROTECT_TRADES);
   ArrayResize(g_pf_book.losses,  DTG_EQ_PROTECT_TRADES);
   ArrayInitialize(g_pf_book.profits, 0.0);
   ArrayInitialize(g_pf_book.losses,  0.0);

   if(!FileIsExist(DTG_PERSIST_FILE))
      return;
   int h = FileOpen(DTG_PERSIST_FILE, FILE_READ | FILE_BIN | FILE_COMMON_OFF);
   if(h == INVALID_HANDLE)
      return;
   int sz = FileReadInteger(h, INT_VALUE);
   if(sz < 0 || sz > DTG_EQ_PROTECT_TRADES) sz = 0;
   for(int i = 0; i < sz; ++i)
     {
      g_pf_book.profits[i] = FileReadDouble(h);
      g_pf_book.losses[i]  = FileReadDouble(h);
     }
   g_pf_book.size = sz;
   FileClose(h);
  }

void DTG_Risk_RegisterClosedTrade(const double pnl)
  {
   int cap = DTG_EQ_PROTECT_TRADES;
   if(g_pf_book.size < cap)
     {
      g_pf_book.profits[g_pf_book.size] = (pnl > 0 ? pnl : 0.0);
      g_pf_book.losses [g_pf_book.size] = (pnl < 0 ? -pnl : 0.0);
      g_pf_book.size++;
     }
   else
     {
      // shift left
      for(int i = 1; i < cap; ++i)
        {
         g_pf_book.profits[i-1] = g_pf_book.profits[i];
         g_pf_book.losses [i-1] = g_pf_book.losses [i];
        }
      g_pf_book.profits[cap-1] = (pnl > 0 ?  pnl : 0.0);
      g_pf_book.losses [cap-1] = (pnl < 0 ? -pnl : 0.0);
     }
   DTG_Risk_SavePF();
  }

double DTG_Risk_RollingPF()
  {
   if(g_pf_book.size < DTG_EQ_PROTECT_TRADES) // require full window
      return 1.0;
   double sp = 0.0, sl = 0.0;
   for(int i = 0; i < g_pf_book.size; ++i)
     { sp += g_pf_book.profits[i]; sl += g_pf_book.losses[i]; }
   if(sl <= 0.0)
      return (sp > 0.0 ? 99.0 : 1.0);
   return sp / sl;
  }

//+------------------------------------------------------------------+
//| Book initialisation / rollover                                   |
//+------------------------------------------------------------------+
void DTG_Risk_RolloverDay(const datetime utc_now, const double equity)
  {
   g_book.day_start_utc       = DTG_StartOfDayUtc(utc_now);
   g_book.session_date_utc    = g_book.day_start_utc;
   g_book.equity_day_start    = equity;
   g_book.pnl_today           = 0.0;
   g_book.trades_today        = 0;
   g_book.long_taken_today    = false;
   g_book.short_taken_today   = false;
   g_book.daily_cap_tripped   = false;
  }

void DTG_Risk_RolloverWeek(const datetime utc_now, const double equity)
  {
   g_book.week_start_utc      = DTG_StartOfWeekUtc(utc_now);
   g_book.equity_week_start   = equity;
   g_book.weekly_cap_tripped  = false;
  }

void DTG_Risk_Init(const datetime utc_now, const double equity)
  {
   ZeroMemory(g_book);
   g_book.equity_peak = equity;
   DTG_Risk_RolloverWeek(utc_now, equity);
   DTG_Risk_RolloverDay (utc_now, equity);
   DTG_Risk_LoadPF();
  }

//+------------------------------------------------------------------+
//| Tick-level book maintenance                                      |
//+------------------------------------------------------------------+
void DTG_Risk_OnTick(const datetime utc_now, const double equity)
  {
   if(equity > g_book.equity_peak)
      g_book.equity_peak = equity;

   datetime sod = DTG_StartOfDayUtc(utc_now);
   if(sod != g_book.day_start_utc)
      DTG_Risk_RolloverDay(utc_now, equity);

   datetime sow = DTG_StartOfWeekUtc(utc_now);
   if(sow != g_book.week_start_utc)
      DTG_Risk_RolloverWeek(utc_now, equity);

   g_book.pnl_today = equity - g_book.equity_day_start;
  }

//+------------------------------------------------------------------+
//| Cap checks                                                       |
//+------------------------------------------------------------------+
bool DTG_Risk_DailyCapTripped(const double equity)
  {
   double loss_pct = -(equity - g_book.equity_day_start) / g_book.equity_day_start * 100.0;
   if(loss_pct >= InpDailyLossCapPct)
      g_book.daily_cap_tripped = true;
   return g_book.daily_cap_tripped;
  }
bool DTG_Risk_WeeklyCapTripped(const double equity)
  {
   double dd_pct = -(equity - g_book.equity_week_start) / g_book.equity_week_start * 100.0;
   if(dd_pct >= InpWeeklyDDCapPct)
      g_book.weekly_cap_tripped = true;
   return g_book.weekly_cap_tripped;
  }
bool DTG_Risk_RunningDDTripped(const double equity)
  {
   double dd_pct = (g_book.equity_peak - equity) / g_book.equity_peak * 100.0;
   if(dd_pct >= InpMaxRunningDDPct)
      g_book.running_dd_tripped = true;
   return g_book.running_dd_tripped;
  }

bool DTG_Risk_GatePass(const double equity, ENUM_DTG_EXIT_REASON &reason_out)
  {
   reason_out = DTG_EXIT_NONE;
   if(DTG_Risk_DailyCapTripped(equity))   { reason_out = DTG_EXIT_DAILY_CAP;     return false; }
   if(DTG_Risk_WeeklyCapTripped(equity))  { reason_out = DTG_EXIT_WEEKLY_CAP;    return false; }
   if(DTG_Risk_RunningDDTripped(equity))  { reason_out = DTG_EXIT_RUNNING_DD_CAP;return false; }
   if(g_book.trades_today >= InpMaxTradesPerDay) return false;
   return true;
  }

//+------------------------------------------------------------------+
//| Lot calculation (XAUUSD-safe in non-USD account currencies)      |
//+------------------------------------------------------------------+
double DTG_Risk_LotForRisk(const string sym,
                           const double sl_price_distance,
                           const double risk_fraction)
  {
   if(sl_price_distance <= 0.0 || risk_fraction <= 0.0)
      return 0.0;

   double tickSize  = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(sym, SYMBOL_TRADE_TICK_VALUE);
   double point     = SymbolInfoDouble(sym, SYMBOL_POINT);

   if(point <= 0.0 || tickSize <= 0.0)
      return 0.0;

   // Defensive fallback: derive value/point via USD->account ccy cross.
   if(tickValue <= 0.0)
     {
      string profit_ccy = SymbolInfoString(sym, SYMBOL_CURRENCY_PROFIT);
      string acct_ccy   = AccountInfoString(ACCOUNT_CURRENCY);
      double cross      = 1.0;
      if(profit_ccy != acct_ccy)
        {
         string p1 = profit_ccy + acct_ccy;
         string p2 = acct_ccy   + profit_ccy;
         double bid = 0.0;
         bool got = false;
         if(SymbolSelect(p1, true) && SymbolInfoDouble(p1, SYMBOL_BID, bid) && bid > 0.0)
           { cross = bid; got = true; }
         else if(SymbolSelect(p2, true) && SymbolInfoDouble(p2, SYMBOL_BID, bid) && bid > 0.0)
           { cross = 1.0 / bid; got = true; }
         if(!got)
           {
            DTG_LOG_W("RISK", StringFormat("Cannot derive %s->%s cross for tickValue",
                                           profit_ccy, acct_ccy));
            return 0.0;
           }
        }
      double contract = SymbolInfoDouble(sym, SYMBOL_TRADE_CONTRACT_SIZE);
      tickValue = contract * tickSize * cross;
     }

   double valuePerPoint = tickValue * (point / tickSize);
   double slPoints = sl_price_distance / point;
   double riskCcy  = AccountInfoDouble(ACCOUNT_EQUITY) * risk_fraction;

   if(valuePerPoint <= 0.0 || slPoints <= 0.0)
      return 0.0;

   double rawLot   = riskCcy / (slPoints * valuePerPoint);

   double step     = SymbolInfoDouble(sym, SYMBOL_VOLUME_STEP);
   double minLot   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MIN);
   double maxLot   = SymbolInfoDouble(sym, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;

   double lot = MathFloor(rawLot / step) * step;

   // Equity-curve protection: halve below PF=1.0, disable already handled in main loop.
   double pf = DTG_Risk_RollingPF();
   if(pf < DTG_EQ_PROTECT_HALF)
     {
      lot = MathFloor((lot * 0.5) / step) * step;
      DTG_LOG_W("RISK",
                StringFormat("Rolling PF=%.2f < %.2f — lot halved to %.2f",
                             pf, DTG_EQ_PROTECT_HALF, lot));
     }

   if(lot < minLot) return 0.0;
   if(lot > maxLot) lot = maxLot;
   return lot;
  }

//+------------------------------------------------------------------+
//| Side bookkeeping                                                 |
//+------------------------------------------------------------------+
bool DTG_Risk_SideTakenToday(const ENUM_DTG_SIDE side)
  {
   if(side == DTG_SIDE_LONG)  return g_book.long_taken_today;
   if(side == DTG_SIDE_SHORT) return g_book.short_taken_today;
   return false;
  }
void DTG_Risk_MarkSideTaken(const ENUM_DTG_SIDE side)
  {
   if(side == DTG_SIDE_LONG)  g_book.long_taken_today  = true;
   if(side == DTG_SIDE_SHORT) g_book.short_taken_today = true;
   g_book.trades_today++;
  }

#endif // DTG_RISK_MQH
