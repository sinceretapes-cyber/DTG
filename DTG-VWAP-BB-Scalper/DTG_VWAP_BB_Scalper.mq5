//+------------------------------------------------------------------+
//|                                       DTG_VWAP_BB_Scalper.mq5    |
//|                            DTG VWAP-BB Mean Reversion Scalper EA |
//|                                              Version v0.1.0      |
//+------------------------------------------------------------------+
//| Asian-session mean-reversion scalper for XAUUSD using anchored   |
//| VWAP and Bollinger Bands. Standalone product — does NOT depend on|
//| the DTG V8 indicator suite.                                      |
//|                                                                  |
//| Compile under MQL5 with #property strict.                        |
//+------------------------------------------------------------------+
#property copyright "DTG — Day Trading Gold"
#property link      "https://daytradinggold.local"
#property version   "1.00"
#property strict
#property description "Asian-session VWAP-BB mean reversion scalper for XAUUSD."

#include "Include/DTG_Config.mqh"
#include "Include/DTG_State.mqh"
#include "Include/DTG_Logger.mqh"
#include "Include/DTG_Indicators.mqh"
#include "Include/DTG_News.mqh"
#include "Include/DTG_Filters.mqh"
#include "Include/DTG_Risk.mqh"
#include "Include/DTG_Setup.mqh"
#include "Include/DTG_Execution.mqh"
#include "Include/DTG_Management.mqh"

//+------------------------------------------------------------------+
//| Global EA state                                                  |
//+------------------------------------------------------------------+
ENUM_DTG_STATE   g_state          = DTG_STATE_IDLE;
datetime         g_state_entered  = 0;
DTGTradeContext  g_active_long;
DTGTradeContext  g_active_short;
bool             g_has_long       = false;
bool             g_has_short      = false;
datetime         g_last_spread_sample = 0;
datetime         g_last_m5_bar    = 0;
datetime         g_last_m1_bar    = 0;
bool             g_disabled       = false;
string           g_disabled_reason = "";

//+------------------------------------------------------------------+
//| Forward declarations                                             |
//+------------------------------------------------------------------+
void DTG_Transition(const ENUM_DTG_STATE next, const string reason);
void DTG_AttemptEntries(const datetime utc_now, const DTGFilterReadings &reads, const DTGVwapSnapshot &vwap);
bool DTG_TryEnter(const ENUM_DTG_SIDE side, const DTGVwapSnapshot &vwap, const DTGFilterReadings &reads, const datetime utc_now);
void DTG_ManageOpen(const datetime utc_now, const DTGVwapSnapshot &vwap_now);
bool DTG_ResolveClosedTrade(DTGTradeContext &ctx);
void DTG_DisableEA(const string why);

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
  {
   string err;
   if(!DTG_ValidateInputs(err))
     {
      DTG_LOG_E("INIT", "Invalid inputs: " + err);
      return INIT_PARAMETERS_INCORRECT;
     }

   string sym = DTG_Exec_ResolveSymbol(InpSymbolOverride);
   if(!SymbolSelect(sym, true))
     {
      DTG_LOG_E("INIT", "SymbolSelect failed for " + sym);
      return INIT_FAILED;
     }
   g_symbol = sym;

   if(!DTG_Indicators_Init(sym))
      return INIT_FAILED;

   DTG_Exec_Init(sym, InpMagicNumber);

   datetime utc_now = DTG_NowUtc();
   double equity = AccountInfoDouble(ACCOUNT_EQUITY);
   DTG_Risk_Init(utc_now, equity);
   DTG_Log_ResetDay();

   DTG_LOG_I("INIT",
             StringFormat("DTG VWAP-BB Scalper v%s on %s (equity=%.2f, broker_utc_offset_sec=%d)",
                          DTG_VERSION, sym, equity, DTG_BrokerToUtcOffsetSec()));

   if(!InpEnabled)
      DTG_DisableEA("InpEnabled=false");

   g_state_entered = utc_now;
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   datetime utc_now = DTG_NowUtc();
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   DTG_WriteDailySummary(g_book.day_start_utc, g_book.equity_day_start, eq, g_book.pnl_today);
   DTG_Risk_SavePF();
   DTG_Indicators_Deinit();
   DTG_LOG_I("DEINIT", StringFormat("reason=%d", reason));
  }

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
  {
   if(g_disabled)
      return;

   datetime utc_now = DTG_NowUtc();
   double   equity  = AccountInfoDouble(ACCOUNT_EQUITY);

   // -- Equity / cap maintenance --
   DTG_Risk_OnTick(utc_now, equity);

   // Equity-curve protection (rolling-30 PF) — disable EA if catastrophic.
   double pf = DTG_Risk_RollingPF();
   if(pf <= DTG_EQ_PROTECT_DISABLE)
     {
      DTG_DisableEA(StringFormat("Rolling PF %.2f below %.2f", pf, DTG_EQ_PROTECT_DISABLE));
      return;
     }

   // -- Spread sampling (one sample per second) --
   if(utc_now != g_last_spread_sample)
     {
      g_last_spread_sample = utc_now;
      long sp = SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
      DTG_Spread_RecordSample((double)sp);
     }

   // -- Persistent VWAP snapshot for this tick --
   DTGVwapSnapshot vwap_now;
   DTG_Vwap_Compute(utc_now, DTG_BrokerToUtcOffsetSec(), vwap_now);
   g_vwap_now = vwap_now;

   // -- Manage existing positions ALWAYS (kill switches must fire any time) --
   DTG_ManageOpen(utc_now, vwap_now);

   // -- Hard cap halts (no new entries) --
   ENUM_DTG_EXIT_REASON cap_reason;
   if(!DTG_Risk_GatePass(equity, cap_reason))
     {
      if(cap_reason != DTG_EXIT_NONE)
        {
         // Force-close all open positions for halting-class caps.
         if(cap_reason == DTG_EXIT_DAILY_CAP ||
            cap_reason == DTG_EXIT_WEEKLY_CAP ||
            cap_reason == DTG_EXIT_RUNNING_DD_CAP)
           {
            if(g_has_long  && PositionSelectByTicket(g_active_long.ticket))
               DTG_Mgmt_ForceClose(g_active_long, cap_reason);
            if(g_has_short && PositionSelectByTicket(g_active_short.ticket))
               DTG_Mgmt_ForceClose(g_active_short, cap_reason);
           }
        }
      return;
     }

   // -- Time stop: outside session+grace, no new entries; force close any open --
   if(DTG_Mgmt_TimeStopDue(utc_now))
     {
      if(g_has_long  && PositionSelectByTicket(g_active_long.ticket))
         DTG_Mgmt_ForceClose(g_active_long, DTG_EXIT_TIME_STOP);
      if(g_has_short && PositionSelectByTicket(g_active_short.ticket))
         DTG_Mgmt_ForceClose(g_active_short, DTG_EXIT_TIME_STOP);
      if(g_state != DTG_STATE_IDLE)
         DTG_Transition(DTG_STATE_IDLE, "time stop / out of window");
      return;
     }

   // -- Filter gate --
   DTGFilterReadings reads;
   string fail;
   if(!DTG_Filters_PassEntry(utc_now, reads, fail))
     {
      if(g_state != DTG_STATE_IDLE && g_state != DTG_STATE_IN_TRADE_TP1_PENDING &&
         g_state != DTG_STATE_IN_TRADE_TP2_PENDING && g_state != DTG_STATE_ENTRY_PLACED)
         DTG_Transition(DTG_STATE_SCANNING, "filters: " + fail);
      return;
     }

   if(g_state == DTG_STATE_IDLE || g_state == DTG_STATE_DISABLED)
      DTG_Transition(DTG_STATE_SCANNING, "filters passed");

   // -- Entry attempts only on a fresh M1 bar to avoid intratick churn --
   datetime cur_m1 = iTime(g_symbol, PERIOD_M1, 0);
   if(cur_m1 != g_last_m1_bar)
     {
      g_last_m1_bar = cur_m1;
      DTG_AttemptEntries(utc_now, reads, vwap_now);
     }

   // -- Watchdog: stuck in a non-terminal state too long --
   datetime cur_m5 = iTime(g_symbol, PERIOD_M5, 0);
   if(cur_m5 != g_last_m5_bar)
     {
      g_last_m5_bar = cur_m5;
      if(g_state == DTG_STATE_SETUP_DETECTED || g_state == DTG_STATE_ENTRY_PLACED)
        {
         if(utc_now - g_state_entered > DTG_WATCHDOG_BARS * 300)
           {
            DTG_LOG_W("WATCHDOG",
                      StringFormat("State %s stuck for >%d M5 bars — forcing IDLE",
                                   DTG_StateName(g_state), DTG_WATCHDOG_BARS));
            DTG_Transition(DTG_STATE_IDLE, "watchdog timeout");
           }
        }
     }
  }

//+------------------------------------------------------------------+
//| Transition + log                                                 |
//+------------------------------------------------------------------+
void DTG_Transition(const ENUM_DTG_STATE next, const string reason)
  {
   if(next == g_state)
      return;
   double eq    = AccountInfoDouble(ACCOUNT_EQUITY);
   long   sp    = SymbolInfoInteger(g_symbol, SYMBOL_SPREAD);
   double atrm5 = 0.0;
   DTG_ATR_M5(1, atrm5);
   DTG_LogStateTransition(g_state, next, eq, (int)sp, atrm5, reason);
   g_state = next;
   g_state_entered = DTG_NowUtc();
  }

//+------------------------------------------------------------------+
//| Attempt long/short entries                                       |
//+------------------------------------------------------------------+
void DTG_AttemptEntries(const datetime utc_now,
                        const DTGFilterReadings &reads,
                        const DTGVwapSnapshot &vwap)
  {
   int my_open = (g_has_long ? 1 : 0) + (g_has_short ? 1 : 0);
   if(my_open >= InpMaxConcurrentPositions)
      return;

   // Evaluate each side independently; only one position per side per session.
   if(!g_has_long && !g_book.long_taken_today)
     {
      DTGSetupSnapshot s;
      if(DTG_Setup_Evaluate(DTG_SIDE_LONG, vwap, s) && s.matched)
        {
         DTG_Transition(DTG_STATE_SETUP_DETECTED, "LONG setup matched");
         if(DTG_TryEnter(DTG_SIDE_LONG, vwap, reads, utc_now))
            DTG_Transition(DTG_STATE_IN_TRADE_TP1_PENDING, "LONG entry placed");
         else
            DTG_Transition(DTG_STATE_SCANNING, "LONG entry failed/skipped");
        }
     }

   my_open = (g_has_long ? 1 : 0) + (g_has_short ? 1 : 0);
   if(my_open >= InpMaxConcurrentPositions)
      return;

   if(!g_has_short && !g_book.short_taken_today)
     {
      DTGSetupSnapshot s;
      if(DTG_Setup_Evaluate(DTG_SIDE_SHORT, vwap, s) && s.matched)
        {
         DTG_Transition(DTG_STATE_SETUP_DETECTED, "SHORT setup matched");
         if(DTG_TryEnter(DTG_SIDE_SHORT, vwap, reads, utc_now))
            DTG_Transition(DTG_STATE_IN_TRADE_TP1_PENDING, "SHORT entry placed");
         else
            DTG_Transition(DTG_STATE_SCANNING, "SHORT entry failed/skipped");
        }
     }
  }

//+------------------------------------------------------------------+
//| Try to enter a single side                                       |
//+------------------------------------------------------------------+
bool DTG_TryEnter(const ENUM_DTG_SIDE side,
                  const DTGVwapSnapshot &vwap,
                  const DTGFilterReadings &reads,
                  const datetime utc_now)
  {
   double atr_m5;
   if(!DTG_ATR_M5(1, atr_m5))
      return false;

   double swing;
   if(!DTG_SwingExtreme_M5(side, InpSwingLookbackBars, swing))
      return false;

   double pt = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   if(pt <= 0.0) return false;

   double bid = SymbolInfoDouble(g_symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   double entry_ref = (side == DTG_SIDE_LONG ? ask : bid);
   double buffer    = InpSlAtrBufferMult * atr_m5;
   double sl;
   if(side == DTG_SIDE_LONG)  sl = swing - buffer;
   else                       sl = swing + buffer;

   double sl_distance = MathAbs(entry_ref - sl);
   double sl_pts = sl_distance / pt;
   if(sl_pts > InpMaxSlPoints)
     {
      DTG_LOG_D("ENTRY",
                StringFormat("Skip %s — SL %.1f pts exceeds cap %.1f pts",
                             DTG_SideName(side), sl_pts, InpMaxSlPoints));
      return false;
     }

   // TP1 = VWAP midline
   double tp1 = vwap.vwap;
   // TP2 = opposite BB midline (preferred) OR VWAP ± 0.5σ in trade direction (fallback).
   // We must ensure TP2 is strictly past TP1 in the trade direction; otherwise fallback.
   double upper2, middle2, lower2;
   double tp2_bb = 0.0;
   bool   tp2_bb_ok = DTG_BB_M5(InpBbDev1, 1, upper2, middle2, lower2);
   if(tp2_bb_ok) tp2_bb = middle2;
   double tp2_vwap = (side == DTG_SIDE_LONG)
                     ? (vwap.vwap + InpTp2VwapSigmaTarget * vwap.sigma)
                     : (vwap.vwap - InpTp2VwapSigmaTarget * vwap.sigma);
   double tp2 = tp2_bb_ok ? tp2_bb : tp2_vwap;
   bool   tp2_past_tp1 = (side == DTG_SIDE_LONG) ? (tp2 > tp1) : (tp2 < tp1);
   if(!tp2_past_tp1) tp2 = tp2_vwap;

   double risk_frac = InpRiskPerTradePct / 100.0;
   double lot = DTG_Risk_LotForRisk(g_symbol, sl_distance, risk_frac);
   if(lot <= 0.0)
     {
      DTG_LogReject("LOT_MIN",
                    StringFormat("calculated lot below broker min (sl_pts=%.1f)", sl_pts));
      return false;
     }

   string comment = InpTradeComment;
   ulong ticket = DTG_Exec_OpenMarket(g_symbol, side, lot, sl, tp2, comment);
   if(ticket == 0)
      return false;

   DTGTradeContext ctx;
   ZeroMemory(ctx);
   ctx.ticket        = ticket;
   ctx.side          = side;
   ctx.opened_utc    = utc_now;
   ctx.initial_lot   = lot;
   ctx.entry_atr_m5  = atr_m5;
   ctx.sl_price      = sl;
   ctx.tp1_price     = tp1;
   ctx.tp2_price     = tp2;
   ctx.filter_atr_h1 = reads.atr_h1;
   ctx.filter_spread = reads.spread_pts;
   ctx.comment       = comment;
   // Best-effort capture of actual fill price.
   if(PositionSelectByTicket(ticket))
      ctx.entry_price = PositionGetDouble(POSITION_PRICE_OPEN);
   else
      ctx.entry_price = entry_ref;

   if(side == DTG_SIDE_LONG)  { g_active_long  = ctx; g_has_long  = true; }
   else                       { g_active_short = ctx; g_has_short = true; }

   DTG_Risk_MarkSideTaken(side);
   DTG_LogTradeOpen(ctx);
   return true;
  }

//+------------------------------------------------------------------+
//| Manage open positions                                            |
//+------------------------------------------------------------------+
void DTG_ManageOpen(const datetime utc_now, const DTGVwapSnapshot &vwap_now)
  {
   if(g_has_long)
     {
      if(!PositionSelectByTicket(g_active_long.ticket))
        {
         DTG_ResolveClosedTrade(g_active_long);
         g_has_long = false;
        }
      else
        {
         ENUM_DTG_EXIT_REASON kr = DTG_Mgmt_KillCheck(g_active_long, vwap_now, utc_now, g_active_long.opened_utc);
         if(kr != DTG_EXIT_NONE)
           {
            DTG_Mgmt_ForceClose(g_active_long, kr);
            DTG_ResolveClosedTrade(g_active_long);
            g_has_long = false;
           }
         else
           {
            DTG_Mgmt_HandleTp1(g_active_long, vwap_now);
            if(g_active_long.tp1_hit && DTG_Mgmt_HandleTp2(g_active_long))
              {
               DTG_ResolveClosedTrade(g_active_long);
               g_has_long = false;
              }
           }
        }
     }
   if(g_has_short)
     {
      if(!PositionSelectByTicket(g_active_short.ticket))
        {
         DTG_ResolveClosedTrade(g_active_short);
         g_has_short = false;
        }
      else
        {
         ENUM_DTG_EXIT_REASON kr = DTG_Mgmt_KillCheck(g_active_short, vwap_now, utc_now, g_active_short.opened_utc);
         if(kr != DTG_EXIT_NONE)
           {
            DTG_Mgmt_ForceClose(g_active_short, kr);
            DTG_ResolveClosedTrade(g_active_short);
            g_has_short = false;
           }
         else
           {
            DTG_Mgmt_HandleTp1(g_active_short, vwap_now);
            if(g_active_short.tp1_hit && DTG_Mgmt_HandleTp2(g_active_short))
              {
               DTG_ResolveClosedTrade(g_active_short);
               g_has_short = false;
              }
           }
        }
     }

   if(!g_has_long && !g_has_short)
     {
      if(g_state == DTG_STATE_IN_TRADE_TP1_PENDING ||
         g_state == DTG_STATE_IN_TRADE_TP2_PENDING ||
         g_state == DTG_STATE_ENTRY_PLACED)
         DTG_Transition(DTG_STATE_COOLDOWN, "all positions closed");
     }
   else
     {
      if(g_active_long.tp1_hit || g_active_short.tp1_hit)
         if(g_state != DTG_STATE_IN_TRADE_TP2_PENDING)
            DTG_Transition(DTG_STATE_IN_TRADE_TP2_PENDING, "tp1 hit on at least one leg");
     }
  }

//+------------------------------------------------------------------+
//| Trade history lookup once a position has gone                    |
//+------------------------------------------------------------------+
bool DTG_ResolveClosedTrade(DTGTradeContext &ctx)
  {
   if(!HistorySelect(ctx.opened_utc - 60, TimeCurrent() + 60))
      return false;
   double total_pnl = 0.0;
   int deals = HistoryDealsTotal();
   for(int i = 0; i < deals; ++i)
     {
      ulong d = HistoryDealGetTicket(i);
      if(d == 0) continue;
      ulong pos_id = (ulong)HistoryDealGetInteger(d, DEAL_POSITION_ID);
      if(pos_id != ctx.ticket) continue;
      total_pnl += HistoryDealGetDouble(d, DEAL_PROFIT);
      total_pnl += HistoryDealGetDouble(d, DEAL_SWAP);
      total_pnl += HistoryDealGetDouble(d, DEAL_COMMISSION);
     }
   DTG_Risk_RegisterClosedTrade(total_pnl);
   return true;
  }

//+------------------------------------------------------------------+
//| Disable the EA (no auto-recovery; user must restart)             |
//+------------------------------------------------------------------+
void DTG_DisableEA(const string why)
  {
   g_disabled = true;
   g_disabled_reason = why;
   DTG_LOG_E("DISABLED", why);
   if(InpSendTerminalAlerts && !MQLInfoInteger(MQL_TESTER))
      Alert("DTG VWAP-BB Scalper disabled: ", why);
   DTG_Transition(DTG_STATE_DISABLED, why);
  }

//+------------------------------------------------------------------+
//| OnTrade — keep our local position cache in sync with broker      |
//+------------------------------------------------------------------+
void OnTrade()
  {
   if(g_has_long  && !PositionSelectByTicket(g_active_long.ticket))
     {
      DTG_ResolveClosedTrade(g_active_long);
      g_has_long = false;
     }
   if(g_has_short && !PositionSelectByTicket(g_active_short.ticket))
     {
      DTG_ResolveClosedTrade(g_active_short);
      g_has_short = false;
     }
  }
//+------------------------------------------------------------------+
