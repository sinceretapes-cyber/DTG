//+------------------------------------------------------------------+
//|                                              DTG_NYRebreak.mq5   |
//|                              Day Trading Gold — NY Rebreak EA    |
//|                                  Aggressive NY-session scalper   |
//+------------------------------------------------------------------+
#property copyright "Day Trading Gold"
#property link      "https://day-trading-gold.com/"
#property version   "1.00"
#property strict

#include <Trade/Trade.mqh>
#include <Trade/PositionInfo.mqh>
#include <Trade/SymbolInfo.mqh>

//+------------------------------------------------------------------+
//| Enums                                                            |
//+------------------------------------------------------------------+
enum ENUM_ANCHOR
{
   NY_FOREX_OPEN = 0, // NY forex open  (08:00 ET)
   NYSE_OPEN     = 1, // NYSE equities open (09:30 ET)
   BOTH          = 2  // Pre-open buffer before forex open, armed through NYSE open
};

enum ENUM_RISK_MODE
{
   PERCENT_EQUITY = 0,
   FIXED_LOT      = 1
};

enum EA_STATE
{
   PRE_WINDOW       = 0,
   HUNTING_INITIAL  = 1,
   IN_TRADE         = 2,
   HUNTING_REBREAK  = 3,
   STOPPED_FOR_DAY  = 4
};

//+------------------------------------------------------------------+
//| Inputs                                                           |
//+------------------------------------------------------------------+
// === Session ===
input ENUM_ANCHOR    InpAnchor             = NY_FOREX_OPEN;   // NY_FOREX_OPEN | NYSE_OPEN | BOTH
input int            InpPreOpenBufferMin   = 30;              // Minutes before anchor to arm
input bool           InpAutoDST            = true;            // Handle US DST automatically

// === Execution ===
input ENUM_TIMEFRAMES InpExecTF            = PERIOD_M5;       // Execution / breakout TF
input ENUM_TIMEFRAMES InpTrailTF           = PERIOD_M5;       // Trailing-stop reference TF

// === Risk ===
input ENUM_RISK_MODE InpRiskMode           = PERCENT_EQUITY;  // PERCENT_EQUITY | FIXED_LOT
input double         InpRiskPercent        = 1.0;             // % equity risked per trade
input double         InpFixedLot           = 0.10;            // Used when RiskMode = FIXED_LOT

// === Stop Loss (ATR) ===
input int            InpATRPeriod          = 14;
input double         InpATRMultiplier      = 1.5;

// === Take Profits (in pips) ===
input double         InpTP1Pips            = 10.0;
input double         InpTP1ClosePct        = 75.0;
input double         InpTP2Pips            = 50.0;
input double         InpTP2ClosePct        = 15.0;
input double         InpTP3Pips            = 100.0;           // Final 10% closes here

// === Trade Management ===
input bool           InpBEAtTP1            = true;            // Move SL to BE when TP1 hits
input bool           InpTrailAfterBE       = true;            // Activate candle-wick trail after BE

// === Daily Limits ===
input int            InpMaxTradesPerDay    = 5;
input bool           InpStopOnFirstProfit  = true;

// === Pip Override (advanced) ===
input double         InpPipSizeOverride    = 0.0;             // 0 = auto-detect

// === Display ===
input bool             InpShowDashboard    = true;
input ENUM_BASE_CORNER InpPanelCorner      = CORNER_LEFT_UPPER;
input color            InpAccentColor      = clrGold;

// === System ===
input long           InpMagicNumber        = 88081008;
input string         InpTradeComment       = "DTG_NYRebreak";

//+------------------------------------------------------------------+
//| Globals                                                          |
//+------------------------------------------------------------------+
CTrade        trade;
CPositionInfo posInfo;

// State machine
EA_STATE      currentState        = PRE_WINDOW;

// Daily levels (locked at window open)
double        dh                  = 0.0;
double        dl                  = 0.0;
bool          levelsCaptured      = false;

// NY rebreak running extremes
double        nyh                 = 0.0;
double        nyl                 = 0.0;
bool          nyExtremesInit      = false;

// Trade tracking
int           tradeCountToday     = 0;
bool          dayProfitMade       = false;
ulong         currentTicket       = 0;
double        currentEntry        = 0.0;
double        currentSL           = 0.0;
double        currentTP1Price     = 0.0;
double        currentTP2Price     = 0.0;
double        currentTP3Price     = 0.0;
double        currentInitialLots  = 0.0;
bool          currentIsBuy        = false;
bool          tp1Hit              = false;
bool          tp2Hit              = false;
bool          tp3Hit              = false;
bool          beApplied           = false;

// Day tracking
datetime      lastBrokerDayStart  = 0;
datetime      windowOpenBroker    = 0;
datetime      windowCloseBroker   = 0;
datetime      lastTrailBarTime    = 0;
double        dailyStartEquity    = 0.0;

// Detected pip size (cached)
double        cachedPipSize       = 0.0;

// ATR handle
int           atrHandle           = INVALID_HANDLE;

// Dashboard names
const string  PANEL_PREFIX        = "DTG_NYR_";
const string  LINE_PREFIX         = "DTG_NYR_LN_";

//+------------------------------------------------------------------+
//| Forward declarations                                             |
//+------------------------------------------------------------------+
double   GetPipSize();
double   PipsToPrice(double pips);
double   PriceToPips(double priceDiff);
double   NormalizeLot(double lot);
double   NormalizePrice(double price);
double   CalculateLot(double slDistanceInPrice);
double   GetATR();
datetime GetNYAnchorTime(datetime brokerDay);
bool     IsTradingWindowOpen();
bool     IsNewBrokerDay();
int      GetBrokerToETOffsetMinutes(datetime t);
void     UpdateState();
void     CaptureDailyLevels();
void     UpdateNYExtremes();
void     CheckEntryConditions();
void     ExecuteEntry(bool isBuy, double triggerPrice);
void     ManageOpenPosition();
void     HandlePartialCloses();
void     HandleBreakEven();
void     HandleTrailingStop();
void     OnPositionClosed(double profit);
void     CreateDashboard();
void     UpdateDashboard();
void     DestroyDashboard();
void     DrawLevels();
void     ClearLevels();
void     ResetDailyState();
bool     SelectMyPosition();
void     RecoverStateFromOpenPosition();
datetime BrokerDayStart(datetime t);
bool     IsUSDST(datetime utc);
int      ETOffsetFromUTC(datetime utc);
int      BrokerOffsetFromUTC();
string   StateToString(EA_STATE s);

//+------------------------------------------------------------------+
//| OnInit                                                           |
//+------------------------------------------------------------------+
int OnInit()
{
   trade.SetExpertMagicNumber((ulong)InpMagicNumber);
   trade.SetMarginMode();
   trade.SetTypeFillingBySymbol(_Symbol);
   trade.SetDeviationInPoints(20);

   // ATR handle
   atrHandle = iATR(_Symbol, InpExecTF, InpATRPeriod);
   if(atrHandle == INVALID_HANDLE)
   {
      PrintFormat("[DTG_NYR] WARNING: iATR handle invalid for %s on TF %d", _Symbol, InpExecTF);
   }

   // Pip size auto-detect (cached)
   cachedPipSize = GetPipSize();
   PrintFormat("[DTG_NYR] Init: symbol=%s digits=%d point=%.10f pipSize=%.10f",
               _Symbol, _Digits, _Point, cachedPipSize);

   // Recover any pre-existing position with our magic
   if(SelectMyPosition())
   {
      RecoverStateFromOpenPosition();
   }
   else
   {
      currentState = PRE_WINDOW;
   }

   // Daily P/L baseline
   dailyStartEquity   = AccountInfoDouble(ACCOUNT_EQUITY);
   lastBrokerDayStart = BrokerDayStart(TimeCurrent());

   if(InpShowDashboard) CreateDashboard();
   EventSetTimer(1); // 1-second refresh for dashboard / countdown

   PrintFormat("[DTG_NYR] Initialized. State=%s", StateToString(currentState));
   return INIT_SUCCEEDED;
}

//+------------------------------------------------------------------+
//| OnDeinit                                                         |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
{
   EventKillTimer();
   if(atrHandle != INVALID_HANDLE) IndicatorRelease(atrHandle);
   DestroyDashboard();
   ClearLevels();
   PrintFormat("[DTG_NYR] Deinit. Reason=%d", reason);
}

//+------------------------------------------------------------------+
//| OnTimer — dashboard refresh, countdowns                          |
//+------------------------------------------------------------------+
void OnTimer()
{
   if(InpShowDashboard) UpdateDashboard();
}

//+------------------------------------------------------------------+
//| OnTick                                                           |
//+------------------------------------------------------------------+
void OnTick()
{
   // 1. New broker day rollover — reset everything
   if(IsNewBrokerDay())
   {
      ResetDailyState();
   }

   // 2. State machine transitions
   UpdateState();

   // 3. Per-state work
   if(currentState == HUNTING_REBREAK)
   {
      UpdateNYExtremes();
   }

   if(currentState == HUNTING_INITIAL || currentState == HUNTING_REBREAK)
   {
      CheckEntryConditions();
   }

   if(currentState == IN_TRADE)
   {
      ManageOpenPosition();
   }

   // 4. Lines (cheap to refresh)
   DrawLevels();
}

//+------------------------------------------------------------------+
//| Time helpers                                                     |
//+------------------------------------------------------------------+

// Determine if the given UTC time is within US DST window.
// US DST: 2nd Sunday of March 02:00 local -> 1st Sunday of November 02:00 local.
// For simplicity we test in UTC by checking the date boundary; tiny window
// edge cases (during the switch hour itself) are acceptable for trading.
bool IsUSDST(datetime utc)
{
   if(!InpAutoDST) return false;

   MqlDateTime dt;
   TimeToStruct(utc, dt);
   int year  = dt.year;
   int month = dt.mon;
   int day   = dt.day;

   if(month < 3 || month > 11) return false;
   if(month > 3 && month < 11) return true;

   // March: DST starts on second Sunday at 02:00 local.
   // November: DST ends on first Sunday at 02:00 local.
   // Compute Sunday-of-month boundary in UTC terms (approx — sufficient for trading hours).
   MqlDateTime first;
   first.year = year; first.mon = month; first.day = 1;
   first.hour = 0; first.min = 0; first.sec = 0;
   datetime firstOfMonth = StructToTime(first);
   MqlDateTime fm; TimeToStruct(firstOfMonth, fm);
   // fm.day_of_week: 0=Sunday
   int firstDow = fm.day_of_week;
   int firstSunday = (firstDow == 0) ? 1 : (1 + (7 - firstDow));

   if(month == 3)
   {
      int secondSunday = firstSunday + 7;
      if(day > secondSunday) return true;
      if(day < secondSunday) return false;
      // On the day itself: DST starts 02:00 local (07:00 UTC during EST).
      return (dt.hour >= 7);
   }
   if(month == 11)
   {
      if(day < firstSunday) return true;
      if(day > firstSunday) return false;
      // On the day itself: DST ends 02:00 local (06:00 UTC during EDT).
      return (dt.hour < 6);
   }
   return false;
}

// Returns minutes offset from UTC for New York ET at the given UTC time.
// EST = -300, EDT = -240.
int ETOffsetFromUTC(datetime utc)
{
   return IsUSDST(utc) ? -240 : -300;
}

// Returns minutes offset of the broker server from UTC at "now".
int BrokerOffsetFromUTC()
{
   datetime srv = TimeCurrent();
   datetime utc = TimeGMT();
   long diffSec = (long)srv - (long)utc;
   return (int)(diffSec / 60);
}

// Returns the broker server minute-offset between broker server time and ET.
// Used by GetBrokerToETOffsetMinutes() — positive when broker is ahead of ET.
int GetBrokerToETOffsetMinutes(datetime t)
{
   // Convert t (broker) -> UTC -> ET
   int brokerOff = BrokerOffsetFromUTC();
   datetime utcEquiv = t - brokerOff * 60;
   int etOff = ETOffsetFromUTC(utcEquiv);
   return brokerOff - etOff; // broker minus ET
}

// Start of broker day for the supplied broker time (midnight server).
datetime BrokerDayStart(datetime t)
{
   MqlDateTime dt;
   TimeToStruct(t, dt);
   dt.hour = 0; dt.min = 0; dt.sec = 0;
   return StructToTime(dt);
}

// Compute broker-server datetime corresponding to the chosen NY anchor on the
// ET calendar day that contains the supplied broker datetime "brokerDay".
// Returns the BUFFER-applied trading-window OPEN time in broker server seconds.
datetime GetNYAnchorTime(datetime brokerDay)
{
   // Convert brokerDay -> UTC -> derive ET calendar day
   int brokerOff = BrokerOffsetFromUTC();
   datetime utcNow = brokerDay - brokerOff * 60;
   int etOff = ETOffsetFromUTC(utcNow);
   datetime etNow = utcNow + etOff * 60;

   MqlDateTime etDt;
   TimeToStruct(etNow, etDt);

   // Choose anchor hour in ET
   int anchorHour = 8, anchorMin = 0;
   if(InpAnchor == NYSE_OPEN)     { anchorHour = 9; anchorMin = 30; }
   else if(InpAnchor == BOTH)     { anchorHour = 8; anchorMin = 0;  } // pre-buffer applies to forex open
   else                           { anchorHour = 8; anchorMin = 0;  }

   etDt.hour = anchorHour;
   etDt.min  = anchorMin;
   etDt.sec  = 0;
   datetime etAnchor = StructToTime(etDt);

   // Apply pre-open buffer
   etAnchor -= (datetime)(InpPreOpenBufferMin * 60);

   // Convert ET back to UTC -> broker
   datetime utcAnchor    = etAnchor - etOff * 60;
   datetime brokerAnchor = utcAnchor + brokerOff * 60;
   return brokerAnchor;
}

// Returns broker server time for NY market CLOSE (17:00 ET) on the ET day
// that contains brokerDay.
datetime GetNYCloseTime(datetime brokerDay)
{
   int brokerOff = BrokerOffsetFromUTC();
   datetime utcNow = brokerDay - brokerOff * 60;
   int etOff = ETOffsetFromUTC(utcNow);
   datetime etNow = utcNow + etOff * 60;

   MqlDateTime etDt;
   TimeToStruct(etNow, etDt);
   etDt.hour = 17; etDt.min = 0; etDt.sec = 0;
   datetime etClose = StructToTime(etDt);

   datetime utcClose    = etClose - etOff * 60;
   datetime brokerClose = utcClose + brokerOff * 60;
   return brokerClose;
}

// True if broker server time is currently inside the configured NY window.
bool IsTradingWindowOpen()
{
   datetime now = TimeCurrent();
   datetime open  = GetNYAnchorTime(now);
   datetime close = GetNYCloseTime(now);
   if(close <= open) close += 24*60*60; // safety
   windowOpenBroker  = open;
   windowCloseBroker = close;
   return (now >= open && now <= close);
}

// True the first time we observe a new broker day boundary.
bool IsNewBrokerDay()
{
   datetime curDay = BrokerDayStart(TimeCurrent());
   if(curDay != lastBrokerDayStart)
   {
      lastBrokerDayStart = curDay;
      return true;
   }
   return false;
}

//+------------------------------------------------------------------+
//| Pip helpers                                                      |
//+------------------------------------------------------------------+

// Universal pip size detection.
double GetPipSize()
{
   if(InpPipSizeOverride > 0.0) return InpPipSizeOverride;

   string sym  = _Symbol;
   string path = SymbolInfoString(_Symbol, SYMBOL_PATH);
   int    dig  = _Digits;
   double pt   = _Point;
   double pip  = pt * 10.0; // generic default

   StringToUpper(sym);
   string pathU = path;  StringToUpper(pathU);

   bool isJPY    = (StringFind(sym, "JPY") >= 0);
   bool isGold   = (StringFind(sym, "XAU") >= 0 || StringFind(sym, "GOLD") >= 0);
   bool isSilver = (StringFind(sym, "XAG") >= 0 || StringFind(sym, "SILVER") >= 0);
   bool isCrypto = (StringFind(sym, "BTC")  >= 0 || StringFind(sym, "ETH") >= 0 ||
                    StringFind(sym, "XRP")  >= 0 || StringFind(sym, "LTC") >= 0 ||
                    StringFind(sym, "SOL")  >= 0 || StringFind(pathU, "CRYPTO") >= 0);
   bool isIndex  = (StringFind(sym, "NAS")  >= 0 || StringFind(sym, "US30") >= 0 ||
                    StringFind(sym, "SPX")  >= 0 || StringFind(sym, "US500") >= 0 ||
                    StringFind(sym, "DAX")  >= 0 || StringFind(sym, "GER")  >= 0 ||
                    StringFind(sym, "UK100")>= 0 || StringFind(sym, "FTSE") >= 0 ||
                    StringFind(sym, "JP225")>= 0 || StringFind(sym, "NIK")  >= 0 ||
                    StringFind(pathU,"INDEX")>= 0 || StringFind(pathU, "INDICES") >= 0);

   if(isJPY)
   {
      pip = (dig == 3) ? 0.01 : (dig == 2 ? 0.01 : pt * 10.0);
   }
   else if(isGold)
   {
      if(dig == 2)      pip = 0.1;
      else if(dig == 3) pip = 0.01;
      else              pip = pt * 10.0;
   }
   else if(isSilver)
   {
      pip = (dig >= 3) ? 0.01 : 0.01;
   }
   else if(isIndex)
   {
      pip = 1.0;
   }
   else if(isCrypto)
   {
      pip = 1.0;
   }
   else
   {
      // FX majors / minors / exotics
      if(dig == 5 || dig == 4) pip = pt * 10.0; // 0.0001
      else if(dig == 3 || dig == 2) pip = pt * 10.0;
      else
      {
         PrintFormat("[DTG_NYR] Pip auto-detect uncertain for %s (digits=%d). "
                     "Defaulting to _Point*10. Set InpPipSizeOverride to override.", _Symbol, dig);
         pip = pt * 10.0;
      }
   }
   return pip;
}

double PipsToPrice(double pips)
{
   return pips * cachedPipSize;
}

double PriceToPips(double priceDiff)
{
   if(cachedPipSize <= 0.0) return 0.0;
   return priceDiff / cachedPipSize;
}

double NormalizePrice(double price)
{
   return NormalizeDouble(price, _Digits);
}

double NormalizeLot(double lot)
{
   double minLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxLot  = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   double stepLot = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   if(stepLot <= 0.0) stepLot = 0.01;

   double normalized = MathFloor(lot / stepLot) * stepLot;
   if(normalized < minLot) normalized = 0.0; // signal "below minimum"
   if(normalized > maxLot) normalized = maxLot;
   return NormalizeDouble(normalized, 2);
}

//+------------------------------------------------------------------+
//| Risk / ATR                                                       |
//+------------------------------------------------------------------+
double CalculateLot(double slDistanceInPrice)
{
   if(InpRiskMode == FIXED_LOT)
   {
      double fixedNorm = NormalizeLot(InpFixedLot);
      return fixedNorm;
   }

   double accountEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   double riskAmount    = accountEquity * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickSize <= 0.0 || tickValue <= 0.0 || slDistanceInPrice <= 0.0)
   {
      PrintFormat("[DTG_NYR] CalculateLot: invalid inputs (ts=%.10f tv=%.10f sl=%.10f)",
                  tickSize, tickValue, slDistanceInPrice);
      return 0.0;
   }
   double lossPerLot = (slDistanceInPrice / tickSize) * tickValue;
   if(lossPerLot <= 0.0) return 0.0;

   double lot = riskAmount / lossPerLot;
   return NormalizeLot(lot);
}

double GetATR()
{
   if(atrHandle == INVALID_HANDLE) return 0.0;
   double buf[];
   if(CopyBuffer(atrHandle, 0, 0, 1, buf) <= 0) return 0.0;
   return buf[0];
}

//+------------------------------------------------------------------+
//| State machine                                                    |
//+------------------------------------------------------------------+
void UpdateState()
{
   bool winOpen = IsTradingWindowOpen();
   bool havePos = SelectMyPosition();

   switch(currentState)
   {
      case PRE_WINDOW:
      {
         if(winOpen)
         {
            CaptureDailyLevels();
            currentState = HUNTING_INITIAL;
            PrintFormat("[DTG_NYR] Window opened. DH=%.5f DL=%.5f. State=HUNTING_INITIAL",
                        dh, dl);
         }
         break;
      }
      case HUNTING_INITIAL:
      {
         if(!winOpen)
         {
            currentState = STOPPED_FOR_DAY;
         }
         else if(havePos)
         {
            currentState = IN_TRADE;
         }
         break;
      }
      case IN_TRADE:
      {
         if(!havePos)
         {
            // Position just closed — handled in ManageOpenPosition's loop;
            // ensure transition here as safety net.
            // We don't know profit precisely here; defer to ManageOpenPosition close detection.
         }
         break;
      }
      case HUNTING_REBREAK:
      {
         if(!winOpen)
         {
            currentState = STOPPED_FOR_DAY;
         }
         else if(havePos)
         {
            currentState = IN_TRADE;
         }
         else if(tradeCountToday >= InpMaxTradesPerDay)
         {
            currentState = STOPPED_FOR_DAY;
            PrintFormat("[DTG_NYR] Max trades (%d) reached. STOPPED_FOR_DAY.", InpMaxTradesPerDay);
         }
         break;
      }
      case STOPPED_FOR_DAY:
      default:
         break;
   }
}

void CaptureDailyLevels()
{
   double dHigh = iHigh(_Symbol, PERIOD_D1, 0);
   double dLow  = iLow(_Symbol,  PERIOD_D1, 0);
   if(dHigh <= 0.0 || dLow <= 0.0)
   {
      PrintFormat("[DTG_NYR] WARNING: Daily H/L unavailable yet. Retrying next tick.");
      return;
   }
   dh = dHigh;
   dl = dLow;
   levelsCaptured = true;

   // Initialize NY running extremes at current price
   nyh = dh;
   nyl = dl;
   nyExtremesInit = true;
}

void UpdateNYExtremes()
{
   if(!nyExtremesInit)
   {
      nyh = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      nyl = nyh;
      nyExtremesInit = true;
   }
   // Refresh on each closed bar of execution TF (per spec) — use highs/lows
   // of bars since window opened. Cheap approximation: track tick-by-tick
   // extremes; closed-bar refresh is implicit because bar's H/L converges.
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   if(bid > nyh) nyh = bid;
   if(ask < nyl && ask > 0.0) nyl = ask;
}

void CheckEntryConditions()
{
   if(!levelsCaptured) return;
   if(tradeCountToday >= InpMaxTradesPerDay) { currentState = STOPPED_FOR_DAY; return; }
   if(SelectMyPosition()) return; // already in trade

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);

   double upperTrigger = (currentState == HUNTING_INITIAL) ? dh : nyh;
   double lowerTrigger = (currentState == HUNTING_INITIAL) ? dl : nyl;

   if(bid > upperTrigger)
   {
      ExecuteEntry(true, upperTrigger);
   }
   else if(ask < lowerTrigger && ask > 0.0)
   {
      ExecuteEntry(false, lowerTrigger);
   }
}

//+------------------------------------------------------------------+
//| Trade execution                                                  |
//+------------------------------------------------------------------+
void ExecuteEntry(bool isBuy, double triggerPrice)
{
   double atr = GetATR();
   if(atr <= 0.0)
   {
      PrintFormat("[DTG_NYR] WARNING: ATR invalid (%.10f). Skipping entry.", atr);
      return;
   }

   double slDistance = atr * InpATRMultiplier;
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double entry = isBuy ? ask : bid;

   double sl  = isBuy ? (entry - slDistance) : (entry + slDistance);
   double tp1 = isBuy ? (entry + PipsToPrice(InpTP1Pips)) : (entry - PipsToPrice(InpTP1Pips));
   double tp2 = isBuy ? (entry + PipsToPrice(InpTP2Pips)) : (entry - PipsToPrice(InpTP2Pips));
   double tp3 = isBuy ? (entry + PipsToPrice(InpTP3Pips)) : (entry - PipsToPrice(InpTP3Pips));

   double lots = CalculateLot(slDistance);
   if(lots <= 0.0)
   {
      PrintFormat("[DTG_NYR] WARNING: Lot calc <= min lot. Skipping trade.");
      return;
   }

   sl  = NormalizePrice(sl);
   tp1 = NormalizePrice(tp1);
   tp2 = NormalizePrice(tp2);
   tp3 = NormalizePrice(tp3);

   bool ok = false;
   if(isBuy) ok = trade.Buy (lots, _Symbol, 0.0, sl, 0.0, InpTradeComment);
   else      ok = trade.Sell(lots, _Symbol, 0.0, sl, 0.0, InpTradeComment);

   if(!ok)
   {
      PrintFormat("[DTG_NYR] ENTRY FAILED. retcode=%d %s",
                  trade.ResultRetcode(), trade.ResultRetcodeDescription());
      return;
   }

   currentTicket      = trade.ResultOrder();
   currentEntry       = entry;
   currentSL          = sl;
   currentTP1Price    = tp1;
   currentTP2Price    = tp2;
   currentTP3Price    = tp3;
   currentInitialLots = lots;
   currentIsBuy       = isBuy;
   tp1Hit = false; tp2Hit = false; tp3Hit = false; beApplied = false;
   tradeCountToday++;
   currentState = IN_TRADE;
   lastTrailBarTime = 0;

   PrintFormat("[DTG_NYR] ENTRY %s %.2f lots @ %.5f | SL=%.5f TP1=%.5f TP2=%.5f TP3=%.5f | ATR=%.5f | trade %d/%d",
               (isBuy ? "BUY" : "SELL"), lots, entry, sl, tp1, tp2, tp3, atr,
               tradeCountToday, InpMaxTradesPerDay);
}

void ManageOpenPosition()
{
   if(!SelectMyPosition())
   {
      // Position closed since last tick — finalize.
      double lastProfit = 0.0;
      // Inspect history for our ticket
      if(currentTicket != 0 && HistorySelectByPosition(currentTicket))
      {
         int deals = HistoryDealsTotal();
         for(int i = 0; i < deals; i++)
         {
            ulong dealTicket = HistoryDealGetTicket(i);
            if(dealTicket == 0) continue;
            lastProfit += HistoryDealGetDouble(dealTicket, DEAL_PROFIT)
                        + HistoryDealGetDouble(dealTicket, DEAL_SWAP)
                        + HistoryDealGetDouble(dealTicket, DEAL_COMMISSION);
         }
      }
      OnPositionClosed(lastProfit);
      return;
   }

   HandlePartialCloses();
   if(InpBEAtTP1) HandleBreakEven();
   if(InpTrailAfterBE && beApplied) HandleTrailingStop();
}

void HandlePartialCloses()
{
   if(!SelectMyPosition()) return;

   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double cur = currentIsBuy ? bid : ask;

   bool reachedTP1 = currentIsBuy ? (cur >= currentTP1Price) : (cur <= currentTP1Price);
   bool reachedTP2 = currentIsBuy ? (cur >= currentTP2Price) : (cur <= currentTP2Price);
   bool reachedTP3 = currentIsBuy ? (cur >= currentTP3Price) : (cur <= currentTP3Price);

   if(reachedTP1 && !tp1Hit)
   {
      double volClose = NormalizeLot(currentInitialLots * InpTP1ClosePct / 100.0);
      if(volClose > 0.0)
      {
         double remainingVol = posInfo.Volume();
         if(volClose > remainingVol) volClose = remainingVol;
         if(trade.PositionClosePartial(currentTicket, volClose))
         {
            tp1Hit = true;
            PrintFormat("[DTG_NYR] TP1 hit. Closed %.2f lots.", volClose);
         }
         else
         {
            PrintFormat("[DTG_NYR] TP1 partial close failed. retcode=%d", trade.ResultRetcode());
         }
      }
      else
      {
         tp1Hit = true; // nothing to close, mark as hit
      }
   }

   if(reachedTP2 && !tp2Hit && tp1Hit)
   {
      double volClose = NormalizeLot(currentInitialLots * InpTP2ClosePct / 100.0);
      if(volClose > 0.0 && SelectMyPosition())
      {
         double remainingVol = posInfo.Volume();
         if(volClose > remainingVol) volClose = remainingVol;
         if(trade.PositionClosePartial(currentTicket, volClose))
         {
            tp2Hit = true;
            PrintFormat("[DTG_NYR] TP2 hit. Closed %.2f lots.", volClose);
         }
         else
         {
            PrintFormat("[DTG_NYR] TP2 partial close failed. retcode=%d", trade.ResultRetcode());
         }
      }
      else
      {
         tp2Hit = true;
      }
   }

   if(reachedTP3 && !tp3Hit && tp2Hit)
   {
      if(SelectMyPosition())
      {
         if(trade.PositionClose(currentTicket))
         {
            tp3Hit = true;
            PrintFormat("[DTG_NYR] TP3 hit. Final close.");
         }
         else
         {
            PrintFormat("[DTG_NYR] TP3 close failed. retcode=%d", trade.ResultRetcode());
         }
      }
   }
}

void HandleBreakEven()
{
   if(!tp1Hit || beApplied) return;
   if(!SelectMyPosition()) return;

   double spread = SymbolInfoInteger(_Symbol, SYMBOL_SPREAD) * _Point;
   double newSL  = currentIsBuy ? currentEntry : (currentEntry + spread);
   newSL = NormalizePrice(newSL);
   double curSL = posInfo.StopLoss();

   bool improves = currentIsBuy ? (newSL > curSL) : (curSL == 0.0 || newSL < curSL);
   if(improves)
   {
      if(trade.PositionModify(currentTicket, newSL, posInfo.TakeProfit()))
      {
         beApplied = true;
         currentSL = newSL;
         PrintFormat("[DTG_NYR] BE applied. SL -> %.5f", newSL);
      }
      else
      {
         PrintFormat("[DTG_NYR] BE modify failed. retcode=%d", trade.ResultRetcode());
      }
   }
   else
   {
      beApplied = true; // already at or beyond BE
   }
}

void HandleTrailingStop()
{
   if(!SelectMyPosition()) return;

   datetime barTime = iTime(_Symbol, InpTrailTF, 1);
   if(barTime == 0 || barTime == lastTrailBarTime) return;
   lastTrailBarTime = barTime;

   double prevHigh = iHigh(_Symbol, InpTrailTF, 1);
   double prevLow  = iLow (_Symbol, InpTrailTF, 1);
   if(prevHigh <= 0.0 || prevLow <= 0.0) return;

   double curSL = posInfo.StopLoss();
   double newSL = curSL;

   if(currentIsBuy)
   {
      newSL = prevLow;
      if(newSL > curSL)
      {
         newSL = NormalizePrice(newSL);
         if(trade.PositionModify(currentTicket, newSL, posInfo.TakeProfit()))
         {
            currentSL = newSL;
            PrintFormat("[DTG_NYR] Trail BUY SL -> %.5f (prevLow)", newSL);
         }
      }
   }
   else
   {
      newSL = prevHigh;
      if(curSL == 0.0 || newSL < curSL)
      {
         newSL = NormalizePrice(newSL);
         if(trade.PositionModify(currentTicket, newSL, posInfo.TakeProfit()))
         {
            currentSL = newSL;
            PrintFormat("[DTG_NYR] Trail SELL SL -> %.5f (prevHigh)", newSL);
         }
      }
   }
}

void OnPositionClosed(double profit)
{
   PrintFormat("[DTG_NYR] Position closed. P/L=%.2f", profit);

   if(profit > 0.0 && InpStopOnFirstProfit)
   {
      dayProfitMade = true;
      currentState = STOPPED_FOR_DAY;
      PrintFormat("[DTG_NYR] Profitable close. STOPPED_FOR_DAY.");
   }
   else if(tradeCountToday >= InpMaxTradesPerDay)
   {
      currentState = STOPPED_FOR_DAY;
      PrintFormat("[DTG_NYR] Max trades after close. STOPPED_FOR_DAY.");
   }
   else if(IsTradingWindowOpen())
   {
      currentState = HUNTING_REBREAK;
      // Re-anchor NY extremes at current price; UpdateNYExtremes will expand.
      double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
      double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      if(bid > nyh) nyh = bid;
      if(ask < nyl && ask > 0.0) nyl = ask;
      PrintFormat("[DTG_NYR] Not profitable. HUNTING_REBREAK. NYH=%.5f NYL=%.5f", nyh, nyl);
   }
   else
   {
      currentState = STOPPED_FOR_DAY;
   }

   // Clear tracking
   currentTicket = 0;
   tp1Hit = tp2Hit = tp3Hit = false;
   beApplied = false;
}

//+------------------------------------------------------------------+
//| Position helpers                                                 |
//+------------------------------------------------------------------+
bool SelectMyPosition()
{
   int total = PositionsTotal();
   for(int i = 0; i < total; i++)
   {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if((long)posInfo.Magic() != InpMagicNumber) continue;
      currentTicket = posInfo.Ticket();
      return true;
   }
   return false;
}

void RecoverStateFromOpenPosition()
{
   if(!SelectMyPosition()) return;

   currentTicket      = posInfo.Ticket();
   currentEntry       = posInfo.PriceOpen();
   currentSL          = posInfo.StopLoss();
   currentInitialLots = posInfo.Volume(); // best-effort recovery
   currentIsBuy       = (posInfo.PositionType() == POSITION_TYPE_BUY);

   // Reconstruct TP price ladders from inputs
   currentTP1Price = currentIsBuy ? currentEntry + PipsToPrice(InpTP1Pips) : currentEntry - PipsToPrice(InpTP1Pips);
   currentTP2Price = currentIsBuy ? currentEntry + PipsToPrice(InpTP2Pips) : currentEntry - PipsToPrice(InpTP2Pips);
   currentTP3Price = currentIsBuy ? currentEntry + PipsToPrice(InpTP3Pips) : currentEntry - PipsToPrice(InpTP3Pips);

   // Infer tpFlags from current SL position
   // If SL >= entry (BUY) or SL <= entry (SELL) → TP1 already hit (BE applied).
   if(currentIsBuy && currentSL >= currentEntry - _Point)
   {
      tp1Hit = true; beApplied = true;
   }
   else if(!currentIsBuy && currentSL <= currentEntry + _Point && currentSL > 0.0)
   {
      tp1Hit = true; beApplied = true;
   }

   currentState = IN_TRADE;
   PrintFormat("[DTG_NYR] Recovered position #%I64u %s entry=%.5f SL=%.5f tp1Hit=%s",
               currentTicket, (currentIsBuy ? "BUY" : "SELL"),
               currentEntry, currentSL, (tp1Hit ? "true" : "false"));
}

//+------------------------------------------------------------------+
//| Daily reset                                                      |
//+------------------------------------------------------------------+
void ResetDailyState()
{
   PrintFormat("[DTG_NYR] New broker day. Resetting state.");
   currentState     = PRE_WINDOW;
   dh = 0.0; dl = 0.0;
   nyh = 0.0; nyl = 0.0;
   levelsCaptured   = false;
   nyExtremesInit   = false;
   tradeCountToday  = 0;
   dayProfitMade    = false;
   dailyStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
   ClearLevels();
}

//+------------------------------------------------------------------+
//| Visuals — lines                                                  |
//+------------------------------------------------------------------+
void DrawHLine(string name, double price, color clr, ENUM_LINE_STYLE style, int width)
{
   if(price <= 0.0) { ObjectDelete(0, name); return; }
   if(ObjectFind(0, name) < 0)
   {
      ObjectCreate(0, name, OBJ_HLINE, 0, 0, price);
   }
   ObjectSetDouble (0, name, OBJPROP_PRICE,  price);
   ObjectSetInteger(0, name, OBJPROP_COLOR,  clr);
   ObjectSetInteger(0, name, OBJPROP_STYLE,  style);
   ObjectSetInteger(0, name, OBJPROP_WIDTH,  width);
   ObjectSetInteger(0, name, OBJPROP_BACK,   true);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN, true);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE, false);
}

void DrawLevels()
{
   // DH / DL — solid gold while active
   if(currentState == HUNTING_INITIAL || currentState == IN_TRADE || currentState == HUNTING_REBREAK)
   {
      DrawHLine(LINE_PREFIX + "DH", dh, InpAccentColor, STYLE_SOLID, 1);
      DrawHLine(LINE_PREFIX + "DL", dl, InpAccentColor, STYLE_SOLID, 1);
   }
   else
   {
      ObjectDelete(0, LINE_PREFIX + "DH");
      ObjectDelete(0, LINE_PREFIX + "DL");
   }

   // NYH / NYL — dashed during HUNTING_REBREAK
   if(currentState == HUNTING_REBREAK)
   {
      DrawHLine(LINE_PREFIX + "NYH", nyh, clrSilver, STYLE_DASH, 1);
      DrawHLine(LINE_PREFIX + "NYL", nyl, clrSilver, STYLE_DASH, 1);
   }
   else
   {
      ObjectDelete(0, LINE_PREFIX + "NYH");
      ObjectDelete(0, LINE_PREFIX + "NYL");
   }

   // Active position lines
   if(currentState == IN_TRADE && SelectMyPosition())
   {
      DrawHLine(LINE_PREFIX + "ENTRY", currentEntry, clrWhite, STYLE_DOT, 1);
      DrawHLine(LINE_PREFIX + "SL",    posInfo.StopLoss(), clrRed, STYLE_DOT, 1);
      DrawHLine(LINE_PREFIX + "TP1",   currentTP1Price, clrLime,       STYLE_DOT, 1);
      DrawHLine(LINE_PREFIX + "TP2",   currentTP2Price, clrLimeGreen,  STYLE_DOT, 1);
      DrawHLine(LINE_PREFIX + "TP3",   currentTP3Price, clrSeaGreen,   STYLE_DOT, 1);
   }
   else
   {
      ObjectDelete(0, LINE_PREFIX + "ENTRY");
      ObjectDelete(0, LINE_PREFIX + "SL");
      ObjectDelete(0, LINE_PREFIX + "TP1");
      ObjectDelete(0, LINE_PREFIX + "TP2");
      ObjectDelete(0, LINE_PREFIX + "TP3");
   }
}

void ClearLevels()
{
   string names[] = { "DH","DL","NYH","NYL","ENTRY","SL","TP1","TP2","TP3" };
   for(int i = 0; i < ArraySize(names); i++)
      ObjectDelete(0, LINE_PREFIX + names[i]);
}

//+------------------------------------------------------------------+
//| Visuals — dashboard                                              |
//+------------------------------------------------------------------+
void CreateLabel(string name, int x, int y, string text, color clr, int fontSize, string font="Consolas")
{
   if(ObjectFind(0, name) < 0)
      ObjectCreate(0, name, OBJ_LABEL, 0, 0, 0);
   ObjectSetInteger(0, name, OBJPROP_CORNER,    InpPanelCorner);
   ObjectSetInteger(0, name, OBJPROP_XDISTANCE, x);
   ObjectSetInteger(0, name, OBJPROP_YDISTANCE, y);
   ObjectSetInteger(0, name, OBJPROP_COLOR,     clr);
   ObjectSetInteger(0, name, OBJPROP_FONTSIZE,  fontSize);
   ObjectSetInteger(0, name, OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0, name, OBJPROP_HIDDEN,    true);
   ObjectSetString (0, name, OBJPROP_TEXT,      text);
   ObjectSetString (0, name, OBJPROP_FONT,      font);
}

void CreateDashboard()
{
   string bgName = PANEL_PREFIX + "BG";
   if(ObjectFind(0, bgName) < 0)
      ObjectCreate(0, bgName, OBJ_RECTANGLE_LABEL, 0, 0, 0);
   ObjectSetInteger(0, bgName, OBJPROP_CORNER,    InpPanelCorner);
   ObjectSetInteger(0, bgName, OBJPROP_XDISTANCE, 10);
   ObjectSetInteger(0, bgName, OBJPROP_YDISTANCE, 20);
   ObjectSetInteger(0, bgName, OBJPROP_XSIZE,     310);
   ObjectSetInteger(0, bgName, OBJPROP_YSIZE,     280);
   ObjectSetInteger(0, bgName, OBJPROP_BGCOLOR,   C'18,18,22');
   ObjectSetInteger(0, bgName, OBJPROP_BORDER_TYPE, BORDER_FLAT);
   ObjectSetInteger(0, bgName, OBJPROP_COLOR,     C'60,60,72');
   ObjectSetInteger(0, bgName, OBJPROP_BACK,      false);
   ObjectSetInteger(0, bgName, OBJPROP_SELECTABLE,false);
   ObjectSetInteger(0, bgName, OBJPROP_HIDDEN,    true);

   UpdateDashboard();
}

void DestroyDashboard()
{
   int total = ObjectsTotal(0, -1, -1);
   for(int i = total - 1; i >= 0; i--)
   {
      string n = ObjectName(0, i, -1, -1);
      if(StringFind(n, PANEL_PREFIX) == 0) ObjectDelete(0, n);
   }
}

string StateToString(EA_STATE s)
{
   switch(s)
   {
      case PRE_WINDOW:      return "PRE_WINDOW";
      case HUNTING_INITIAL: return "HUNTING_INITIAL";
      case IN_TRADE:        return "IN_TRADE";
      case HUNTING_REBREAK: return "HUNTING_REBREAK";
      case STOPPED_FOR_DAY: return "STOPPED_FOR_DAY";
   }
   return "UNKNOWN";
}

string FormatCountdown()
{
   datetime now = TimeCurrent();
   datetime open  = GetNYAnchorTime(now);
   datetime close = GetNYCloseTime(now);
   if(close <= open) close += 24*60*60;
   long secs;
   string lbl;
   if(now < open)        { secs = (long)(open  - now); lbl = "to open";  }
   else if(now < close)  { secs = (long)(close - now); lbl = "to close"; }
   else                  { secs = 0;                   lbl = "closed";   }
   long h = secs / 3600;
   long m = (secs % 3600) / 60;
   long s = secs % 60;
   return StringFormat("%02d:%02d:%02d %s", (int)h, (int)m, (int)s, lbl);
}

void UpdateDashboard()
{
   if(!InpShowDashboard) return;
   if(ObjectFind(0, PANEL_PREFIX + "BG") < 0) CreateDashboard();

   const int xCol1 = 22;
   const int xCol2 = 165;
   int y = 30;
   const int dy = 18;
   const color clrLbl  = C'160,160,170';
   const color clrVal  = C'235,235,240';
   const color clrAcc  = InpAccentColor;
   const color clrDim  = C'120,120,128';

   CreateLabel(PANEL_PREFIX + "T1", xCol1, y, "DTG NY REBREAK", clrAcc, 10, "Consolas");
   y += dy + 2;

   CreateLabel(PANEL_PREFIX + "L_State", xCol1, y, "State", clrLbl, 9);
   CreateLabel(PANEL_PREFIX + "V_State", xCol2, y, StateToString(currentState), clrAcc, 9);
   y += dy;

   CreateLabel(PANEL_PREFIX + "L_Win",   xCol1, y, "Window", clrLbl, 9);
   CreateLabel(PANEL_PREFIX + "V_Win",   xCol2, y, FormatCountdown(), clrVal, 9);
   y += dy;

   CreateLabel(PANEL_PREFIX + "L_DH",    xCol1, y, "DH / DL", clrLbl, 9);
   string dhdl = (levelsCaptured)
                 ? StringFormat("%.5f / %.5f", dh, dl)
                 : "— / —";
   CreateLabel(PANEL_PREFIX + "V_DH",    xCol2, y, dhdl, clrVal, 9);
   y += dy;

   CreateLabel(PANEL_PREFIX + "L_NY",    xCol1, y, "NYH / NYL", clrLbl, 9);
   string ny = (currentState == HUNTING_REBREAK)
               ? StringFormat("%.5f / %.5f", nyh, nyl)
               : "— / —";
   CreateLabel(PANEL_PREFIX + "V_NY",    xCol2, y, ny, clrVal, 9);
   y += dy;

   // Active position rows
   bool inPos = SelectMyPosition();
   CreateLabel(PANEL_PREFIX + "L_Pos",   xCol1, y, "Position", clrLbl, 9);
   string posStr = "—";
   double pnlAcc = 0.0;
   double pnlPips = 0.0;
   if(inPos)
   {
      string side = (currentIsBuy ? "BUY" : "SELL");
      pnlAcc  = posInfo.Profit() + posInfo.Swap() + posInfo.Commission();
      double curPrice = currentIsBuy ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                                     : SymbolInfoDouble(_Symbol, SYMBOL_ASK);
      double diff = currentIsBuy ? (curPrice - currentEntry) : (currentEntry - curPrice);
      pnlPips = PriceToPips(diff);
      posStr = StringFormat("%s %.2f @ %.5f", side, posInfo.Volume(), currentEntry);
   }
   CreateLabel(PANEL_PREFIX + "V_Pos",   xCol2, y, posStr, clrVal, 9);
   y += dy;

   CreateLabel(PANEL_PREFIX + "L_SL",    xCol1, y, "SL", clrLbl, 9);
   CreateLabel(PANEL_PREFIX + "V_SL",    xCol2, y, inPos ? StringFormat("%.5f", posInfo.StopLoss()) : "—",
               clrVal, 9);
   y += dy;

   string tp1Mk = tp1Hit ? "OK" : "—";
   string tp2Mk = tp2Hit ? "OK" : "—";
   string tp3Mk = tp3Hit ? "OK" : "—";
   CreateLabel(PANEL_PREFIX + "L_TP",    xCol1, y, "TP1/2/3", clrLbl, 9);
   string tps = inPos
                ? StringFormat("%.5f %s | %.5f %s | %.5f %s",
                               currentTP1Price, tp1Mk,
                               currentTP2Price, tp2Mk,
                               currentTP3Price, tp3Mk)
                : "—";
   CreateLabel(PANEL_PREFIX + "V_TP",    xCol2, y, tps, clrVal, 8);
   y += dy;

   CreateLabel(PANEL_PREFIX + "L_PnL",   xCol1, y, "P/L (pos)", clrLbl, 9);
   string posPnl = inPos
                   ? StringFormat("%.2f  (%.1f pips)", pnlAcc, pnlPips)
                   : "—";
   CreateLabel(PANEL_PREFIX + "V_PnL",   xCol2, y,
               posPnl,
               (pnlAcc >= 0.0 ? clrAcc : C'220,90,90'), 9);
   y += dy;

   // Daily P/L
   double eq = AccountInfoDouble(ACCOUNT_EQUITY);
   double dayPnl = eq - dailyStartEquity;
   double dayPct = (dailyStartEquity > 0.0) ? (dayPnl / dailyStartEquity * 100.0) : 0.0;
   CreateLabel(PANEL_PREFIX + "L_Day",   xCol1, y, "Daily P/L", clrLbl, 9);
   CreateLabel(PANEL_PREFIX + "V_Day",   xCol2, y,
               StringFormat("%.2f  (%.2f%%)", dayPnl, dayPct),
               (dayPnl >= 0.0 ? clrAcc : C'220,90,90'), 9);
   y += dy;

   CreateLabel(PANEL_PREFIX + "L_Trd",   xCol1, y, "Trades", clrLbl, 9);
   CreateLabel(PANEL_PREFIX + "V_Trd",   xCol2, y,
               StringFormat("%d / %d", tradeCountToday, InpMaxTradesPerDay),
               clrVal, 9);
   y += dy;

   double atr = GetATR();
   CreateLabel(PANEL_PREFIX + "L_ATR",   xCol1, y, "ATR", clrLbl, 9);
   CreateLabel(PANEL_PREFIX + "V_ATR",   xCol2, y,
               StringFormat("%.5f", atr), clrVal, 9);
   y += dy;

   CreateLabel(PANEL_PREFIX + "L_Pip",   xCol1, y, "Pip size", clrLbl, 9);
   CreateLabel(PANEL_PREFIX + "V_Pip",   xCol2, y,
               StringFormat("%.5f", cachedPipSize), clrDim, 9);
   y += dy;
}

//+------------------------------------------------------------------+
