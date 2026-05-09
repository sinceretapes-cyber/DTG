//+------------------------------------------------------------------+
//|                                          CandleSpikeScalper.mq5 |
//|                                                              DTG |
//|                  Multi-timeframe candle break / spike scalper.   |
//+------------------------------------------------------------------+
#property copyright "DTG"
#property link      ""
#property version   "1.00"
#property description "Multi-timeframe candle break scalper."
#property description "On each new H4/H6/H8/H12/D1/W1 bar it inspects the previously-closed candle on that timeframe."
#property description " - Bullish close -> Buy Stop just above the high"
#property description " - Bearish close -> Sell Stop just below the low"
#property description "Each timeframe is treated independently (own magic number) so opposing trades across TFs"
#property description "can run side by side. Aggressive management: at the spike target a configurable % is"
#property description "closed and the runner's SL is moved to break even."

#include <Trade\Trade.mqh>
#include <Trade\PositionInfo.mqh>
#include <Trade\OrderInfo.mqh>
#include <Trade\SymbolInfo.mqh>

//==================================================================
// Inputs
//==================================================================
enum ENUM_SL_MODE
  {
   SL_FIXED_PIPS,    // Fixed pip distance
   SL_M1_CANDLE      // Beyond previous M1 candle low/high
  };

enum ENUM_LOT_MODE
  {
   LOT_FIXED,        // Fixed lot size
   LOT_RISK_PCT      // % of balance risked per trade (uses actual SL distance)
  };

input group                "=== Timeframes ==="
input bool   InpUseH4              = true;     // Trade H4
input bool   InpUseH6              = true;     // Trade H6
input bool   InpUseH8              = true;     // Trade H8
input bool   InpUseH12             = true;     // Trade H12
input bool   InpUseD1              = true;     // Trade D1
input bool   InpUseW1              = true;     // Trade W1

input group                "=== Entry ==="
input double InpOffsetPips         = 1.0;      // Pips offset above high / below low for the stop trigger
input bool   InpExpirePending      = true;     // Cancel un-triggered pending when a new bar of that TF appears
input bool   InpUsePendingExpiry   = true;     // Set broker-side expiry on the pending order
input int    InpPendingExpiryBars  = 1;        // Pending expiry length in bars of the entry timeframe

input group                "=== Stop loss ==="
input ENUM_SL_MODE InpSLMode       = SL_FIXED_PIPS; // SL placement mode
input double InpStopLossPips       = 15.0;     // Fixed SL distance (pips) when SL_FIXED_PIPS
input double InpM1BufferPips       = 1.0;      // Extra pips beyond M1 low/high when SL_M1_CANDLE
input double InpMinSLPips          = 4.0;      // Minimum SL distance (safety floor, pips)
input double InpMaxSLPips          = 60.0;     // Maximum SL distance (safety cap, pips)

input group                "=== Take profit / partial close ==="
input double InpPartialTriggerPips = 12.0;     // Profit (pips) at which to take partial + move runner to BE
input double InpPartialClosePct    = 90.0;     // % of position closed at the partial trigger
input bool   InpMoveToBreakEven    = true;     // Move SL to break-even after partial close
input double InpBreakEvenPaddingPips = 1.0;    // Pips beyond entry to lock in (covers spread/commission)
input double InpFinalTPPips        = 0.0;      // Hard TP for the runner in pips (0 = no TP, let it run)

input group                "=== Sizing / risk ==="
input ENUM_LOT_MODE InpLotMode     = LOT_FIXED; // Lot sizing mode
input double InpFixedLot           = 0.10;     // Fixed lot size
input double InpRiskPercent        = 1.0;      // % of balance risked per trade (LOT_RISK_PCT)
input double InpMaxLot             = 5.0;      // Hard cap on computed lot size

input group                "=== Misc ==="
input long   InpMagicBase          = 73310000; // Base magic number (per-TF offset added)
input string InpComment            = "CSS";    // Comment prefix on orders
input ulong  InpDeviationPoints    = 20;       // Max slippage on management closes (points)
input bool   InpVerboseLog         = true;     // Print detailed log

//==================================================================
// Globals
//==================================================================
CTrade         trade;
CPositionInfo  posInfo;
COrderInfo     ordInfo;
CSymbolInfo    symInfo;

// Timeframes we manage and per-TF state
ENUM_TIMEFRAMES gTFs[]      = { PERIOD_H4, PERIOD_H6, PERIOD_H8, PERIOD_H12, PERIOD_D1, PERIOD_W1 };
bool            gEnabled[6];
datetime        gLastBar[6];
long            gMagic[6];

//==================================================================
// Utility helpers
//==================================================================
double PipSize()
  {
   int    digits = (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   if(digits == 3 || digits == 5)
      return point * 10.0;
   return point;
  }

double PipsToPrice(double pips) { return pips * PipSize(); }
double PriceToPips(double price){ double p = PipSize(); return (p>0.0) ? price / p : 0.0; }

long MagicForTF(ENUM_TIMEFRAMES tf)
  {
   // Period seconds is unique per timeframe so we get unique, deterministic magics per TF.
   return InpMagicBase + (long)PeriodSeconds(tf);
  }

string TFName(ENUM_TIMEFRAMES tf) { return EnumToString(tf); }

double NormalizePrice(double p)
  {
   double tick = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tick <= 0.0) tick = SymbolInfoDouble(_Symbol, SYMBOL_POINT);
   return MathRound(p / tick) * tick;
  }

double NormalizeVolume(double vol)
  {
   double step = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_STEP);
   double minV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
   double maxV = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MAX);
   if(step <= 0.0) step = 0.01;

   double v = MathFloor(vol / step) * step;
   if(v < minV) v = 0.0;          // signal that volume is below the broker minimum
   if(v > maxV) v = maxV;
   // round to step precision
   int stepDigits = 2;
   if(step >= 1.0)        stepDigits = 0;
   else if(step >= 0.1)   stepDigits = 1;
   else if(step >= 0.01)  stepDigits = 2;
   else                   stepDigits = 3;
   v = NormalizeDouble(v, stepDigits);
   return v;
  }

double LotForRisk(double slDistancePrice)
  {
   if(slDistancePrice <= 0.0) return 0.0;

   double balance   = AccountInfoDouble(ACCOUNT_BALANCE);
   double riskMoney = balance * InpRiskPercent / 100.0;

   double tickValue = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_VALUE);
   double tickSize  = SymbolInfoDouble(_Symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0) return 0.0;

   double moneyPerLot = (slDistancePrice / tickSize) * tickValue;
   if(moneyPerLot <= 0.0) return 0.0;

   double lots = riskMoney / moneyPerLot;
   if(lots > InpMaxLot) lots = InpMaxLot;
   return NormalizeVolume(lots);
  }

double ChooseLotSize(double slDistancePrice)
  {
   double lot = (InpLotMode == LOT_FIXED) ? InpFixedLot : LotForRisk(slDistancePrice);
   if(lot > InpMaxLot) lot = InpMaxLot;
   return NormalizeVolume(lot);
  }

bool IsOurMagic(long m)
  {
   for(int i=0;i<ArraySize(gMagic);++i)
      if(gMagic[i] == m) return true;
   return false;
  }

int IndexForMagic(long m)
  {
   for(int i=0;i<ArraySize(gMagic);++i)
      if(gMagic[i] == m) return i;
   return -1;
  }

//==================================================================
// Pending / position bookkeeping
//==================================================================
bool HasOpenPositionForMagic(long magic)
  {
   for(int i = PositionsTotal()-1; i >= 0; --i)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      if((long)posInfo.Magic() == magic) return true;
     }
   return false;
  }

void CancelPendingsForMagic(long magic)
  {
   for(int i = OrdersTotal()-1; i >= 0; --i)
     {
      if(!ordInfo.SelectByIndex(i)) continue;
      if(ordInfo.Symbol() != _Symbol) continue;
      if((long)ordInfo.Magic() != magic) continue;
      ulong ticket = ordInfo.Ticket();
      if(!trade.OrderDelete(ticket))
         PrintFormat("[CSS] Failed to cancel pending #%I64u err=%d", ticket, GetLastError());
      else if(InpVerboseLog)
         PrintFormat("[CSS] Cancelled stale pending #%I64u (magic=%I64d)", ticket, magic);
     }
  }

//==================================================================
// Signal generation per timeframe
//==================================================================
void ProcessTimeframe(int idx)
  {
   if(!gEnabled[idx]) return;

   ENUM_TIMEFRAMES tf = gTFs[idx];
   datetime curBar    = (datetime)iTime(_Symbol, tf, 0);
   if(curBar == 0) return;            // history not ready

   // Initialise on first run: no signal placed, just record current bar.
   if(gLastBar[idx] == 0)
     {
      gLastBar[idx] = curBar;
      return;
     }

   if(curBar == gLastBar[idx]) return; // no new bar yet

   gLastBar[idx] = curBar;
   long magic    = gMagic[idx];

   // Refresh pendings on the new bar.
   if(InpExpirePending)
      CancelPendingsForMagic(magic);

   // Don't open another order while a prior position from this TF is still alive.
   if(HasOpenPositionForMagic(magic))
     {
      if(InpVerboseLog)
         PrintFormat("[CSS][%s] New bar but a position is still open – skipping new pending.", TFName(tf));
      return;
     }

   // Just-closed candle is bar 1 (bar 0 is the freshly-opened one).
   double openPrev  = iOpen (_Symbol, tf, 1);
   double closePrev = iClose(_Symbol, tf, 1);
   double highPrev  = iHigh (_Symbol, tf, 1);
   double lowPrev   = iLow  (_Symbol, tf, 1);

   if(openPrev == 0 || closePrev == 0) return;

   bool bullish = (closePrev > openPrev);
   bool bearish = (closePrev < openPrev);
   if(!bullish && !bearish)
     {
      if(InpVerboseLog)
         PrintFormat("[CSS][%s] Doji previous candle – no trade.", TFName(tf));
      return;
     }

   double offset    = PipsToPrice(InpOffsetPips);
   double entry     = bullish ? (highPrev + offset) : (lowPrev - offset);
   entry            = NormalizePrice(entry);

   // Require the trigger to still be on the right side of price; otherwise the candle has already
   // sped past the level and we'd just chase it.
   double ask = SymbolInfoDouble(_Symbol, SYMBOL_ASK);
   double bid = SymbolInfoDouble(_Symbol, SYMBOL_BID);
   long   stopLevelPts = SymbolInfoInteger(_Symbol, SYMBOL_TRADE_STOPS_LEVEL);
   double stopLevel    = stopLevelPts * SymbolInfoDouble(_Symbol, SYMBOL_POINT);

   if(bullish && entry <= ask + stopLevel)
     {
      if(InpVerboseLog)
         PrintFormat("[CSS][%s] Buy stop trigger %.5f already at/below ask %.5f (stops=%.5f) – skip.",
                     TFName(tf), entry, ask, stopLevel);
      return;
     }
   if(bearish && entry >= bid - stopLevel)
     {
      if(InpVerboseLog)
         PrintFormat("[CSS][%s] Sell stop trigger %.5f already at/above bid %.5f (stops=%.5f) – skip.",
                     TFName(tf), entry, bid, stopLevel);
      return;
     }

   // Compute SL.
   double slPrice = 0.0;
   if(InpSLMode == SL_FIXED_PIPS)
     {
      double slDist = PipsToPrice(InpStopLossPips);
      slPrice = bullish ? entry - slDist : entry + slDist;
     }
   else // SL_M1_CANDLE
     {
      double m1Low  = iLow (_Symbol, PERIOD_M1, 1);
      double m1High = iHigh(_Symbol, PERIOD_M1, 1);
      double bufPx  = PipsToPrice(InpM1BufferPips);
      if(bullish)
        {
         slPrice = m1Low - bufPx;
         if(slPrice >= entry) // M1 low above the trigger – fall back to fixed pips
            slPrice = entry - PipsToPrice(InpStopLossPips);
        }
      else
        {
         slPrice = m1High + bufPx;
         if(slPrice <= entry)
            slPrice = entry + PipsToPrice(InpStopLossPips);
        }
     }

   // Apply min / max SL guards.
   double slDistPips = MathAbs(entry - slPrice) / PipSize();
   if(slDistPips < InpMinSLPips)
      slPrice = bullish ? entry - PipsToPrice(InpMinSLPips) : entry + PipsToPrice(InpMinSLPips);
   if(slDistPips > InpMaxSLPips)
      slPrice = bullish ? entry - PipsToPrice(InpMaxSLPips) : entry + PipsToPrice(InpMaxSLPips);
   slPrice = NormalizePrice(slPrice);

   double slDistPrice = MathAbs(entry - slPrice);
   double tpPrice     = 0.0;
   if(InpFinalTPPips > 0.0)
      tpPrice = NormalizePrice(bullish ? entry + PipsToPrice(InpFinalTPPips)
                                       : entry - PipsToPrice(InpFinalTPPips));

   double lots = ChooseLotSize(slDistPrice);
   if(lots <= 0.0)
     {
      PrintFormat("[CSS][%s] Computed lot size is below broker minimum – skip.", TFName(tf));
      return;
     }

   datetime expiry = 0;
   ENUM_ORDER_TYPE_TIME tt = ORDER_TIME_GTC;
   if(InpUsePendingExpiry && InpPendingExpiryBars > 0)
     {
      int secs = PeriodSeconds(tf) * InpPendingExpiryBars;
      expiry   = curBar + secs;
      tt       = ORDER_TIME_SPECIFIED;
     }

   trade.SetExpertMagicNumber((ulong)magic);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   string cmt = StringFormat("%s|%s", InpComment, TFName(tf));

   bool ok = false;
   if(bullish)
      ok = trade.BuyStop(lots, entry, _Symbol, slPrice, tpPrice, tt, expiry, cmt);
   else
      ok = trade.SellStop(lots, entry, _Symbol, slPrice, tpPrice, tt, expiry, cmt);

   if(!ok)
     {
      PrintFormat("[CSS][%s] Pending placement failed: ret=%d  err=%d  entry=%.5f  sl=%.5f  lots=%.2f",
                  TFName(tf), trade.ResultRetcode(), GetLastError(), entry, slPrice, lots);
     }
   else
     {
      PrintFormat("[CSS][%s] %s STOP placed @ %.5f  SL=%.5f  TP=%.5f  lots=%.2f  magic=%I64d",
                  TFName(tf), bullish?"BUY":"SELL", entry, slPrice, tpPrice, lots, magic);
     }
  }

//==================================================================
// Open position management: partial close + break even
//==================================================================
void ManageOpenPositions()
  {
   double pip = PipSize();
   if(pip <= 0.0) return;

   for(int i = PositionsTotal()-1; i >= 0; --i)
     {
      if(!posInfo.SelectByIndex(i)) continue;
      if(posInfo.Symbol() != _Symbol) continue;
      long magic = (long)posInfo.Magic();
      if(!IsOurMagic(magic)) continue;

      ENUM_POSITION_TYPE type = posInfo.PositionType();
      double entry = posInfo.PriceOpen();
      double sl    = posInfo.StopLoss();
      double tp    = posInfo.TakeProfit();
      double vol   = posInfo.Volume();
      ulong  ticket= posInfo.Ticket();

      double mkt   = (type == POSITION_TYPE_BUY)
                     ? SymbolInfoDouble(_Symbol, SYMBOL_BID)
                     : SymbolInfoDouble(_Symbol, SYMBOL_ASK);

      double profitPips = (type == POSITION_TYPE_BUY)
                          ? (mkt - entry) / pip
                          : (entry - mkt) / pip;

      if(profitPips < InpPartialTriggerPips) continue;

      // Detect "partial / BE already done" via SL position relative to entry.
      // After BE: BUY  has sl >= entry (sl moved up from below)
      //          SELL has sl <= entry (sl moved down from above)
      double bePad   = PipsToPrice(InpBreakEvenPaddingPips);
      double beLevel = (type == POSITION_TYPE_BUY) ? entry + bePad : entry - bePad;
      double tol     = SymbolInfoDouble(_Symbol, SYMBOL_POINT) * 0.5;
      bool beAlreadyDone =
         (type == POSITION_TYPE_BUY  && sl > 0.0 && sl >= entry - tol) ||
         (type == POSITION_TYPE_SELL && sl > 0.0 && sl <= entry + tol);

      if(beAlreadyDone) continue;

      // Partial close.
      double pct      = MathMax(0.0, MathMin(100.0, InpPartialClosePct));
      double minVol   = SymbolInfoDouble(_Symbol, SYMBOL_VOLUME_MIN);
      // Cap requested close volume so the remainder is still a valid trade volume.
      double maxClose = vol - minVol;
      double target   = vol * pct / 100.0;
      if(target > maxClose) target = maxClose;
      double closeVol = NormalizeVolume(target);
      double remainder= vol - closeVol;
      double volEps   = 1e-8;

      trade.SetExpertMagicNumber((ulong)magic);
      trade.SetDeviationInPoints(InpDeviationPoints);

      bool partialDone = false;
      if(closeVol >= minVol - volEps && remainder >= minVol - volEps && closeVol < vol - volEps)
        {
         if(trade.PositionClosePartial(ticket, closeVol))
           {
            partialDone = true;
            PrintFormat("[CSS] Partial close %.2f of %.2f on #%I64u @ +%.1f pips",
                        closeVol, vol, ticket, profitPips);
           }
         else
           {
            PrintFormat("[CSS] Partial close failed on #%I64u: ret=%d  err=%d",
                        ticket, trade.ResultRetcode(), GetLastError());
           }
        }
      else
        {
         // Position too small to split: just move to BE so the runner is risk-free.
         partialDone = true;
         if(InpVerboseLog)
            PrintFormat("[CSS] Skipping partial on #%I64u – volume too small to split (vol=%.2f, min=%.2f)",
                        ticket, vol, minVol);
        }

      if(partialDone && InpMoveToBreakEven)
        {
         double newSL = NormalizePrice(beLevel);
         // Preserve TP, only modify SL.
         if(!trade.PositionModify(ticket, newSL, tp))
           {
            PrintFormat("[CSS] BE modify failed on #%I64u: ret=%d  err=%d",
                        ticket, trade.ResultRetcode(), GetLastError());
           }
         else if(InpVerboseLog)
           {
            PrintFormat("[CSS] Moved SL to break-even on #%I64u (sl=%.5f)", ticket, newSL);
           }
        }
     }
  }

//==================================================================
// Init / deinit / OnTick
//==================================================================
int OnInit()
  {
   if(!symInfo.Name(_Symbol)) symInfo.Name(_Symbol);

   bool flags[6] = { InpUseH4, InpUseH6, InpUseH8, InpUseH12, InpUseD1, InpUseW1 };
   for(int i=0;i<6;++i)
     {
      gEnabled[i] = flags[i];
      gLastBar[i] = 0;
      gMagic[i]   = MagicForTF(gTFs[i]);
     }

   trade.SetExpertMagicNumber((ulong)InpMagicBase);
   trade.SetDeviationInPoints(InpDeviationPoints);
   trade.SetTypeFillingBySymbol(_Symbol);

   PrintFormat("[CSS] Init OK. Symbol=%s pip=%.5f point=%.5f digits=%d",
               _Symbol, PipSize(),
               SymbolInfoDouble(_Symbol, SYMBOL_POINT),
               (int)SymbolInfoInteger(_Symbol, SYMBOL_DIGITS));

   for(int i=0;i<6;++i)
      if(gEnabled[i])
         PrintFormat("[CSS]   %-8s magic=%I64d", TFName(gTFs[i]), gMagic[i]);

   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   PrintFormat("[CSS] Deinit reason=%d", reason);
  }

void OnTick()
  {
   for(int i=0;i<6;++i)
      ProcessTimeframe(i);

   ManageOpenPositions();
  }

//+------------------------------------------------------------------+
