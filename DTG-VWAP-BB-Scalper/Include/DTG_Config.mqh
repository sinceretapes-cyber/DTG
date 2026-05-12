//+------------------------------------------------------------------+
//|                                                   DTG_Config.mqh |
//|                           DTG VWAP-BB Mean Reversion Scalper EA  |
//|                                              v0.1.0 — production |
//+------------------------------------------------------------------+
//| All input parameters, enums, named constants for the EA.         |
//| No inline literals are allowed elsewhere; centralise them here.  |
//+------------------------------------------------------------------+
#ifndef DTG_CONFIG_MQH
#define DTG_CONFIG_MQH

#property strict

//+------------------------------------------------------------------+
//| Enumerations                                                     |
//+------------------------------------------------------------------+
enum ENUM_DTG_LOG_LEVEL
  {
   DTG_LOG_ERROR   = 0,
   DTG_LOG_WARN    = 1,
   DTG_LOG_INFO    = 2,
   DTG_LOG_DEBUG   = 3
  };

enum ENUM_DTG_SIDE
  {
   DTG_SIDE_NONE   = 0,
   DTG_SIDE_LONG   = 1,
   DTG_SIDE_SHORT  = -1
  };

enum ENUM_DTG_EXIT_REASON
  {
   DTG_EXIT_NONE             = 0,
   DTG_EXIT_TP1              = 1,
   DTG_EXIT_TP2              = 2,
   DTG_EXIT_SL               = 3,
   DTG_EXIT_TIME_STOP        = 4,
   DTG_EXIT_TREND_KILL       = 5,
   DTG_EXIT_VOL_SPIKE_KILL   = 6,
   DTG_EXIT_VWAP_BREAK_KILL  = 7,
   DTG_EXIT_DAILY_CAP        = 8,
   DTG_EXIT_WEEKLY_CAP       = 9,
   DTG_EXIT_RUNNING_DD_CAP   = 10,
   DTG_EXIT_MANUAL           = 11,
   DTG_EXIT_EA_DISABLED      = 12
  };

//+------------------------------------------------------------------+
//| Compile-time constants                                           |
//+------------------------------------------------------------------+
#define DTG_VERSION                "0.1.0"
#define DTG_MAGIC_BASE             70000     // reserved 70000-70099
#define DTG_MAX_CONCURRENT_HARD    2
#define DTG_RETRY_MAX              3
#define DTG_RETRY_BACKOFF_MS_1     50
#define DTG_RETRY_BACKOFF_MS_2     200
#define DTG_RETRY_BACKOFF_MS_3     500
#define DTG_BARS_LOOKBACK          250       // enough for BB(20), EMA(50), EMA(200) lead-in
#define DTG_ATR_MEDIAN_LOOKBACK_D  20        // rolling 20-day median H1 ATR
#define DTG_SPREAD_MEDIAN_MIN      30        // rolling 30 minute spread median window
#define DTG_WATCHDOG_BARS          6         // force IDLE if stuck longer than this on M5
#define DTG_GRACE_MINUTES_DEFAULT  30        // grace after session end before forced close
#define DTG_EQ_PROTECT_TRADES      30        // rolling N-trade PF window
#define DTG_EQ_PROTECT_HALF        1.0       // PF below this halves lots
#define DTG_EQ_PROTECT_DISABLE     0.8       // PF below this disables EA
#define DTG_PERSIST_FILE           "DTG_VWAP_BB_State.bin"
#define DTG_STATIC_CALENDAR_FILE   "calendar_static.csv"

//+------------------------------------------------------------------+
//| Inputs — General                                                 |
//+------------------------------------------------------------------+
input group "=== General ==="
input bool   InpEnabled                = true;                          // Master enable/disable
input int    InpMagicNumber            = 70001;                         // Magic number (70000-70099)
input string InpTradeComment           = "DTG-VWAP-BB v0.1.0";          // Comment string on orders
input string InpSymbolOverride         = "";                            // Optional symbol override; empty = chart symbol

//+------------------------------------------------------------------+
//| Inputs — Session                                                 |
//+------------------------------------------------------------------+
input group "=== Session ==="
input int    InpAsianStartHourUTC      = 0;                             // Asian session start hour (UTC, inclusive)
input int    InpAsianEndHourUTC        = 6;                             // Asian session end hour (UTC, exclusive)
input int    InpAsianGraceMinutes      = DTG_GRACE_MINUTES_DEFAULT;     // Grace minutes after session end before forced close
input int    InpBrokerToUtcOffsetMin   = 0;                             // Broker server offset from UTC, in minutes (0=auto-detect)
input bool   InpAutoDetectUtcOffset    = true;                          // Auto-detect broker UTC offset from TimeGMTOffset
input int    InpFridayCutoffHourUTC    = 18;                            // Block new trades after this hour on Fridays
input int    InpSundayBlockStartUTC    = 22;                            // Block trades from this hour Sunday
input int    InpMondayBlockEndUTC      = 0;                             // Block until this hour Monday

//+------------------------------------------------------------------+
//| Inputs — Strategy                                                |
//+------------------------------------------------------------------+
input group "=== Strategy ==="
input int    InpBbLength               = 20;                            // Bollinger Band length (M5)
input double InpBbDev1                 = 2.0;                           // Inner BB deviation
input double InpBbDev2                 = 2.5;                           // Outer BB deviation
input int    InpVwapAnchorHourUTC      = 0;                             // VWAP anchor hour (UTC) — Asian open
input int    InpEmaFastPeriod          = 50;                            // M15 EMA fast period
input int    InpEmaSlowPeriod          = 200;                           // M15 EMA slow period
input int    InpAtrPeriod              = 14;                            // ATR period (M5 and H1)
input int    InpRsiPeriod              = 7;                             // M1 RSI period
input double InpRsiOversold            = 25.0;                          // M1 RSI oversold threshold
input double InpRsiOverbought          = 75.0;                          // M1 RSI overbought threshold
input int    InpRsiCrossLookbackBars   = 3;                             // M1 bars to look back for RSI cross
input int    InpSwingLookbackBars      = 12;                            // M5 bars used for swing extreme reference

//+------------------------------------------------------------------+
//| Inputs — Entry filters                                           |
//+------------------------------------------------------------------+
input group "=== Entry filters ==="
input double InpAtrMinPoints           = 25.0;                          // Minimum M5 ATR in points to allow trades
input double InpAtrMaxPoints           = 80.0;                          // Maximum M5 ATR in points to allow trades
input double InpH1AtrMedianMult        = 1.2;                           // H1 ATR must be <= median * this
input double InpTrendFlatPctMax        = 0.3;                           // |EMA50-EMA200|/EMA200 % must be <= this to enter
input int    InpMaxSpreadPoints        = 25;                            // Hard cap on spread (points)
input double InpSpreadMedianMult       = 1.5;                           // Spread must be <= rolling median * this

//+------------------------------------------------------------------+
//| Inputs — Risk management                                         |
//+------------------------------------------------------------------+
input group "=== Risk management ==="
input double InpRiskPerTradePct        = 1.0;                           // Risk per trade (% of equity)
input double InpRiskPerTradePctMax     = 2.0;                           // Hard ceiling on risk per trade (%)
input int    InpMaxConcurrentPositions = 2;                             // Max concurrent positions (<= DTG_MAX_CONCURRENT_HARD)
input double InpDailyLossCapPct        = 4.0;                           // Daily loss cap (% of starting-day equity)
input double InpWeeklyDDCapPct         = 10.0;                          // Weekly drawdown cap (% of week start equity)
input double InpMaxRunningDDPct        = 15.0;                          // Running drawdown cap from equity peak (%)
input int    InpMaxTradesPerDay        = 4;                             // Max trades opened per day
input int    InpMinHoldSeconds         = 60;                            // Minimum hold seconds (prop firm compliance)

//+------------------------------------------------------------------+
//| Inputs — Trade management                                        |
//+------------------------------------------------------------------+
input group "=== Trade management ==="
input double InpSlAtrBufferMult        = 0.3;                           // Stop-loss buffer in ATR(M5) multiples beyond swing
input double InpMaxSlPoints            = 50.0;                          // Hard maximum SL distance (points); skip trade if exceeded
input double InpTp2VwapSigmaTarget     = 0.5;                           // VWAP +/- N sigma fallback target for TP2
input int    InpPartialClosePct        = 50;                            // Percentage closed at TP1
input int    InpBreakevenBufferPoints  = 1;                             // Breakeven offset (points) after TP1
input int    InpTimeStopGraceMinutes   = DTG_GRACE_MINUTES_DEFAULT;     // Force close N minutes after session end
input int    InpDeviationPoints        = 30;                            // Allowed slippage (points)

//+------------------------------------------------------------------+
//| Inputs — Kill switches                                           |
//+------------------------------------------------------------------+
input group "=== Kill switches ==="
input double InpTrendKillPct           = 0.5;                           // Close in-trade if |EMA50-EMA200|/EMA200 % exceeds this
input double InpVolSpikeMult           = 2.0;                           // Close in-trade if M5 ATR > entry ATR * this
input double InpVwapBreakSigma         = 2.5;                           // Close in-trade if M5 closes beyond VWAP +/- this sigma

//+------------------------------------------------------------------+
//| Inputs — News filter                                             |
//+------------------------------------------------------------------+
input group "=== News filter ==="
input bool   InpUseNewsFilter          = true;                          // Enable news filter
input string InpNewsCurrencies         = "USD,EUR";                     // CSV of currencies to block on high-impact events
input int    InpNewsPreMinutes         = 15;                            // Block N minutes before high-impact event
input int    InpNewsPostMinutes        = 15;                            // Block N minutes after high-impact event
input int    InpNfpPreMinutes          = 60;                            // Block N minutes before NFP
input int    InpNfpPostMinutes         = 60;                            // Block N minutes after NFP
input int    InpFomcPreMinutes         = 90;                            // Block N minutes before FOMC rate decision
input int    InpFomcPostMinutes        = 90;                            // Block N minutes after FOMC rate decision
input bool   InpUseStaticCsvInTester   = true;                          // In strategy tester, fall back to Files/calendar_static.csv

//+------------------------------------------------------------------+
//| Inputs — Debugging                                               |
//+------------------------------------------------------------------+
input group "=== Debugging ==="
input ENUM_DTG_LOG_LEVEL InpLogLevel   = DTG_LOG_INFO;                  // Log verbosity
input bool   InpSendTerminalAlerts     = false;                         // Use Alert() on critical events
input bool   InpWriteDailySummary      = true;                          // Write daily summary log file
input bool   InpVisualDebug            = false;                         // Draw VWAP/BB lines on chart (off in tester for speed)

//+------------------------------------------------------------------+
//| Validate & clamp user inputs at OnInit                           |
//+------------------------------------------------------------------+
bool DTG_ValidateInputs(string &err)
  {
   err = "";
   if(InpMagicNumber < DTG_MAGIC_BASE || InpMagicNumber > DTG_MAGIC_BASE + 99)
     { err = "Magic number must be in reserved range 70000-70099"; return false; }
   if(InpAsianStartHourUTC < 0 || InpAsianStartHourUTC > 23)
     { err = "Asian start hour invalid";  return false; }
   if(InpAsianEndHourUTC   < 1 || InpAsianEndHourUTC   > 24)
     { err = "Asian end hour invalid";    return false; }
   if(InpAsianEndHourUTC <= InpAsianStartHourUTC)
     { err = "Asian end hour must be > start hour"; return false; }
   if(InpBbLength < 5 || InpBbLength > 200)
     { err = "BB length out of range";     return false; }
   if(InpBbDev1 <= 0.0 || InpBbDev2 <= 0.0 || InpBbDev2 <= InpBbDev1)
     { err = "BB deviations invalid (dev2 must exceed dev1)"; return false; }
   if(InpAtrPeriod < 2 || InpRsiPeriod < 2)
     { err = "ATR/RSI periods too small";  return false; }
   if(InpEmaFastPeriod <= 0 || InpEmaSlowPeriod <= 0 || InpEmaFastPeriod >= InpEmaSlowPeriod)
     { err = "EMA periods invalid (fast must be smaller than slow)"; return false; }
   if(InpRiskPerTradePct <= 0.0 || InpRiskPerTradePct > InpRiskPerTradePctMax)
     { err = "Risk per trade out of range"; return false; }
   if(InpMaxConcurrentPositions < 1 || InpMaxConcurrentPositions > DTG_MAX_CONCURRENT_HARD)
     { err = "Max concurrent positions invalid"; return false; }
   if(InpAtrMinPoints <= 0 || InpAtrMaxPoints <= InpAtrMinPoints)
     { err = "ATR min/max range invalid";   return false; }
   if(InpMaxSlPoints <= 0)
     { err = "Max SL points must be > 0";   return false; }
   if(InpPartialClosePct <= 0 || InpPartialClosePct >= 100)
     { err = "Partial close percent must be 1..99"; return false; }
   return true;
  }

#endif // DTG_CONFIG_MQH
