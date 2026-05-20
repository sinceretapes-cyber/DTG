//+------------------------------------------------------------------+
//|                                                  DTG_Filters.mqh |
//| Session / day-of-week / spread / volatility / news gates.        |
//+------------------------------------------------------------------+
#ifndef DTG_FILTERS_MQH
#define DTG_FILTERS_MQH

#property strict

#include "DTG_Config.mqh"
#include "DTG_State.mqh"
#include "DTG_Logger.mqh"
#include "DTG_Indicators.mqh"
#include "DTG_News.mqh"

//+------------------------------------------------------------------+
//| Broker -> UTC offset                                             |
//|   offset_sec = broker_time - utc_time                            |
//|   Live: derived from TimeCurrent()-TimeGMT() and rounded to the   |
//|   nearest 15 minutes (broker offsets are quantised).              |
//|   Tester: TimeGMT() is not reliable, so fall back to the input.   |
//+------------------------------------------------------------------+
int DTG_BrokerToUtcOffsetSec()
  {
   if(!InpAutoDetectUtcOffset || MQLInfoInteger(MQL_TESTER))
      return InpBrokerToUtcOffsetMin * 60;
   long diff = (long)TimeCurrent() - (long)TimeGMT();
   if(diff < -14*3600 || diff > 14*3600)
      return InpBrokerToUtcOffsetMin * 60;
   long quant = 15 * 60;
   long rounded = ((diff + (diff >= 0 ? quant/2 : -quant/2)) / quant) * quant;
   return (int)rounded;
  }

datetime DTG_BrokerToUtc(const datetime broker_time)
  {
   return broker_time - DTG_BrokerToUtcOffsetSec();
  }
datetime DTG_NowUtc()
  {
   return TimeCurrent() - DTG_BrokerToUtcOffsetSec();
  }

//+------------------------------------------------------------------+
//| Session window                                                   |
//+------------------------------------------------------------------+
bool DTG_Filter_InSession(const datetime utc_now, string &why)
  {
   MqlDateTime mdt;
   TimeToStruct(utc_now, mdt);
   int h = mdt.hour;
   if(h < InpAsianStartHourUTC || h >= InpAsianEndHourUTC)
     {
      why = StringFormat("hour=%d outside [%d,%d)", h, InpAsianStartHourUTC, InpAsianEndHourUTC);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Day-of-week guard                                                |
//+------------------------------------------------------------------+
bool DTG_Filter_DayOfWeekOk(const datetime utc_now, string &why)
  {
   MqlDateTime mdt;
   TimeToStruct(utc_now, mdt);
   int dow = mdt.day_of_week; // 0=Sun..6=Sat

   if(dow == 0 && mdt.hour >= InpSundayBlockStartUTC)
     { why = "Sunday late evening block"; return false; }
   if(dow == 1 && mdt.hour < InpMondayBlockEndUTC)
     { why = "Monday pre-open block";     return false; }
   if(dow == 5 && mdt.hour >= InpFridayCutoffHourUTC)
     { why = "Friday afternoon cut-off";  return false; }
   if(dow == 6)
     { why = "Saturday";                  return false; }
   return true;
  }

//+------------------------------------------------------------------+
//| Rolling 30-minute median spread                                  |
//+------------------------------------------------------------------+
double g_spread_samples[];   // ring buffer storing points
int    g_spread_head = 0;
int    g_spread_count = 0;
const int DTG_SPREAD_RING_CAP = 1800; // 30 min * 60 ticks/min (one sample per second worst case)

void DTG_Spread_RecordSample(const double current_pts)
  {
   if(ArraySize(g_spread_samples) != DTG_SPREAD_RING_CAP)
      ArrayResize(g_spread_samples, DTG_SPREAD_RING_CAP);
   g_spread_samples[g_spread_head] = current_pts;
   g_spread_head = (g_spread_head + 1) % DTG_SPREAD_RING_CAP;
   if(g_spread_count < DTG_SPREAD_RING_CAP) g_spread_count++;
  }

double DTG_Spread_Median()
  {
   if(g_spread_count < 10)
      return 0.0;
   double tmp[];
   ArrayResize(tmp, g_spread_count);
   for(int i = 0; i < g_spread_count; ++i) tmp[i] = g_spread_samples[i];
   ArraySort(tmp);
   return tmp[g_spread_count / 2];
  }

//+------------------------------------------------------------------+
//| Spread filter (entry gate)                                       |
//+------------------------------------------------------------------+
bool DTG_Filter_Spread(string &why, double &spread_pts_out)
  {
   long spread_pts_long = SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
   double spread_pts = (double)spread_pts_long;
   spread_pts_out = spread_pts;
   if(spread_pts <= 0.0)
     {
      // derive from bid/ask if broker reports zero
      double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);
      double pt  = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
      if(pt > 0.0) spread_pts = (ask - bid) / pt;
     }
   if(spread_pts > InpMaxSpreadPoints)
     {
      why = StringFormat("spread=%.1f > cap %d", spread_pts, InpMaxSpreadPoints);
      return false;
     }
   double med = DTG_Spread_Median();
   if(med > 0.0 && spread_pts > med * InpSpreadMedianMult)
     {
      why = StringFormat("spread=%.1f > %.1f x median %.1f",
                         spread_pts, InpSpreadMedianMult, med);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Volatility filter                                                |
//|   * M5 ATR ∈ [Min, Max]                                          |
//|   * H1 ATR ≤ 20-day median H1 ATR × Mult                          |
//+------------------------------------------------------------------+
bool DTG_Filter_Volatility(string &why, double &atr_m5_pts_out, double &atr_h1_out)
  {
   double atr_m5, atr_h1, atr_h1_med;
   if(!DTG_ATR_M5(1, atr_m5)) { why = "ATR(M5) unavailable"; return false; }
   if(!DTG_ATR_H1(1, atr_h1)) { why = "ATR(H1) unavailable"; return false; }

   double pt = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(pt <= 0.0) { why = "POINT == 0"; return false; }
   double atr_m5_pts = atr_m5 / pt;
   atr_m5_pts_out = atr_m5_pts;
   atr_h1_out = atr_h1;

   if(atr_m5_pts < InpAtrMinPoints || atr_m5_pts > InpAtrMaxPoints)
     {
      why = StringFormat("ATR(M5) %.1f pts outside [%.1f, %.1f]",
                         atr_m5_pts, InpAtrMinPoints, InpAtrMaxPoints);
      return false;
     }

   if(DTG_ATR_H1_Median(atr_h1_med) && atr_h1_med > 0.0)
     {
      if(atr_h1 > atr_h1_med * InpH1AtrMedianMult)
        {
         why = StringFormat("ATR(H1) %.5f > %.2f x median %.5f",
                            atr_h1, InpH1AtrMedianMult, atr_h1_med);
         return false;
        }
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Trend-flat regime test                                           |
//+------------------------------------------------------------------+
bool DTG_Filter_TrendFlat(string &why, double &dev_pct_out)
  {
   double ema_fast, ema_slow;
   if(!DTG_EMA_M15_Fast(1, ema_fast) || !DTG_EMA_M15_Slow(1, ema_slow))
     {
      why = "EMA(M15) unavailable";
      return false;
     }
   if(ema_slow <= 0.0) { why = "EMA slow <= 0"; return false; }
   double dev = MathAbs(ema_fast - ema_slow) / ema_slow * 100.0;
   dev_pct_out = dev;
   if(dev > InpTrendFlatPctMax)
     {
      why = StringFormat("|EMA50-EMA200|/EMA200 = %.3f%% > %.3f%%",
                         dev, InpTrendFlatPctMax);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Aggregate entry gate                                             |
//+------------------------------------------------------------------+
struct DTGFilterReadings
  {
   double  spread_pts;
   double  atr_m5_pts;
   double  atr_h1;
   double  ema_dev_pct;
  };

// Session / day-of-week state for one-shot transition announcements.
// We don't want to spam the journal with per-tick rejection lines for these
// two filters since they fire constantly outside trading hours.
bool g_was_in_session = false;
bool g_was_dow_ok     = true;

bool DTG_Filters_PassEntry(const datetime utc_now,
                           DTGFilterReadings &r,
                           string &fail_reason)
  {
   ZeroMemory(r);

   string why;
   bool in_session = DTG_Filter_InSession(utc_now, why);
   if(in_session != g_was_in_session)
     {
      if(in_session) DTG_LOG_I("SESSION", "Asian session window OPEN");
      else            DTG_LOG_I("SESSION", "Asian session window CLOSED");
      g_was_in_session = in_session;
     }
   if(!in_session)
     {
      g_log_stats.rej_session++;
      fail_reason = why;
      return false;
     }

   bool dow_ok = DTG_Filter_DayOfWeekOk(utc_now, why);
   if(dow_ok != g_was_dow_ok)
     {
      if(!dow_ok) DTG_LOG_I("DOW", "Day-of-week guard active: " + why);
      g_was_dow_ok = dow_ok;
     }
   if(!dow_ok)
     {
      g_log_stats.rej_dayofweek++;
      fail_reason = why;
      return false;
     }
   if(!DTG_Filter_Spread(why, r.spread_pts))
     { DTG_LogReject("SPREAD", why);  fail_reason = why; return false; }
   if(DTG_News_BlockTrades(utc_now, why))
     { DTG_LogReject("NEWS", why);    fail_reason = why; return false; }
   if(!DTG_Filter_Volatility(why, r.atr_m5_pts, r.atr_h1))
     {
      // The detail message decides which counter to bump.
      if(StringFind(why, "ATR(M5)") >= 0) DTG_LogReject("ATR_M5", why);
      else                                 DTG_LogReject("ATR_H1", why);
      fail_reason = why; return false;
     }
   if(!DTG_Filter_TrendFlat(why, r.ema_dev_pct))
     { DTG_LogReject("TREND_FLAT", why); fail_reason = why; return false; }
   return true;
  }

#endif // DTG_FILTERS_MQH
