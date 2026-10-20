//+------------------------------------------------------------------+
//| VCG_Gold_EA.mq5                                                   |
//| Gold (XAUUSD) trend-pullback Expert Advisor.                      |
//|                                                                    |
//| Logic (evaluated once per new bar, on COMPLETED bars):             |
//|  TREND     : price vs EMA(200), and EMA(20) vs EMA(50) alignment   |
//|  STRENGTH  : ADX(14) must be above InpADXMin (skip choppy markets) |
//|  ENTRY     : RSI(14) pulls back then crosses back through a level  |
//|              LONG  = RSI crosses UP through InpRSILongLevel (40)   |
//|              SHORT = RSI crosses DOWN through InpRSIShortLevel(60) |
//|  EXITS     : ATR-based stop loss + take profit, optional ATR trail |
//|  SIZING    : risk InpRiskPct % of equity per trade from SL distance|
//|                                                                    |
//| Live/demo accounts are SIGNAL-ONLY unless InpLiveTrading = true.   |
//| In the Strategy Tester orders are always simulated.                |
//| No strategy guarantees profit - backtest, then forward-test on a   |
//| demo account before risking real money.                            |
//+------------------------------------------------------------------+
#property copyright "Built for MoraMakhlouf"
#property version   "1.00"
#property description "Gold trend-pullback EA: EMA trend + ADX + RSI pullback, ATR stops, risk-based sizing."

#define EA_MAGIC 20260920

//================================ INPUTS =============================
input string          InpSymbol         = "XAUUSD";   // Gold symbol on VCG (auto-detected by description "Gold" if not found)
input ENUM_TIMEFRAMES InpTF             = PERIOD_H1;  // Signal timeframe

input int    InpEMATrend      = 200;    // Long-term trend EMA
input int    InpEMAFast       = 20;     // Fast EMA
input int    InpEMASlow       = 50;     // Slow EMA
input int    InpRSIPeriod     = 14;     // RSI period
input int    InpRSILongLevel  = 40;     // Long entry: RSI crosses UP through this level (in uptrend)
input int    InpRSIShortLevel = 60;     // Short entry: RSI crosses DOWN through this level (in downtrend)
input int    InpADXPeriod     = 14;     // ADX period
input double InpADXMin        = 20.0;   // Minimum ADX (trend strength)
input int    InpATRPeriod     = 14;     // ATR period

input double InpSLATR         = 1.5;    // Stop loss = this many ATR
input double InpTPATR         = 3.0;    // Take profit = this many ATR (3.0 / 1.5 = 1:2 risk/reward)
input bool   InpUseTrail      = true;   // Trail the stop once in profit
input double InpTrailStartATR = 1.5;    // Start trailing after this many ATR of profit
input double InpTrailDistATR  = 1.0;    // Trail distance in ATR

input double InpRiskPct       = 1.0;    // % of equity risked per trade
input bool   InpAllowLong     = true;
input bool   InpAllowShort    = true;
input bool   InpUseTimeFilter = true;   // Only open trades within the hours below (server time)
input int    InpStartHour     = 7;
input int    InpEndHour       = 20;
input int    InpMaxSpreadPts  = 0;      // Skip entries if spread (points) is above this. 0 = no limit

input bool   InpLiveTrading   = false;  // false = signals only on real accounts. true = real orders. (Tester always simulates)

//================================ STATE ===============================
string   g_sym = "";
int      hEmaTrend = INVALID_HANDLE, hEmaFast = INVALID_HANDLE, hEmaSlow = INVALID_HANDLE;
int      hRsi = INVALID_HANDLE, hAdx = INVALID_HANDLE, hAtr = INVALID_HANDLE;
datetime g_lastBar = 0;
double   g_atr = 0.0;

//+------------------------------------------------------------------+
bool TradingEnabled()
  {
   return InpLiveTrading || (bool)MQLInfoInteger(MQL_TESTER);
  }

//+------------------------------------------------------------------+
int StringFindNoCase(const string haystack, const string needle)
  {
   string h = haystack;
   string n = needle;
   StringToLower(h);
   StringToLower(n);
   return StringFind(h, n);
  }

//+------------------------------------------------------------------+
bool ResolveSymbol()
  {
   if(SymbolSelect(InpSymbol, true))
     {
      g_sym = InpSymbol;
      return true;
     }
   string cand[] = {"XAUUSD", "GOLD", "XAUUSD.", "XAU/USD", "GOLDUSD"};
   for(int i = 0; i < ArraySize(cand); i++)
      if(SymbolSelect(cand[i], true))
        {
         g_sym = cand[i];
         return true;
        }
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, false);
      string desc = SymbolInfoString(name, SYMBOL_DESCRIPTION);
      if(StringFindNoCase(desc, "Gold") >= 0 && StringFindNoCase(desc, "Mining") < 0 && StringFindNoCase(desc, "Index") < 0)
        {
         Print("Gold candidate: ", name, " [", desc, "]");
         if(SymbolSelect(name, true))
           {
            g_sym = name;
            return true;
           }
        }
     }
   return false;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ResolveSymbol())
     {
      Print("ERROR: gold symbol not found. Type the exact VCG gold symbol name into InpSymbol.");
      return(INIT_FAILED);
     }

   hEmaTrend = iMA(g_sym, InpTF, InpEMATrend, 0, MODE_EMA, PRICE_CLOSE);
   hEmaFast  = iMA(g_sym, InpTF, InpEMAFast,  0, MODE_EMA, PRICE_CLOSE);
   hEmaSlow  = iMA(g_sym, InpTF, InpEMASlow,  0, MODE_EMA, PRICE_CLOSE);
   hRsi      = iRSI(g_sym, InpTF, InpRSIPeriod, PRICE_CLOSE);
   hAdx      = iADX(g_sym, InpTF, InpADXPeriod);
   hAtr      = iATR(g_sym, InpTF, InpATRPeriod);
   if(hEmaTrend == INVALID_HANDLE || hEmaFast == INVALID_HANDLE || hEmaSlow == INVALID_HANDLE ||
      hRsi == INVALID_HANDLE || hAdx == INVALID_HANDLE || hAtr == INVALID_HANDLE)
     {
      Print("ERROR: could not create indicator handles for ", g_sym);
      return(INIT_FAILED);
     }

   Print("VCG Gold EA v1.00 started on ", g_sym, " ", EnumToString(InpTF),
         " | Risk/trade=", DoubleToString(InpRiskPct, 2), "% | SL=", DoubleToString(InpSLATR, 1), "xATR TP=",
         DoubleToString(InpTPATR, 1), "xATR | Order placement=",
         (TradingEnabled() ? "ON (tester or InpLiveTrading=true)" : "OFF (signal only)"));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   int h[] = {0, 0, 0, 0, 0, 0};
   h[0] = hEmaTrend; h[1] = hEmaFast; h[2] = hEmaSlow; h[3] = hRsi; h[4] = hAdx; h[5] = hAtr;
   for(int i = 0; i < 6; i++)
      if(h[i] != INVALID_HANDLE)
         IndicatorRelease(h[i]);
  }

//+------------------------------------------------------------------+
bool GetBuf(const int handle, const int shift, const int count, double &out[])
  {
   ArraySetAsSeries(out, true);
   return (CopyBuffer(handle, 0, shift, count, out) == count);
  }

//+------------------------------------------------------------------+
bool HasPosition(ulong &ticket)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      string s = PositionGetSymbol(i);
      if(s != g_sym)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != EA_MAGIC)
         continue;
      ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
ENUM_ORDER_TYPE_FILLING GetFillingMode(const string symbol)
  {
   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

//+------------------------------------------------------------------+
double CalcLots(const double entry, const double sl, const ENUM_ORDER_TYPE type)
  {
   double tickSize  = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_SIZE);
   double tickValue = SymbolInfoDouble(g_sym, SYMBOL_TRADE_TICK_VALUE);
   double minLot    = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double maxLot    = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
   double step      = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   if(tickSize <= 0 || tickValue <= 0 || step <= 0)
      return 0.0;

   double riskMoney  = AccountInfoDouble(ACCOUNT_EQUITY) * InpRiskPct / 100.0;
   double lossPerLot = MathAbs(entry - sl) / tickSize * tickValue;
   if(lossPerLot <= 0)
      return 0.0;

   double lots = MathFloor(riskMoney / lossPerLot / step) * step;
   if(lots > maxLot)
      lots = maxLot;

   // never exceed ~90% of free margin
   double margin = 0.0;
   double free   = AccountInfoDouble(ACCOUNT_MARGIN_FREE) * 0.9;
   while(lots >= minLot && OrderCalcMargin(type, g_sym, lots, entry, margin) && margin > free)
      lots = MathFloor((lots * 0.8) / step) * step;

   if(lots < minLot)
      return 0.0;
   return NormalizeDouble(lots, 2);
  }

//+------------------------------------------------------------------+
bool OpenTrade(const bool isBuy, const double atr)
  {
   int    digits = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   double point  = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   double minDist = (double)SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double entry  = isBuy ? SymbolInfoDouble(g_sym, SYMBOL_ASK) : SymbolInfoDouble(g_sym, SYMBOL_BID);
   if(entry <= 0)
      return false;

   double slDist = MathMax(InpSLATR * atr, minDist + 10 * point);
   double tpDist = MathMax(InpTPATR * atr, minDist + 10 * point);
   double sl = isBuy ? entry - slDist : entry + slDist;
   double tp = isBuy ? entry + tpDist : entry - tpDist;
   sl = NormalizeDouble(sl, digits);
   tp = NormalizeDouble(tp, digits);

   double lots = CalcLots(entry, sl, isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(lots <= 0)
     {
      Print("Lot size too small for the risk setting - trade skipped.");
      return false;
     }

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = g_sym;
   req.volume       = lots;
   req.type         = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price        = entry;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = 30;
   req.magic        = EA_MAGIC;
   req.comment      = "VCG Gold EA";
   req.type_filling = GetFillingMode(g_sym);
   req.type_time    = ORDER_TIME_GTC;

   bool sent = OrderSend(req, res);
   if(!sent || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED))
     {
      Print("Order FAILED ", (isBuy ? "BUY" : "SELL"), " ", g_sym, " retcode=", res.retcode, " comment=", res.comment);
      return false;
     }
   Print((isBuy ? "BUY " : "SELL "), DoubleToString(lots, 2), " ", g_sym, " @", DoubleToString(entry, digits),
         " SL=", DoubleToString(sl, digits), " TP=", DoubleToString(tp, digits));
   return true;
  }

//+------------------------------------------------------------------+
void TrailStop(const ulong ticket)
  {
   if(!InpUseTrail || g_atr <= 0 || !PositionSelectByTicket(ticket))
      return;

   int    digits  = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   double minDist = (double)SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double open    = PositionGetDouble(POSITION_PRICE_OPEN);
   double curSL   = PositionGetDouble(POSITION_SL);
   double curTP   = PositionGetDouble(POSITION_TP);
   long   type    = PositionGetInteger(POSITION_TYPE);
   double newSL   = 0.0;

   if(type == POSITION_TYPE_BUY)
     {
      double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
      if(bid - open < InpTrailStartATR * g_atr)
         return;
      newSL = NormalizeDouble(bid - InpTrailDistATR * g_atr, digits);
      if((curSL != 0.0 && newSL <= curSL) || newSL > bid - minDist)
         return;
     }
   else
     {
      double ask = SymbolInfoDouble(g_sym, SYMBOL_ASK);
      if(open - ask < InpTrailStartATR * g_atr)
         return;
      newSL = NormalizeDouble(ask + InpTrailDistATR * g_atr, digits);
      if((curSL != 0.0 && newSL >= curSL) || newSL < ask + minDist)
         return;
     }

   MqlTradeRequest req;
   MqlTradeResult  res;
   ZeroMemory(req);
   ZeroMemory(res);
   req.action   = TRADE_ACTION_SLTP;
   req.position = ticket;
   req.symbol   = g_sym;
   req.sl       = newSL;
   req.tp       = curTP;
   req.magic    = EA_MAGIC;
   if(!OrderSend(req, res))
      Print("Trailing stop update failed, retcode=", res.retcode);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   ulong ticket = 0;
   bool  havePos = HasPosition(ticket);
   if(havePos)
      TrailStop(ticket);

   datetime bar = iTime(g_sym, InpTF, 0);
   if(bar == 0 || bar == g_lastBar)
      return;
   g_lastBar = bar;

   double ema200[], emaF[], emaS[], rsi[], adx[], atr[];
   if(!GetBuf(hEmaTrend, 1, 1, ema200) || !GetBuf(hEmaFast, 1, 1, emaF) || !GetBuf(hEmaSlow, 1, 1, emaS) ||
      !GetBuf(hRsi, 1, 2, rsi) || !GetBuf(hAdx, 1, 1, adx) || !GetBuf(hAtr, 1, 1, atr))
      return;   // indicators still warming up

   g_atr = atr[0];
   if(havePos || g_atr <= 0)
      return;

   if(InpUseTimeFilter)
     {
      MqlDateTime dt;
      TimeToStruct(TimeCurrent(), dt);
      if(dt.hour < InpStartHour || dt.hour >= InpEndHour)
         return;
     }
   if(InpMaxSpreadPts > 0 && SymbolInfoInteger(g_sym, SYMBOL_SPREAD) > InpMaxSpreadPts)
      return;
   if(adx[0] < InpADXMin)
      return;

   double close1 = iClose(g_sym, InpTF, 1);
   bool upTrend   = (close1 > ema200[0]) && (emaF[0] > emaS[0]);
   bool downTrend = (close1 < ema200[0]) && (emaF[0] < emaS[0]);
   // rsi[0] = last closed bar, rsi[1] = the bar before it
   bool longSig   = upTrend   && rsi[1] < InpRSILongLevel  && rsi[0] >= InpRSILongLevel;
   bool shortSig  = downTrend && rsi[1] > InpRSIShortLevel && rsi[0] <= InpRSIShortLevel;

   if(longSig && InpAllowLong)
     {
      Print("[BUY SIGNAL] ", g_sym, " uptrend + RSI back above ", InpRSILongLevel, " | ADX=", DoubleToString(adx[0], 1));
      if(TradingEnabled())
         OpenTrade(true, g_atr);
      else
         Comment("Signal-only: BUY ", g_sym, " (set InpLiveTrading=true yourself to place orders)");
     }
   else if(shortSig && InpAllowShort)
     {
      Print("[SELL SIGNAL] ", g_sym, " downtrend + RSI back below ", InpRSIShortLevel, " | ADX=", DoubleToString(adx[0], 1));
      if(TradingEnabled())
         OpenTrade(false, g_atr);
      else
         Comment("Signal-only: SELL ", g_sym, " (set InpLiveTrading=true yourself to place orders)");
     }
  }
//+------------------------------------------------------------------+
