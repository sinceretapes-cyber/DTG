//+------------------------------------------------------------------+
//|                                               DTG_Management.mqh |
//| TP1 partial + breakeven, TP2 close, time-stop, kill switches.    |
//+------------------------------------------------------------------+
#ifndef DTG_MANAGEMENT_MQH
#define DTG_MANAGEMENT_MQH

#property strict

#include "DTG_Config.mqh"
#include "DTG_State.mqh"
#include "DTG_Logger.mqh"
#include "DTG_Indicators.mqh"
#include "DTG_Execution.mqh"

//+------------------------------------------------------------------+
//| Compute current realised+unrealised PnL on a position             |
//+------------------------------------------------------------------+
double DTG_Mgmt_PositionPnL(const ulong pos_ticket)
  {
   if(!PositionSelectByTicket(pos_ticket))
      return 0.0;
   return PositionGetDouble(POSITION_PROFIT) + PositionGetDouble(POSITION_SWAP);
  }

double DTG_Mgmt_PositionVolume(const ulong pos_ticket)
  {
   if(!PositionSelectByTicket(pos_ticket))
      return 0.0;
   return PositionGetDouble(POSITION_VOLUME);
  }

//+------------------------------------------------------------------+
//| Manage TP1 / breakeven                                           |
//|   If TP1 not yet hit and price has reached vwap midline, close   |
//|   half and move SL to breakeven + buffer.                        |
//+------------------------------------------------------------------+
bool DTG_Mgmt_HandleTp1(DTGTradeContext &ctx,
                        const DTGVwapSnapshot &vwap_now)
  {
   if(ctx.tp1_hit) return false;
   if(!PositionSelectByTicket(ctx.ticket))
      return false;

   double price = (ctx.side == DTG_SIDE_LONG)
                  ? SymbolInfoDouble(g_symbol, SYMBOL_BID)
                  : SymbolInfoDouble(g_symbol, SYMBOL_ASK);

   bool hit = (ctx.side == DTG_SIDE_LONG)
              ? (price >= ctx.tp1_price)
              : (price <= ctx.tp1_price);
   if(!hit) return false;

   double vol_now = PositionGetDouble(POSITION_VOLUME);
   double step    = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0) step = 0.01;
   double close_vol = MathFloor((vol_now * (InpPartialClosePct / 100.0)) / step) * step;
   if(close_vol < SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN))
      close_vol = SymbolInfoDouble(g_symbol, SYMBOL_VOLUME_MIN);
   if(close_vol >= vol_now)
      close_vol = MathMax(step, vol_now - step);

   if(!DTG_Exec_PartialClose(ctx.ticket, close_vol))
     {
      DTG_LOG_W("MGMT", StringFormat("TP1 partial close failed #%I64u", ctx.ticket));
      return false;
     }

   // Move SL to BE +/- buffer.
   double pt   = SymbolInfoDouble(g_symbol, SYMBOL_POINT);
   double buf  = InpBreakevenBufferPoints * pt;
   double new_sl = (ctx.side == DTG_SIDE_LONG)
                   ? (ctx.entry_price + buf)
                   : (ctx.entry_price - buf);
   DTG_Exec_ModifyPosition(ctx.ticket, new_sl, ctx.tp2_price);
   ctx.tp1_hit = true;
   ctx.be_set  = true;
   ctx.sl_price = new_sl;
   ctx.tp1_price = 0.0; // disable further checks for this trade

   DTG_LOG_I("MGMT", StringFormat("TP1 hit #%I64u — closed %.2f, SL->BE %.5f",
                                  ctx.ticket, close_vol, new_sl));
   return true;
  }

//+------------------------------------------------------------------+
//| Manage TP2 (full close at target)                                |
//+------------------------------------------------------------------+
bool DTG_Mgmt_HandleTp2(DTGTradeContext &ctx)
  {
   if(!ctx.tp1_hit) return false;
   if(!PositionSelectByTicket(ctx.ticket))
      return false;

   double price = (ctx.side == DTG_SIDE_LONG)
                  ? SymbolInfoDouble(g_symbol, SYMBOL_BID)
                  : SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   bool hit = (ctx.side == DTG_SIDE_LONG)
              ? (price >= ctx.tp2_price)
              : (price <= ctx.tp2_price);
   if(!hit) return false;

   double pnl = DTG_Mgmt_PositionPnL(ctx.ticket);
   if(DTG_Exec_Close(ctx.ticket))
     {
      DTG_LogTradeClose(ctx, DTG_EXIT_TP2, price, pnl);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Kill switches                                                    |
//+------------------------------------------------------------------+
ENUM_DTG_EXIT_REASON DTG_Mgmt_KillCheck(const DTGTradeContext &ctx,
                                       const DTGVwapSnapshot &vwap_now,
                                       const datetime utc_now,
                                       const datetime opened_utc)
  {
   if(!PositionSelectByTicket(ctx.ticket))
      return DTG_EXIT_NONE;

   // Honour minimum hold for prop firm compliance.
   if(utc_now - opened_utc < InpMinHoldSeconds)
      return DTG_EXIT_NONE;

   // Trend-day kill
   double ema_fast, ema_slow;
   if(DTG_EMA_M15_Fast(0, ema_fast) && DTG_EMA_M15_Slow(0, ema_slow) && ema_slow > 0.0)
     {
      double dev = MathAbs(ema_fast - ema_slow) / ema_slow * 100.0;
      if(dev > InpTrendKillPct)
         return DTG_EXIT_TREND_KILL;
     }

   // Vol spike kill
   double atr_now;
   if(DTG_ATR_M5(0, atr_now) && ctx.entry_atr_m5 > 0.0)
     {
      if(atr_now > ctx.entry_atr_m5 * InpVolSpikeMult)
         return DTG_EXIT_VOL_SPIKE_KILL;
     }

   // VWAP break kill on last completed M5 close
   MqlRates m5[];
   ArraySetAsSeries(m5, true);
   if(CopyRates(g_symbol, PERIOD_M5, 0, 2, m5) >= 2 && vwap_now.valid)
     {
      double close_1 = m5[1].close;
      if(ctx.side == DTG_SIDE_LONG)
        {
         double brk = vwap_now.vwap - InpVwapBreakSigma * vwap_now.sigma;
         if(close_1 < brk || close_1 < ctx.sl_price)
            return DTG_EXIT_VWAP_BREAK_KILL;
        }
      else
        {
         double brk = vwap_now.vwap + InpVwapBreakSigma * vwap_now.sigma;
         if(close_1 > brk || close_1 > ctx.sl_price)
            return DTG_EXIT_VWAP_BREAK_KILL;
        }
     }
   return DTG_EXIT_NONE;
  }

//+------------------------------------------------------------------+
//| Time stop                                                        |
//|   If we are past end-of-Asian + grace minutes, force close.      |
//+------------------------------------------------------------------+
bool DTG_Mgmt_TimeStopDue(const datetime utc_now)
  {
   MqlDateTime mdt;
   TimeToStruct(utc_now, mdt);
   int total_min   = mdt.hour * 60 + mdt.min;
   int session_end = InpAsianEndHourUTC * 60 + InpTimeStopGraceMinutes;
   return (total_min >= session_end);
  }

//+------------------------------------------------------------------+
//| Force-close helper                                               |
//+------------------------------------------------------------------+
bool DTG_Mgmt_ForceClose(DTGTradeContext &ctx, const ENUM_DTG_EXIT_REASON reason)
  {
   double price = (ctx.side == DTG_SIDE_LONG)
                  ? SymbolInfoDouble(g_symbol, SYMBOL_BID)
                  : SymbolInfoDouble(g_symbol, SYMBOL_ASK);
   double pnl = DTG_Mgmt_PositionPnL(ctx.ticket);
   if(DTG_Exec_Close(ctx.ticket))
     {
      DTG_LogTradeClose(ctx, reason, price, pnl);
      return true;
     }
   return false;
  }

#endif // DTG_MANAGEMENT_MQH
