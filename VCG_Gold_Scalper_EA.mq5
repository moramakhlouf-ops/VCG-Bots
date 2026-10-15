//+------------------------------------------------------------------+
//| VCG_Gold_Scalper_EA.mq5                                           |
//| High-frequency gold (XAUUSD) scalper - many trades per day.       |
//|                                                                    |
//| Logic (evaluated once per new M5 bar, on COMPLETED bars):          |
//|  TREND : close vs EMA(50) on the signal timeframe                  |
//|  ENTRY : fast RSI(5) pullback inside the trend                     |
//|          LONG  = uptrend   + RSI crosses UP through 30             |
//|          SHORT = downtrend + RSI crosses DOWN through 70           |
//|  EXITS : ATR stop + ATR target, move stop to breakeven, and a      |
//|          time stop (close after N bars if neither was hit)         |
//|  SIZING: risk InpRiskPct % of equity per trade from SL distance    |
//|  SAFETY: max spread, trading hours, daily loss limit, max          |
//|          trades per day                                            |
//|                                                                    |
//| Places orders on DEMO accounts and in the Strategy Tester.         |
//| On REAL accounts it is signal-only unless InpLiveTrading = true.   |
//| Scalping is very sensitive to spread/commission: backtest with     |
//| "Every tick based on real ticks" and forward-test on demo first.   |
//| No strategy guarantees profit.                                     |
//+------------------------------------------------------------------+
#property copyright "Built for MoraMakhlouf"
#property version   "1.00"
#property description "High-frequency gold scalper: EMA trend + fast RSI pullback, ATR stops, breakeven, time stop."

#define EA_MAGIC 20261015

//================================ INPUTS =============================
input string          InpSymbol        = "XAUUSD";  // Gold symbol on VCG (auto-detected by description "Gold" if not found)
input ENUM_TIMEFRAMES InpTF            = PERIOD_M5; // Signal timeframe

input int    InpEMATrend      = 50;     // Trend EMA
input int    InpRSIPeriod     = 5;      // Fast RSI period
input double InpRSILow        = 30.0;   // Long entry: RSI crosses UP through this level (in uptrend)
input double InpRSIHigh       = 70.0;   // Short entry: RSI crosses DOWN through this level (in downtrend)
input int    InpATRPeriod     = 14;     // ATR period

input double InpSLATR         = 1.2;    // Stop loss = this many ATR
input double InpTPATR         = 1.2;    // Take profit = this many ATR
input double InpBEATR         = 0.7;    // Move stop to breakeven after this many ATR of profit (0 = off)
input int    InpMaxBarsInTrade = 12;    // Close the trade after this many bars (12 x M5 = 1 hour). 0 = off

input double InpRiskPct       = 0.5;    // % of equity risked per trade
input int    InpMaxPositions  = 1;      // Max simultaneous positions from this EA
input int    InpMaxTradesDay  = 40;     // Max new trades per day (0 = unlimited)
input double InpDailyLossPct  = 3.0;    // Stop opening trades for the day after this % loss (0 = off)
input bool   InpAllowLong     = true;
input bool   InpAllowShort    = true;
input bool   InpUseTimeFilter = true;   // Only open trades within the hours below (server time)
input int    InpStartHour     = 2;
input int    InpEndHour       = 22;
input int    InpMaxSpreadPts  = 60;     // Skip entries if spread (points) is above this. 0 = no limit

input bool   InpLiveTrading   = false;  // REAL accounts only: true = place real orders. Demo + tester always trade.

//================================ STATE ===============================
string   g_sym = "";
int      hEma = INVALID_HANDLE, hRsi = INVALID_HANDLE, hAtr = INVALID_HANDLE;
datetime g_lastBar = 0;
double   g_atr = 0.0;
datetime g_day = 0;
double   g_dayStartEquity = 0.0;
int      g_tradesToday = 0;

//+------------------------------------------------------------------+
bool TradingEnabled()
  {
   if((bool)MQLInfoInteger(MQL_TESTER))
      return true;
   if((ENUM_ACCOUNT_TRADE_MODE)AccountInfoInteger(ACCOUNT_TRADE_MODE) == ACCOUNT_TRADE_MODE_DEMO)
      return true;
   return InpLiveTrading;
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
         if(SymbolSelect(name, true))
           {
            g_sym = name;
            return true;
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

   hEma = iMA(g_sym, InpTF, InpEMATrend, 0, MODE_EMA, PRICE_CLOSE);
   hRsi = iRSI(g_sym, InpTF, InpRSIPeriod, PRICE_CLOSE);
   hAtr = iATR(g_sym, InpTF, InpATRPeriod);
   if(hEma == INVALID_HANDLE || hRsi == INVALID_HANDLE || hAtr == INVALID_HANDLE)
     {
      Print("ERROR: could not create indicator handles for ", g_sym);
      return(INIT_FAILED);
     }

   if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED) || !MQLInfoInteger(MQL_TRADE_ALLOWED))
      Print("WARNING: Algo Trading is OFF. Press the 'Algo Trading' button in the toolbar and tick ",
            "'Allow Algo Trading' in the EA's Common tab, or no orders will be placed.");

   Print("VCG Gold Scalper v1.00 started on ", g_sym, " ", EnumToString(InpTF),
         " | Risk/trade=", DoubleToString(InpRiskPct, 2), "% | SL=", DoubleToString(InpSLATR, 1), "xATR TP=",
         DoubleToString(InpTPATR, 1), "xATR | Order placement=",
         (TradingEnabled() ? "ON (tester/demo or InpLiveTrading=true)" : "OFF (real account, signal only)"));
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   if(hEma != INVALID_HANDLE)
      IndicatorRelease(hEma);
   if(hRsi != INVALID_HANDLE)
      IndicatorRelease(hRsi);
   if(hAtr != INVALID_HANDLE)
      IndicatorRelease(hAtr);
   Comment("");
  }

//+------------------------------------------------------------------+
bool GetBuf(const int handle, const int shift, const int count, double &out[])
  {
   ArraySetAsSeries(out, true);
   return (CopyBuffer(handle, 0, shift, count, out) == count);
  }

//+------------------------------------------------------------------+
int CountPositions()
  {
   int n = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(PositionGetSymbol(i) == g_sym && (int)PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
         n++;
   return n;
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
bool SendRequest(MqlTradeRequest &req, const string what)
  {
   MqlTradeResult res;
   ZeroMemory(res);
   bool sent = OrderSend(req, res);
   if(!sent || (res.retcode != TRADE_RETCODE_DONE && res.retcode != TRADE_RETCODE_PLACED))
     {
      Print(what, " FAILED on ", g_sym, " retcode=", res.retcode, " comment=", res.comment);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
bool OpenTrade(const bool isBuy)
  {
   int    digits  = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   double minDist = (double)SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   double entry   = isBuy ? SymbolInfoDouble(g_sym, SYMBOL_ASK) : SymbolInfoDouble(g_sym, SYMBOL_BID);
   if(entry <= 0)
      return false;

   double slDist = MathMax(InpSLATR * g_atr, minDist + 10 * point);
   double tpDist = MathMax(InpTPATR * g_atr, minDist + 10 * point);
   double sl = NormalizeDouble(isBuy ? entry - slDist : entry + slDist, digits);
   double tp = NormalizeDouble(isBuy ? entry + tpDist : entry - tpDist, digits);

   double lots = CalcLots(entry, sl, isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL);
   if(lots <= 0)
     {
      Print("Lot size too small for the risk setting - trade skipped.");
      return false;
     }

   MqlTradeRequest req;
   ZeroMemory(req);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = g_sym;
   req.volume       = lots;
   req.type         = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price        = entry;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = 30;
   req.magic        = EA_MAGIC;
   req.comment      = "VCG Gold Scalper";
   req.type_filling = GetFillingMode(g_sym);
   req.type_time    = ORDER_TIME_GTC;
   if(!SendRequest(req, isBuy ? "BUY" : "SELL"))
      return false;

   g_tradesToday++;
   Print((isBuy ? "BUY " : "SELL "), DoubleToString(lots, 2), " ", g_sym, " @", DoubleToString(entry, digits),
         " SL=", DoubleToString(sl, digits), " TP=", DoubleToString(tp, digits));
   return true;
  }

//+------------------------------------------------------------------+
void ClosePosition(const ulong ticket, const string why)
  {
   if(!PositionSelectByTicket(ticket))
      return;
   bool isBuy = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
   MqlTradeRequest req;
   ZeroMemory(req);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = g_sym;
   req.position     = ticket;
   req.volume       = PositionGetDouble(POSITION_VOLUME);
   req.type         = isBuy ? ORDER_TYPE_SELL : ORDER_TYPE_BUY;
   req.price        = isBuy ? SymbolInfoDouble(g_sym, SYMBOL_BID) : SymbolInfoDouble(g_sym, SYMBOL_ASK);
   req.deviation    = 30;
   req.magic        = EA_MAGIC;
   req.type_filling = GetFillingMode(g_sym);
   if(SendRequest(req, "CLOSE"))
      Print("CLOSED #", ticket, " ", g_sym, " (", why, ")");
  }

//+------------------------------------------------------------------+
//| Breakeven stop + time stop for every open EA position.             |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   int    digits  = (int)SymbolInfoInteger(g_sym, SYMBOL_DIGITS);
   double point   = SymbolInfoDouble(g_sym, SYMBOL_POINT);
   double minDist = (double)SymbolInfoInteger(g_sym, SYMBOL_TRADE_STOPS_LEVEL) * point;
   int    tfSec   = PeriodSeconds(InpTF);

   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != g_sym || (int)PositionGetInteger(POSITION_MAGIC) != EA_MAGIC)
         continue;
      ulong  ticket = (ulong)PositionGetInteger(POSITION_TICKET);
      double open   = PositionGetDouble(POSITION_PRICE_OPEN);
      double curSL  = PositionGetDouble(POSITION_SL);
      double curTP  = PositionGetDouble(POSITION_TP);
      bool   isBuy  = (PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);

      if(InpMaxBarsInTrade > 0 && TimeCurrent() - opened >= (long)InpMaxBarsInTrade * tfSec)
        {
         ClosePosition(ticket, "time stop");
         continue;
        }

      if(InpBEATR <= 0 || g_atr <= 0)
         continue;
      double px    = isBuy ? SymbolInfoDouble(g_sym, SYMBOL_BID) : SymbolInfoDouble(g_sym, SYMBOL_ASK);
      double gain  = isBuy ? px - open : open - px;
      if(gain < InpBEATR * g_atr)
         continue;
      // lock in a couple of points beyond entry to cover costs
      double newSL = NormalizeDouble(isBuy ? open + 2 * point : open - 2 * point, digits);
      bool better  = isBuy ? (curSL == 0.0 || newSL > curSL) : (curSL == 0.0 || newSL < curSL);
      bool legal   = isBuy ? (newSL < px - minDist) : (newSL > px + minDist);
      if(!better || !legal)
         continue;

      MqlTradeRequest req;
      ZeroMemory(req);
      req.action   = TRADE_ACTION_SLTP;
      req.position = ticket;
      req.symbol   = g_sym;
      req.sl       = newSL;
      req.tp       = curTP;
      req.magic    = EA_MAGIC;
      SendRequest(req, "BREAKEVEN");
     }
  }

//+------------------------------------------------------------------+
//| Daily counters: trades opened today and loss since the day began.  |
//+------------------------------------------------------------------+
bool DailyLimitsOk()
  {
   datetime today = iTime(g_sym, PERIOD_D1, 0);
   if(today != 0 && today != g_day)
     {
      g_day            = today;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_tradesToday    = 0;
     }
   if(InpMaxTradesDay > 0 && g_tradesToday >= InpMaxTradesDay)
      return false;
   if(InpDailyLossPct > 0 && g_dayStartEquity > 0 &&
      AccountInfoDouble(ACCOUNT_EQUITY) <= g_dayStartEquity * (1.0 - InpDailyLossPct / 100.0))
      return false;
   return true;
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   if(TradingEnabled())
      ManagePositions();

   datetime bar = iTime(g_sym, InpTF, 0);
   if(bar == 0 || bar == g_lastBar)
      return;
   g_lastBar = bar;

   double ema[], rsi[], atr[];
   if(!GetBuf(hEma, 1, 1, ema) || !GetBuf(hRsi, 1, 2, rsi) || !GetBuf(hAtr, 1, 1, atr))
      return;   // indicators still warming up
   g_atr = atr[0];
   if(g_atr <= 0)
      return;

   bool limitsOk = DailyLimitsOk();
   Comment("VCG Gold Scalper | ", g_sym, " | trades today: ", g_tradesToday,
           (limitsOk ? "" : " | DAILY LIMIT HIT - paused until tomorrow"),
           " | orders ", (TradingEnabled() ? "ON" : "OFF (signal only)"));
   if(!limitsOk || CountPositions() >= InpMaxPositions)
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

   double close1 = iClose(g_sym, InpTF, 1);
   // rsi[0] = last closed bar, rsi[1] = the bar before it
   bool longSig  = close1 > ema[0] && rsi[1] < InpRSILow  && rsi[0] >= InpRSILow;
   bool shortSig = close1 < ema[0] && rsi[1] > InpRSIHigh && rsi[0] <= InpRSIHigh;

   if(longSig && InpAllowLong)
     {
      Print("[BUY SIGNAL] ", g_sym, " above EMA", InpEMATrend, " + RSI back above ", DoubleToString(InpRSILow, 0));
      if(TradingEnabled())
         OpenTrade(true);
     }
   else if(shortSig && InpAllowShort)
     {
      Print("[SELL SIGNAL] ", g_sym, " below EMA", InpEMATrend, " + RSI back below ", DoubleToString(InpRSIHigh, 0));
      if(TradingEnabled())
         OpenTrade(false);
     }
  }
//+------------------------------------------------------------------+
