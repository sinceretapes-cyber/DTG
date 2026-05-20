//+------------------------------------------------------------------+
//|                                               DTG_Indicators.mqh |
//| Indicator handle creation, defensive reads, and a custom anchored|
//| VWAP (session-anchored to the daily Asian session open).          |
//+------------------------------------------------------------------+
#ifndef DTG_INDICATORS_MQH
#define DTG_INDICATORS_MQH

#property strict

#include "DTG_Config.mqh"
#include "DTG_State.mqh"
#include "DTG_Logger.mqh"

//+------------------------------------------------------------------+
//| Handle cache                                                     |
//+------------------------------------------------------------------+
struct DTGIndicatorHandles
  {
   int h_bb_m5_dev1;
   int h_bb_m5_dev2;
   int h_atr_m5;
   int h_atr_h1;
   int h_ema_fast_m15;
   int h_ema_slow_m15;
   int h_rsi_m1;
  };

DTGIndicatorHandles g_ind;
string              g_symbol = "";

//+------------------------------------------------------------------+
//| VWAP cache                                                       |
//|   We recompute the anchored VWAP (and sigma bands) from M1 bars  |
//|   of the current session for accuracy and tester determinism.    |
//+------------------------------------------------------------------+
struct DTGVwapSnapshot
  {
   datetime anchor_time;
   double   vwap;
   double   sigma;       // standard deviation of price vs VWAP, volume-weighted
   double   upper_1;
   double   lower_1;
   double   upper_2;
   double   lower_2;
   bool     valid;
  };

DTGVwapSnapshot g_vwap_now;

//+------------------------------------------------------------------+
//| Init / Deinit                                                    |
//+------------------------------------------------------------------+
bool DTG_Indicators_Init(const string sym)
  {
   g_symbol = sym;
   ZeroMemory(g_ind);

   g_ind.h_bb_m5_dev1   = iBands(sym, PERIOD_M5,  InpBbLength, 0, InpBbDev1, PRICE_CLOSE);
   g_ind.h_bb_m5_dev2   = iBands(sym, PERIOD_M5,  InpBbLength, 0, InpBbDev2, PRICE_CLOSE);
   g_ind.h_atr_m5       = iATR  (sym, PERIOD_M5,  InpAtrPeriod);
   g_ind.h_atr_h1       = iATR  (sym, PERIOD_H1,  InpAtrPeriod);
   g_ind.h_ema_fast_m15 = iMA   (sym, PERIOD_M15, InpEmaFastPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_ind.h_ema_slow_m15 = iMA   (sym, PERIOD_M15, InpEmaSlowPeriod, 0, MODE_EMA, PRICE_CLOSE);
   g_ind.h_rsi_m1       = iRSI  (sym, PERIOD_M1,  InpRsiPeriod, PRICE_CLOSE);

   if(g_ind.h_bb_m5_dev1 == INVALID_HANDLE ||
      g_ind.h_bb_m5_dev2 == INVALID_HANDLE ||
      g_ind.h_atr_m5     == INVALID_HANDLE ||
      g_ind.h_atr_h1     == INVALID_HANDLE ||
      g_ind.h_ema_fast_m15 == INVALID_HANDLE ||
      g_ind.h_ema_slow_m15 == INVALID_HANDLE ||
      g_ind.h_rsi_m1     == INVALID_HANDLE)
     {
      DTG_LOG_E("IND", "Failed to create one or more indicator handles");
      return false;
     }
   return true;
  }

void DTG_Indicators_Deinit()
  {
   if(g_ind.h_bb_m5_dev1   != INVALID_HANDLE) IndicatorRelease(g_ind.h_bb_m5_dev1);
   if(g_ind.h_bb_m5_dev2   != INVALID_HANDLE) IndicatorRelease(g_ind.h_bb_m5_dev2);
   if(g_ind.h_atr_m5       != INVALID_HANDLE) IndicatorRelease(g_ind.h_atr_m5);
   if(g_ind.h_atr_h1       != INVALID_HANDLE) IndicatorRelease(g_ind.h_atr_h1);
   if(g_ind.h_ema_fast_m15 != INVALID_HANDLE) IndicatorRelease(g_ind.h_ema_fast_m15);
   if(g_ind.h_ema_slow_m15 != INVALID_HANDLE) IndicatorRelease(g_ind.h_ema_slow_m15);
   if(g_ind.h_rsi_m1       != INVALID_HANDLE) IndicatorRelease(g_ind.h_rsi_m1);
   ZeroMemory(g_ind);
  }

//+------------------------------------------------------------------+
//| Defensive single-value reads (shift = 0 is forming, 1 = last     |
//| closed). All return false on any error.                          |
//+------------------------------------------------------------------+
bool DTG_CopyBuf(const int handle, const int buffer, const int shift, double &out)
  {
   double tmp[];
   if(handle == INVALID_HANDLE)
      return false;
   if(CopyBuffer(handle, buffer, shift, 1, tmp) != 1)
      return false;
   if(tmp[0] == EMPTY_VALUE || !MathIsValidNumber(tmp[0]))
      return false;
   out = tmp[0];
   return true;
  }

bool DTG_BB_M5(const double dev, const int shift,
               double &upper, double &middle, double &lower)
  {
   // iBands buffer layout in MQL5: 0 = base/middle, 1 = upper, 2 = lower.
   const int handle = (MathAbs(dev - InpBbDev1) < 1e-9) ? g_ind.h_bb_m5_dev1 : g_ind.h_bb_m5_dev2;
   if(!DTG_CopyBuf(handle, 0, shift, middle)) return false;
   if(!DTG_CopyBuf(handle, 1, shift, upper))  return false;
   if(!DTG_CopyBuf(handle, 2, shift, lower))  return false;
   return true;
  }

bool DTG_ATR_M5(const int shift, double &v) { return DTG_CopyBuf(g_ind.h_atr_m5, 0, shift, v); }
bool DTG_ATR_H1(const int shift, double &v) { return DTG_CopyBuf(g_ind.h_atr_h1, 0, shift, v); }
bool DTG_EMA_M15_Fast(const int shift, double &v){ return DTG_CopyBuf(g_ind.h_ema_fast_m15, 0, shift, v); }
bool DTG_EMA_M15_Slow(const int shift, double &v){ return DTG_CopyBuf(g_ind.h_ema_slow_m15, 0, shift, v); }
bool DTG_RSI_M1(const int shift, double &v){ return DTG_CopyBuf(g_ind.h_rsi_m1, 0, shift, v); }

//+------------------------------------------------------------------+
//| Rolling H1 ATR median (DTG_ATR_MEDIAN_LOOKBACK_D days ≈ 480 bars)|
//+------------------------------------------------------------------+
bool DTG_ATR_H1_Median(double &median_out)
  {
   const int bars_needed = DTG_ATR_MEDIAN_LOOKBACK_D * 24;
   double buf[];
   ArraySetAsSeries(buf, true);
   int copied = CopyBuffer(g_ind.h_atr_h1, 0, 1, bars_needed, buf);
   if(copied < bars_needed / 4)
      return false; // not enough history yet
   ArraySort(buf);
   median_out = buf[copied / 2];
   return median_out > 0.0;
  }

//+------------------------------------------------------------------+
//| Anchored VWAP computation                                        |
//|                                                                  |
//| For each completed M1 bar from the session anchor up to "as_of",  |
//| accumulate:                                                      |
//|   sum_pv  = Σ typical_price * volume                              |
//|   sum_v   = Σ volume                                              |
//|   sum_p2v = Σ typical_price² * volume    (for variance)           |
//| VWAP = sum_pv / sum_v                                            |
//| Var  = sum_p2v/sum_v − VWAP²    (volume-weighted variance)        |
//|                                                                  |
//| Volume choice: prefer tick volume (always available); real volume |
//| is unreliable on FX/metal pairs.                                  |
//+------------------------------------------------------------------+
datetime DTG_Vwap_AnchorTimeForUtc(const datetime utc_now)
  {
   MqlDateTime mdt;
   TimeToStruct(utc_now, mdt);
   mdt.hour = InpVwapAnchorHourUTC;
   mdt.min  = 0;
   mdt.sec  = 0;
   datetime anchor = StructToTime(mdt);
   if(anchor > utc_now)
      anchor -= 86400; // before today's anchor -> use yesterday's
   return anchor;
  }

bool DTG_Vwap_Compute(const datetime utc_now,
                      const int      broker_offset_sec,
                      DTGVwapSnapshot &snap)
  {
   ZeroMemory(snap);
   datetime anchor_utc = DTG_Vwap_AnchorTimeForUtc(utc_now);
   datetime anchor_broker = anchor_utc + broker_offset_sec;

   // Fetch all M1 bars from anchor up to now (use copyrates by date range).
   MqlRates rates[];
   ArraySetAsSeries(rates, false);
   datetime end_broker = TimeCurrent() + 1;
   int copied = CopyRates(g_symbol, PERIOD_M1, anchor_broker, end_broker, rates);
   if(copied <= 0)
      return false;

   double sum_pv  = 0.0;
   double sum_v   = 0.0;
   double sum_p2v = 0.0;
   long   n_used  = 0;

   for(int i = 0; i < copied; ++i)
     {
      if(rates[i].time < anchor_broker)
         continue;
      double tp = (rates[i].high + rates[i].low + rates[i].close) / 3.0;
      double v  = (double)rates[i].tick_volume;
      if(v <= 0.0)
         continue;
      sum_pv  += tp * v;
      sum_v   += v;
      sum_p2v += tp * tp * v;
      n_used++;
     }

   if(sum_v <= 0.0 || n_used < 1)
      return false;

   double vwap = sum_pv / sum_v;
   double var  = (sum_p2v / sum_v) - (vwap * vwap);
   if(var < 0.0) var = 0.0;
   double sigma = MathSqrt(var);

   snap.anchor_time = anchor_utc;
   snap.vwap        = vwap;
   snap.sigma       = sigma;
   snap.upper_1     = vwap + 1.0 * sigma;
   snap.lower_1     = vwap - 1.0 * sigma;
   snap.upper_2     = vwap + 2.0 * sigma;
   snap.lower_2     = vwap - 2.0 * sigma;
   snap.valid       = true;
   return true;
  }

//+------------------------------------------------------------------+
//| RSI cross-back detector                                          |
//|  Returns true if within last 'lookback' M1 bars RSI has gone     |
//|  below threshold (oversold) and crossed back above it.           |
//|  direction = +1 for long (cross up from below 'level'),          |
//|  direction = -1 for short (cross down from above 'level').       |
//+------------------------------------------------------------------+
bool DTG_RSI_CrossBack(const int direction,
                       const double level,
                       const int lookback)
  {
   if(g_ind.h_rsi_m1 == INVALID_HANDLE || lookback < 2)
      return false;
   const int need = lookback + 2;
   double buf[];
   ArraySetAsSeries(buf, true);
   if(CopyBuffer(g_ind.h_rsi_m1, 0, 0, need, buf) != need)
      return false;

   bool seen_extreme = false;
   for(int i = lookback; i >= 1; --i)
     {
      if(direction > 0 && buf[i] < level)      seen_extreme = true;
      else if(direction < 0 && buf[i] > level) seen_extreme = true;

      if(seen_extreme)
        {
         if(direction > 0 && buf[i-1] > level && buf[i] <= level)
            return true;  // cross up
         if(direction < 0 && buf[i-1] < level && buf[i] >= level)
            return true;  // cross down
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Most recent M5 close direction (close > open ?)                  |
//+------------------------------------------------------------------+
bool DTG_LastM5_Bullish()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(g_symbol, PERIOD_M5, 0, 2, r) < 2)
      return false;
   return (r[1].close > r[1].open);
  }
bool DTG_LastM5_Bearish()
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   if(CopyRates(g_symbol, PERIOD_M5, 0, 2, r) < 2)
      return false;
   return (r[1].close < r[1].open);
  }

//+------------------------------------------------------------------+
//| Swing extreme on M5 over N bars                                  |
//|  side = LONG  -> returns lowest low                              |
//|  side = SHORT -> returns highest high                            |
//+------------------------------------------------------------------+
bool DTG_SwingExtreme_M5(const ENUM_DTG_SIDE side, const int lookback, double &out)
  {
   MqlRates r[];
   ArraySetAsSeries(r, true);
   int copied = CopyRates(g_symbol, PERIOD_M5, 0, lookback + 1, r);
   if(copied < lookback + 1)
      return false;
   double extreme = (side == DTG_SIDE_LONG) ? r[1].low : r[1].high;
   for(int i = 1; i <= lookback; ++i)
     {
      if(side == DTG_SIDE_LONG  && r[i].low  < extreme) extreme = r[i].low;
      if(side == DTG_SIDE_SHORT && r[i].high > extreme) extreme = r[i].high;
     }
   out = extreme;
   return true;
  }

#endif // DTG_INDICATORS_MQH
