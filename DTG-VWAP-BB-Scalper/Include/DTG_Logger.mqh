//+------------------------------------------------------------------+
//|                                                   DTG_Logger.mqh |
//| Lightweight structured logger.                                   |
//|  - Writes to MT5 Experts log via Print().                        |
//|  - Optionally writes a daily summary file Files/DTG_VWAP_BB_*.log|
//|  - Filter rejection counters for end-of-day summary.             |
//+------------------------------------------------------------------+
#ifndef DTG_LOGGER_MQH
#define DTG_LOGGER_MQH

#property strict

#include "DTG_Config.mqh"
#include "DTG_State.mqh"

//+------------------------------------------------------------------+
//| Internal counters (filter rejections / trade outcomes / etc.).   |
//+------------------------------------------------------------------+
struct DTGLogStats
  {
   int   rej_session;
   int   rej_dayofweek;
   int   rej_spread;
   int   rej_news;
   int   rej_atr;
   int   rej_h1atr;
   int   rej_trendflat;
   int   rej_setup_long;
   int   rej_setup_short;
   int   rej_risk_caps;
   int   rej_lot_too_small;
   int   trades_opened;
   int   trades_tp1;
   int   trades_tp2;
   int   trades_sl;
   int   trades_killed;
   int   trades_timestop;
   double pnl_realised;
  };

DTGLogStats g_log_stats;

void DTG_Log_ResetDay()
  {
   ZeroMemory(g_log_stats);
  }

//+------------------------------------------------------------------+
//| Core print                                                       |
//+------------------------------------------------------------------+
void DTG_LogRaw(const ENUM_DTG_LOG_LEVEL lvl, const string tag, const string msg)
  {
   if(lvl > InpLogLevel)
      return;

   string prefix;
   switch(lvl)
     {
      case DTG_LOG_ERROR: prefix = "[ERR] "; break;
      case DTG_LOG_WARN:  prefix = "[WRN] "; break;
      case DTG_LOG_INFO:  prefix = "[INF] "; break;
      default:            prefix = "[DBG] "; break;
     }
   PrintFormat("%s%s | %s", prefix, tag, msg);

   if(lvl == DTG_LOG_ERROR && InpSendTerminalAlerts && !MQLInfoInteger(MQL_TESTER))
      Alert("DTG: ", tag, " | ", msg);
  }

#define DTG_LOG_E(tag, msg) DTG_LogRaw(DTG_LOG_ERROR, tag, msg)
#define DTG_LOG_W(tag, msg) DTG_LogRaw(DTG_LOG_WARN,  tag, msg)
#define DTG_LOG_I(tag, msg) DTG_LogRaw(DTG_LOG_INFO,  tag, msg)
#define DTG_LOG_D(tag, msg) DTG_LogRaw(DTG_LOG_DEBUG, tag, msg)

//+------------------------------------------------------------------+
//| State transition logger                                          |
//+------------------------------------------------------------------+
void DTG_LogStateTransition(const ENUM_DTG_STATE prev,
                            const ENUM_DTG_STATE next,
                            const double equity,
                            const int spread_points,
                            const double atr_m5,
                            const string reason)
  {
   DTG_LOG_I("STATE",
             StringFormat("%s -> %s | eq=%.2f spread=%d atr_m5=%.5f | %s",
                          DTG_StateName(prev), DTG_StateName(next),
                          equity, spread_points, atr_m5, reason));
  }

//+------------------------------------------------------------------+
//| Filter rejection logger (also bumps counters)                    |
//+------------------------------------------------------------------+
void DTG_LogReject(const string filter_tag, const string detail)
  {
   if(filter_tag == "SESSION")    g_log_stats.rej_session++;
   else if(filter_tag == "DOW")   g_log_stats.rej_dayofweek++;
   else if(filter_tag == "SPREAD")g_log_stats.rej_spread++;
   else if(filter_tag == "NEWS")  g_log_stats.rej_news++;
   else if(filter_tag == "ATR_M5")g_log_stats.rej_atr++;
   else if(filter_tag == "ATR_H1")g_log_stats.rej_h1atr++;
   else if(filter_tag == "TREND_FLAT") g_log_stats.rej_trendflat++;
   else if(filter_tag == "RISK_CAPS")  g_log_stats.rej_risk_caps++;
   else if(filter_tag == "LOT_MIN")    g_log_stats.rej_lot_too_small++;
   DTG_LOG_D("REJECT", StringFormat("%s | %s", filter_tag, detail));
  }

//+------------------------------------------------------------------+
//| Trade open / close summary                                       |
//+------------------------------------------------------------------+
void DTG_LogTradeOpen(const DTGTradeContext &t)
  {
   g_log_stats.trades_opened++;
   DTG_LOG_I("TRADE_OPEN",
             StringFormat("#%I64u side=%s lot=%.2f entry=%.5f sl=%.5f tp1=%.5f tp2=%.5f atr=%.5f spread=%.1f",
                          t.ticket, DTG_SideName(t.side), t.initial_lot,
                          t.entry_price, t.sl_price, t.tp1_price, t.tp2_price,
                          t.entry_atr_m5, t.filter_spread));
  }

void DTG_LogTradeClose(const DTGTradeContext &t,
                       const ENUM_DTG_EXIT_REASON reason,
                       const double exit_price,
                       const double pnl)
  {
   switch(reason)
     {
      case DTG_EXIT_TP1: g_log_stats.trades_tp1++;     break;
      case DTG_EXIT_TP2: g_log_stats.trades_tp2++;     break;
      case DTG_EXIT_SL:  g_log_stats.trades_sl++;      break;
      case DTG_EXIT_TIME_STOP: g_log_stats.trades_timestop++; break;
      case DTG_EXIT_TREND_KILL:
      case DTG_EXIT_VOL_SPIKE_KILL:
      case DTG_EXIT_VWAP_BREAK_KILL:
         g_log_stats.trades_killed++;
         break;
      default: break;
     }
   g_log_stats.pnl_realised += pnl;
   DTG_LOG_I("TRADE_CLOSE",
             StringFormat("#%I64u side=%s exit=%.5f reason=%s pnl=%.2f",
                          t.ticket, DTG_SideName(t.side),
                          exit_price, DTG_ExitReasonName(reason), pnl));
  }

//+------------------------------------------------------------------+
//| Daily summary file writer                                        |
//+------------------------------------------------------------------+
bool DTG_WriteDailySummary(const datetime day_utc,
                           const double eq_start,
                           const double eq_end,
                           const double pnl_today)
  {
   if(!InpWriteDailySummary)
      return true;

   MqlDateTime mdt;
   TimeToStruct(day_utc, mdt);
   string fname = StringFormat("DTG_VWAP_BB_%04d%02d%02d.log",
                               mdt.year, mdt.mon, mdt.day);
   int h = FileOpen(fname, FILE_WRITE | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      DTG_LOG_W("LOG", StringFormat("Could not open %s err=%d", fname, GetLastError()));
      return false;
     }

   FileWriteString(h, StringFormat("DTG VWAP-BB Daily Summary %04d-%02d-%02d (UTC)\n",
                                   mdt.year, mdt.mon, mdt.day));
   FileWriteString(h, StringFormat("Equity start=%.2f  end=%.2f  realised PnL=%.2f\n",
                                   eq_start, eq_end, pnl_today));
   FileWriteString(h, StringFormat("Trades opened=%d  TP1=%d  TP2=%d  SL=%d  Killed=%d  TimeStop=%d\n",
                                   g_log_stats.trades_opened,
                                   g_log_stats.trades_tp1,  g_log_stats.trades_tp2,
                                   g_log_stats.trades_sl,
                                   g_log_stats.trades_killed,
                                   g_log_stats.trades_timestop));
   FileWriteString(h, StringFormat("Rejections — session=%d dow=%d spread=%d news=%d atr_m5=%d atr_h1=%d trend=%d risk=%d lot=%d\n",
                                   g_log_stats.rej_session,
                                   g_log_stats.rej_dayofweek,
                                   g_log_stats.rej_spread,
                                   g_log_stats.rej_news,
                                   g_log_stats.rej_atr,
                                   g_log_stats.rej_h1atr,
                                   g_log_stats.rej_trendflat,
                                   g_log_stats.rej_risk_caps,
                                   g_log_stats.rej_lot_too_small));
   FileClose(h);
   return true;
  }

#endif // DTG_LOGGER_MQH
