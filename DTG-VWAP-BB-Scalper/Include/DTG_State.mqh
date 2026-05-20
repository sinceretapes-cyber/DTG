//+------------------------------------------------------------------+
//|                                                    DTG_State.mqh |
//| Finite state machine + session/trade book-keeping data.          |
//+------------------------------------------------------------------+
#ifndef DTG_STATE_MQH
#define DTG_STATE_MQH

#property strict

#include "DTG_Config.mqh"

//+------------------------------------------------------------------+
//| EA states                                                        |
//+------------------------------------------------------------------+
enum ENUM_DTG_STATE
  {
   DTG_STATE_IDLE                  = 0,
   DTG_STATE_SCANNING              = 1,
   DTG_STATE_SETUP_DETECTED        = 2,
   DTG_STATE_ENTRY_PLACED          = 3,
   DTG_STATE_IN_TRADE_TP1_PENDING  = 4,
   DTG_STATE_IN_TRADE_TP2_PENDING  = 5,
   DTG_STATE_COOLDOWN              = 6,
   DTG_STATE_DISABLED              = 7
  };

//+------------------------------------------------------------------+
//| Per-trade snapshot (for logging / kill-switches that need entry  |
//| reference values).                                               |
//+------------------------------------------------------------------+
struct DTGTradeContext
  {
   ulong            ticket;
   ENUM_DTG_SIDE    side;
   datetime         opened_utc;
   double           entry_price;
   double           sl_price;
   double           tp1_price;
   double           tp2_price;
   double           initial_lot;
   double           entry_atr_m5;          // captured for vol-spike kill
   bool             tp1_hit;
   bool             be_set;
   double           best_excursion;        // signed best price excursion
   double           filter_atr_h1;
   double           filter_spread;
   string           comment;
  };

//+------------------------------------------------------------------+
//| Session book-keeping                                             |
//+------------------------------------------------------------------+
struct DTGSessionBook
  {
   datetime         session_date_utc;      // day stamp (00:00 UTC of current Asian session day)
   datetime         day_start_utc;
   datetime         week_start_utc;
   double           equity_day_start;
   double           equity_week_start;
   double           equity_peak;
   double           pnl_today;
   int              trades_today;
   bool             long_taken_today;
   bool             short_taken_today;
   bool             daily_cap_tripped;
   bool             weekly_cap_tripped;
   bool             running_dd_tripped;
   int              consec_losses;
  };

//+------------------------------------------------------------------+
//| Rolling-30 PF book-keeping (persisted)                           |
//+------------------------------------------------------------------+
struct DTGRollingPF
  {
   double           profits[];   // dynamic
   double           losses[];    // dynamic (positive magnitudes)
   int              size;
  };

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
string DTG_StateName(const ENUM_DTG_STATE s)
  {
   switch(s)
     {
      case DTG_STATE_IDLE:                  return "IDLE";
      case DTG_STATE_SCANNING:              return "SCANNING";
      case DTG_STATE_SETUP_DETECTED:        return "SETUP_DETECTED";
      case DTG_STATE_ENTRY_PLACED:          return "ENTRY_PLACED";
      case DTG_STATE_IN_TRADE_TP1_PENDING:  return "IN_TRADE_TP1_PENDING";
      case DTG_STATE_IN_TRADE_TP2_PENDING:  return "IN_TRADE_TP2_PENDING";
      case DTG_STATE_COOLDOWN:              return "COOLDOWN";
      case DTG_STATE_DISABLED:              return "DISABLED";
     }
   return "UNKNOWN";
  }

string DTG_SideName(const ENUM_DTG_SIDE side)
  {
   if(side == DTG_SIDE_LONG)  return "LONG";
   if(side == DTG_SIDE_SHORT) return "SHORT";
   return "NONE";
  }

string DTG_ExitReasonName(const ENUM_DTG_EXIT_REASON r)
  {
   switch(r)
     {
      case DTG_EXIT_TP1:              return "TP1";
      case DTG_EXIT_TP2:              return "TP2";
      case DTG_EXIT_SL:               return "SL";
      case DTG_EXIT_TIME_STOP:        return "TIME_STOP";
      case DTG_EXIT_TREND_KILL:       return "TREND_KILL";
      case DTG_EXIT_VOL_SPIKE_KILL:   return "VOL_SPIKE_KILL";
      case DTG_EXIT_VWAP_BREAK_KILL:  return "VWAP_BREAK_KILL";
      case DTG_EXIT_DAILY_CAP:        return "DAILY_CAP";
      case DTG_EXIT_WEEKLY_CAP:       return "WEEKLY_CAP";
      case DTG_EXIT_RUNNING_DD_CAP:   return "RUNNING_DD_CAP";
      case DTG_EXIT_MANUAL:           return "MANUAL";
      case DTG_EXIT_EA_DISABLED:      return "EA_DISABLED";
     }
   return "NONE";
  }

#endif // DTG_STATE_MQH
