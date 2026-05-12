//+------------------------------------------------------------------+
//|                                                     DTG_News.mqh |
//| Economic calendar wrapper.                                       |
//|   * Live mode: native MQL5 Calendar API.                         |
//|   * Tester / fallback: static CSV at Files/calendar_static.csv   |
//|     Format: yyyy.mm.dd HH:MM;currency;event_name;impact;kind     |
//|       impact = HIGH | MEDIUM | LOW                               |
//|       kind   = NORMAL | NFP | FOMC                               |
//+------------------------------------------------------------------+
#ifndef DTG_NEWS_MQH
#define DTG_NEWS_MQH

#property strict

#include "DTG_Config.mqh"
#include "DTG_Logger.mqh"

//+------------------------------------------------------------------+
//| Static-CSV calendar entry                                        |
//+------------------------------------------------------------------+
struct DTGCalEntry
  {
   datetime  time_utc;
   string    currency;
   string    event;
   string    impact;
   string    kind;       // NORMAL | NFP | FOMC
  };

DTGCalEntry g_static_cal[];
bool         g_static_cal_loaded = false;

//+------------------------------------------------------------------+
//| Helpers                                                          |
//+------------------------------------------------------------------+
bool DTG_News_CurrencyAllowed(const string ccy)
  {
   if(StringLen(InpNewsCurrencies) == 0)
      return false;
   string list = InpNewsCurrencies;
   StringToUpper(list);
   string up = ccy;
   StringToUpper(up);
   string parts[];
   int n = StringSplit(list, ',', parts);
   for(int i = 0; i < n; ++i)
      if(StringCompare(parts[i], up) == 0)
         return true;
   return false;
  }

void DTG_News_LoadStaticCsv()
  {
   g_static_cal_loaded = true;
   ArrayResize(g_static_cal, 0);

   int h = FileOpen(DTG_STATIC_CALENDAR_FILE,
                    FILE_READ | FILE_TXT | FILE_ANSI);
   if(h == INVALID_HANDLE)
     {
      DTG_LOG_W("NEWS", StringFormat("Static calendar %s not found (err=%d) — assuming empty",
                                      DTG_STATIC_CALENDAR_FILE, GetLastError()));
      return;
     }

   int row = 0;
   while(!FileIsEnding(h))
     {
      string line = FileReadString(h);
      row++;
      if(StringLen(line) < 5)            continue;
      if(StringGetCharacter(line, 0) == '#') continue;

      string f[];
      int nf = StringSplit(line, ';', f);
      if(nf < 4) continue;

      DTGCalEntry e;
      e.time_utc = StringToTime(f[0]);   // 'yyyy.mm.dd HH:MM' interpreted as broker time
      e.currency = f[1];
      e.event    = f[2];
      e.impact   = f[3];
      e.kind     = (nf >= 5) ? f[4] : "NORMAL";

      if(e.time_utc == 0) continue;

      int sz = ArraySize(g_static_cal);
      ArrayResize(g_static_cal, sz + 1);
      g_static_cal[sz] = e;
     }
   FileClose(h);
   DTG_LOG_I("NEWS", StringFormat("Loaded %d static calendar entries from %s",
                                  ArraySize(g_static_cal), DTG_STATIC_CALENDAR_FILE));
  }

//+------------------------------------------------------------------+
//| Test whether time t is within [evt - pre, evt + post] window     |
//+------------------------------------------------------------------+
bool DTG_News_InWindow(const datetime t,
                       const datetime evt,
                       const int pre_min,
                       const int post_min)
  {
   return (t >= evt - pre_min * 60 && t <= evt + post_min * 60);
  }

//+------------------------------------------------------------------+
//| Check static calendar                                            |
//+------------------------------------------------------------------+
bool DTG_News_Block_Static(const datetime utc_now, string &why)
  {
   if(!g_static_cal_loaded)
      DTG_News_LoadStaticCsv();

   int sz = ArraySize(g_static_cal);
   for(int i = 0; i < sz; ++i)
     {
      DTGCalEntry e = g_static_cal[i];
      if(!DTG_News_CurrencyAllowed(e.currency))
         continue;
      string impact = e.impact; StringToUpper(impact);
      string kind   = e.kind;   StringToUpper(kind);

      int pre = InpNewsPreMinutes;
      int post = InpNewsPostMinutes;
      if(kind == "NFP")  { pre = InpNfpPreMinutes;  post = InpNfpPostMinutes;  }
      if(kind == "FOMC") { pre = InpFomcPreMinutes; post = InpFomcPostMinutes; }

      if(impact != "HIGH" && kind == "NORMAL")
         continue;

      if(DTG_News_InWindow(utc_now, e.time_utc, pre, post))
        {
         why = StringFormat("static %s %s %s in window [-%d/+%d min]",
                            e.currency, kind, e.event, pre, post);
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Check live MT5 calendar                                          |
//|   We look back/forward 4h around now to bracket any windows up   |
//|   to FOMC ±90min.                                                |
//+------------------------------------------------------------------+
bool DTG_News_Block_Live(const datetime utc_now, string &why)
  {
   MqlCalendarValue values[];
   datetime from = utc_now - 4 * 3600;
   datetime to   = utc_now + 4 * 3600;
   int n = CalendarValueHistory(values, from, to);
   if(n <= 0)
      return false;

   for(int i = 0; i < n; ++i)
     {
      MqlCalendarEvent   evt;
      MqlCalendarCountry ctry;
      if(!CalendarEventById(values[i].event_id, evt))
         continue;
      if(!CalendarCountryById(evt.country_id, ctry))
         continue;
      if(!DTG_News_CurrencyAllowed(ctry.currency))
         continue;

      bool is_nfp = false;
      bool is_fomc = false;
      string ename = evt.name;
      string up    = ename; StringToUpper(up);
      if(StringFind(up, "NONFARM") >= 0 || StringFind(up, "NON-FARM") >= 0 ||
         StringFind(up, "EMPLOYMENT CHANGE") >= 0)
         is_nfp = true;
      if(StringFind(up, "FOMC") >= 0 || StringFind(up, "FED FUNDS RATE") >= 0 ||
         StringFind(up, "INTEREST RATE DECISION") >= 0)
         is_fomc = true;

      bool high_impact = (evt.importance == CALENDAR_IMPORTANCE_HIGH);
      if(!high_impact && !is_nfp && !is_fomc)
         continue;

      int pre = InpNewsPreMinutes;
      int post = InpNewsPostMinutes;
      if(is_nfp)  { pre = InpNfpPreMinutes;  post = InpNfpPostMinutes;  }
      if(is_fomc) { pre = InpFomcPreMinutes; post = InpFomcPostMinutes; }

      if(DTG_News_InWindow(utc_now, values[i].time, pre, post))
        {
         why = StringFormat("live %s %s in window [-%d/+%d min]",
                            ctry.currency, evt.name, pre, post);
         return true;
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
//| Public entry — returns true if trades must be blocked NOW.        |
//+------------------------------------------------------------------+
bool DTG_News_BlockTrades(const datetime utc_now, string &why)
  {
   why = "";
   if(!InpUseNewsFilter)
      return false;

   // In strategy tester, the live calendar is empty -> use CSV fallback.
   if(MQLInfoInteger(MQL_TESTER) && InpUseStaticCsvInTester)
      return DTG_News_Block_Static(utc_now, why);

   if(DTG_News_Block_Live(utc_now, why))
      return true;

   // Always also honour static CSV if user supplies one (live + override).
   return DTG_News_Block_Static(utc_now, why);
  }

#endif // DTG_NEWS_MQH
