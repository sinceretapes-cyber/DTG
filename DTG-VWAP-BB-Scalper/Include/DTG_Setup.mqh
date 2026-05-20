//+------------------------------------------------------------------+
//|                                                    DTG_Setup.mqh |
//| Long/short setup detection per Section 2.2 of the spec.          |
//+------------------------------------------------------------------+
#ifndef DTG_SETUP_MQH
#define DTG_SETUP_MQH

#property strict

#include "DTG_Config.mqh"
#include "DTG_State.mqh"
#include "DTG_Logger.mqh"
#include "DTG_Indicators.mqh"

//+------------------------------------------------------------------+
//| Per-side setup snapshot                                          |
//+------------------------------------------------------------------+
struct DTGSetupSnapshot
  {
   bool             matched;
   ENUM_DTG_SIDE    side;
   double           bb_lower_dev1;
   double           bb_upper_dev1;
   double           bb_middle;
   double           vwap;
   double           vwap_sigma;
   double           atr_m5;
   double           last_close;
   string           debug;
  };

//+------------------------------------------------------------------+
//| Evaluate one direction                                           |
//+------------------------------------------------------------------+
bool DTG_Setup_Evaluate(const ENUM_DTG_SIDE side,
                        const DTGVwapSnapshot &vwap_now,
                        DTGSetupSnapshot &out)
  {
   ZeroMemory(out);
   out.side = side;

   if(!vwap_now.valid)                          { out.debug = "vwap not valid"; return false; }

   double upper1, middle, lower1;
   if(!DTG_BB_M5(InpBbDev1, 1, upper1, middle, lower1))
     { out.debug = "BB read failed"; return false; }
   double atr;
   if(!DTG_ATR_M5(1, atr))
     { out.debug = "ATR(M5) read failed"; return false; }

   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   if(CopyRates(g_symbol, PERIOD_M5, 0, 2, m5) < 2)
     { out.debug = "M5 rates copy failed"; return false; }
   double last_close = m5[1].close;
   double last_open  = m5[1].open;
   double last_high  = m5[1].high;
   double last_low   = m5[1].low;

   out.bb_lower_dev1 = lower1;
   out.bb_upper_dev1 = upper1;
   out.bb_middle     = middle;
   out.vwap          = vwap_now.vwap;
   out.vwap_sigma    = vwap_now.sigma;
   out.atr_m5        = atr;
   out.last_close    = last_close;

   // Condition 5: M5 price touched or pierced lower (long) / upper (short) BB
   bool cond_bb_touch =
        (side == DTG_SIDE_LONG  ? (last_low  <= lower1) : (last_high >= upper1));

   // Condition 6: M5 price at or below VWAP -1σ (long), at or above VWAP +1σ (short)
   bool cond_vwap_sigma =
        (side == DTG_SIDE_LONG  ? (last_close <= vwap_now.lower_1)
                                : (last_close >= vwap_now.upper_1));

   // Condition 7: M1 RSI cross-back through threshold within InpRsiCrossLookbackBars
   bool cond_rsi =
        (side == DTG_SIDE_LONG  ? DTG_RSI_CrossBack(+1, InpRsiOversold,   InpRsiCrossLookbackBars)
                                : DTG_RSI_CrossBack(-1, InpRsiOverbought, InpRsiCrossLookbackBars));

   // Condition 8: confirming candle close
   bool cond_confirm =
        (side == DTG_SIDE_LONG  ? (last_close > last_open) : (last_close < last_open));

   out.debug = StringFormat("bb_touch=%d vwap_sig=%d rsi=%d confirm=%d",
                            (int)cond_bb_touch, (int)cond_vwap_sigma,
                            (int)cond_rsi, (int)cond_confirm);

   out.matched = cond_bb_touch && cond_vwap_sigma && cond_rsi && cond_confirm;
   return true;
  }

#endif // DTG_SETUP_MQH
