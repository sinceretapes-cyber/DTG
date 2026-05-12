//+------------------------------------------------------------------+
//|                                                DTG_Execution.mqh |
//| Order send / modify / close wrapped in retry logic.              |
//| All trade operations route through CTrade.                       |
//+------------------------------------------------------------------+
#ifndef DTG_EXECUTION_MQH
#define DTG_EXECUTION_MQH

#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

#include "DTG_Config.mqh"
#include "DTG_State.mqh"
#include "DTG_Logger.mqh"

CTrade        g_trade;
CPositionInfo g_pos;
CSymbolInfo   g_sym_info;

//+------------------------------------------------------------------+
//| Init                                                             |
//+------------------------------------------------------------------+
void DTG_Exec_Init(const string sym, const int magic)
  {
   g_sym_info.Name(sym);
   g_sym_info.RefreshRates();
   g_trade.SetExpertMagicNumber(magic);
   g_trade.SetDeviationInPoints(InpDeviationPoints);
   g_trade.SetTypeFillingBySymbol(sym);
   g_trade.LogLevel(0); // we own logging
  }

//+------------------------------------------------------------------+
//| Retry helpers                                                    |
//+------------------------------------------------------------------+
int DTG_BackoffMs(const int attempt)
  {
   switch(attempt)
     {
      case 0: return DTG_RETRY_BACKOFF_MS_1;
      case 1: return DTG_RETRY_BACKOFF_MS_2;
      default: return DTG_RETRY_BACKOFF_MS_3;
     }
  }
bool DTG_IsRetryableRetcode(const uint rc)
  {
   return (rc == TRADE_RETCODE_REQUOTE       ||
           rc == TRADE_RETCODE_PRICE_OFF     ||
           rc == TRADE_RETCODE_TIMEOUT       ||
           rc == TRADE_RETCODE_PRICE_CHANGED ||
           rc == TRADE_RETCODE_CONNECTION    ||
           rc == TRADE_RETCODE_TRADE_DISABLED);
  }

//+------------------------------------------------------------------+
//| Normalise stop levels to broker requirements                     |
//|   - Round to point precision.                                    |
//|   - Enforce SYMBOL_TRADE_STOPS_LEVEL minimum distance from price.|
//+------------------------------------------------------------------+
double DTG_NormalizePrice(const string sym, const double price)
  {
   int digits = (int)SymbolInfoInteger(sym, SYMBOL_DIGITS);
   return NormalizeDouble(price, digits);
  }

bool DTG_RespectStopsLevel(const string sym,
                           const ENUM_DTG_SIDE side,
                           const double entry,
                           double &sl,
                           double &tp)
  {
   double pt = SymbolInfoDouble(sym, SYMBOL_POINT);
   long lvl_pts_long = SymbolInfoInteger(sym, SYMBOL_TRADE_STOPS_LEVEL);
   if(pt <= 0.0) return false;
   double min_dist = lvl_pts_long * pt;
   if(min_dist <= 0.0) return true;

   if(side == DTG_SIDE_LONG)
     {
      if(entry - sl < min_dist) sl = entry - min_dist;
      if(tp - entry < min_dist) tp = entry + min_dist;
     }
   else
     {
      if(sl - entry < min_dist) sl = entry + min_dist;
      if(entry - tp < min_dist) tp = entry - min_dist;
     }
   sl = DTG_NormalizePrice(sym, sl);
   tp = DTG_NormalizePrice(sym, tp);
   return true;
  }

//+------------------------------------------------------------------+
//| Market open with retries                                         |
//| Returns ticket of the created position on success, 0 on failure. |
//+------------------------------------------------------------------+
ulong DTG_Exec_OpenMarket(const string sym,
                          const ENUM_DTG_SIDE side,
                          const double lot,
                          const double sl_price,
                          const double tp_price,
                          const string comment)
  {
   if(side == DTG_SIDE_NONE || lot <= 0.0)
      return 0;

   double sl = sl_price;
   double tp = tp_price;

   for(int attempt = 0; attempt < DTG_RETRY_MAX; ++attempt)
     {
      g_sym_info.RefreshRates();
      double price = (side == DTG_SIDE_LONG ? g_sym_info.Ask() : g_sym_info.Bid());
      DTG_RespectStopsLevel(sym, side, price, sl, tp);

      bool ok;
      if(side == DTG_SIDE_LONG)
         ok = g_trade.Buy (lot, sym, price, sl, tp, comment);
      else
         ok = g_trade.Sell(lot, sym, price, sl, tp, comment);

      uint rc = g_trade.ResultRetcode();
      if(ok && rc == TRADE_RETCODE_DONE)
        {
         ulong ticket = g_trade.ResultDeal();
         // resolve to position ticket
         if(HistoryDealSelect(ticket))
           {
            ulong pos_id = (ulong)HistoryDealGetInteger(ticket, DEAL_POSITION_ID);
            if(pos_id != 0) return pos_id;
           }
         return ticket;
        }

      DTG_LOG_W("EXEC",
                StringFormat("Open %s lot=%.2f attempt=%d rc=%u (%s)",
                             DTG_SideName(side), lot, attempt + 1, rc,
                             g_trade.ResultRetcodeDescription()));

      if(rc == TRADE_RETCODE_INVALID_STOPS)
        {
         // Refit stops level and retry once more without sleeping.
         g_sym_info.RefreshRates();
         price = (side == DTG_SIDE_LONG ? g_sym_info.Ask() : g_sym_info.Bid());
         DTG_RespectStopsLevel(sym, side, price, sl, tp);
         continue;
        }
      if(!DTG_IsRetryableRetcode(rc))
         break;
      Sleep(DTG_BackoffMs(attempt));
     }
   return 0;
  }

//+------------------------------------------------------------------+
//| Modify SL/TP                                                     |
//+------------------------------------------------------------------+
bool DTG_Exec_ModifyPosition(const ulong pos_ticket,
                             const double new_sl,
                             const double new_tp)
  {
   for(int attempt = 0; attempt < DTG_RETRY_MAX; ++attempt)
     {
      if(g_trade.PositionModify(pos_ticket, new_sl, new_tp))
        {
         uint rc = g_trade.ResultRetcode();
         if(rc == TRADE_RETCODE_DONE)
            return true;
        }
      uint rc = g_trade.ResultRetcode();
      DTG_LOG_W("EXEC",
                StringFormat("Modify #%I64u sl=%.5f tp=%.5f rc=%u (%s)",
                             pos_ticket, new_sl, new_tp, rc,
                             g_trade.ResultRetcodeDescription()));
      if(!DTG_IsRetryableRetcode(rc))
         return false;
      Sleep(DTG_BackoffMs(attempt));
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Partial close                                                    |
//+------------------------------------------------------------------+
bool DTG_Exec_PartialClose(const ulong pos_ticket, const double lot_to_close)
  {
   for(int attempt = 0; attempt < DTG_RETRY_MAX; ++attempt)
     {
      if(g_trade.PositionClosePartial(pos_ticket, lot_to_close))
        {
         uint rc = g_trade.ResultRetcode();
         if(rc == TRADE_RETCODE_DONE)
            return true;
        }
      uint rc = g_trade.ResultRetcode();
      DTG_LOG_W("EXEC",
                StringFormat("PartialClose #%I64u lot=%.2f rc=%u (%s)",
                             pos_ticket, lot_to_close, rc,
                             g_trade.ResultRetcodeDescription()));
      if(!DTG_IsRetryableRetcode(rc))
         return false;
      Sleep(DTG_BackoffMs(attempt));
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Full close                                                       |
//+------------------------------------------------------------------+
bool DTG_Exec_Close(const ulong pos_ticket)
  {
   for(int attempt = 0; attempt < DTG_RETRY_MAX; ++attempt)
     {
      if(g_trade.PositionClose(pos_ticket))
        {
         uint rc = g_trade.ResultRetcode();
         if(rc == TRADE_RETCODE_DONE)
            return true;
        }
      uint rc = g_trade.ResultRetcode();
      DTG_LOG_W("EXEC",
                StringFormat("Close #%I64u rc=%u (%s)",
                             pos_ticket, rc, g_trade.ResultRetcodeDescription()));
      if(!DTG_IsRetryableRetcode(rc))
         return false;
      Sleep(DTG_BackoffMs(attempt));
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Count my positions for this symbol & magic                       |
//+------------------------------------------------------------------+
int DTG_Exec_CountPositions(const string sym, const int magic)
  {
   int cnt = 0;
   int total = PositionsTotal();
   for(int i = 0; i < total; ++i)
     {
      if(!g_pos.SelectByIndex(i)) continue;
      if(g_pos.Symbol() != sym)   continue;
      if(g_pos.Magic()  != magic) continue;
      cnt++;
     }
   return cnt;
  }

//+------------------------------------------------------------------+
//| Resolve symbol with broker suffix                                |
//|   Input symbol = user override or chart symbol.                   |
//|   We try the exact name first, then the chart symbol.            |
//+------------------------------------------------------------------+
string DTG_Exec_ResolveSymbol(const string requested)
  {
   string candidate = (StringLen(requested) > 0) ? requested : _Symbol;
   if(SymbolSelect(candidate, true))
      return candidate;
   // try chart symbol as fallback
   if(SymbolSelect(_Symbol, true))
     {
      DTG_LOG_W("EXEC", StringFormat("Symbol '%s' not selectable, falling back to chart '%s'",
                                     candidate, _Symbol));
      return _Symbol;
     }
   return candidate;
  }

#endif // DTG_EXECUTION_MQH
