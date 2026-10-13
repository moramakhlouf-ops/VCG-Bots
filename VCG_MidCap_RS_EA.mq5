//+------------------------------------------------------------------+
//| VCG_MidCap_RS_EA.mq5                                              |
//| Relative-Strength EMA(20)/EMA(50) crossover system, adapted from  |
//| the "S&P 400 Mid-Cap Relative Strength Signal System" report.     |
//|                                                                    |
//| SINGLE-SYMBOL MODE (default): trades ONE stock only (e.g. AMD) -   |
//|   the chart / Strategy Tester symbol, or InpSingleSymbol.          |
//| MULTI-SYMBOL MODE: scans every share CFD on your VCG account and   |
//|   applies the monthly Top-N relative-strength filter.              |
//|                                                                    |
//| Live/demo accounts are SIGNAL-ONLY unless you set InpLiveTrading   |
//| = true yourself. In the Strategy Tester (simulated money) orders   |
//| are always simulated so you can see a real backtest.               |
//+------------------------------------------------------------------+
#property copyright "Built for MoraMakhlouf"
#property version   "1.02"
#property description "Standalone EA - no includes. Single-symbol (AMD) mode by default."

#define EA_MAGIC 20260917

//================================ INPUTS =============================
input bool   InpSingleSymbolMode  = true;      // true = trade ONE symbol only. false = scan the whole share universe
input string InpSingleSymbol      = "";        // Symbol for single-symbol mode. Empty = use the chart / Strategy Tester symbol (e.g. AMD)
input string InpBenchmarkSymbol   = "US500";   // S&P 500 CFD name. If not found, common alternatives are tried automatically

input string InpGroupSubstring    = "Share";   // (multi mode) substring matched against symbol path/description
input string InpManualSymbolList  = "";        // (multi mode) optional comma-separated list instead of auto-discovery
input int    InpTopN              = 20;        // (multi mode) monthly Top-N relative-strength universe size
input int    InpRSLookbackDays    = 126;       // (multi mode) RS ranking lookback in trading days

input int    InpEMAFast           = 20;        // Fast EMA period on the ratio series
input int    InpEMASlow           = 50;        // Slow EMA period on the ratio series
input int    InpHistoryBars       = 300;       // D1 bars fetched per symbol

input bool   InpLiveTrading       = false;     // false = log/alert only on real accounts. true = send real market orders. (Tester always simulates)
input int    InpMaxPositions      = 20;        // (multi mode) equal-weight sizing denominator / position cap
input double InpRiskEquityPct     = 100.0;     // % of equity allocated per position slot (single mode = 1 slot)

input bool   InpSendPushAlerts    = true;      // MT5 mobile push notification on each signal
input string InpSignalLogFile     = "VCG_MidCap_RS_signals.csv"; // CSV signal log in MQL5\Files

//================================ STATE ===============================
string   g_universe[];
string   g_active[];
string   g_benchmark = "";
datetime g_lastMonthProcessed = 0;
datetime g_lastDayProcessed   = 0;

struct RSItem
  {
   string sym;
   double change;
  };

struct PendingOrder
  {
   string   sym;
   int      side;      // +1 = buy, -1 = close
   datetime created;
  };

PendingOrder g_pending[];
int          g_lastRetcode = 0;

//+------------------------------------------------------------------+
bool TradingEnabled()
  {
   return InpLiveTrading || (bool)MQLInfoInteger(MQL_TESTER);
  }

//+------------------------------------------------------------------+
//| Find a working S&P 500 benchmark symbol on this account.           |
//+------------------------------------------------------------------+
bool ResolveBenchmark()
  {
   string candidates[] = {"", "US500", "SPX500", "USA500", "US500.cash", "SP500", "S&P500", "US500Cash", "USSPX500", "SPX"};
   candidates[0] = InpBenchmarkSymbol;
   for(int i = 0; i < ArraySize(candidates); i++)
     {
      if(candidates[i] == "")
         continue;
      if(SymbolSelect(candidates[i], true))
        {
         g_benchmark = candidates[i];
         return true;
        }
     }

   // Names above not found: search every symbol on this account by name / description / group.
   int total = SymbolsTotal(false);
   string found = "";
   string indexLike[];
   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, false);
      string desc = SymbolInfoString(name, SYMBOL_DESCRIPTION);
      string path = SymbolInfoString(name, SYMBOL_PATH);
      string hay  = name + " " + desc;
      if(StringFindNoCase(path, "Share") >= 0 || StringFindNoCase(path, "Forex") >= 0)
         continue;
      bool isSP = (StringFindNoCase(hay, "500") >= 0 || StringFindNoCase(hay, "S&P") >= 0 ||
                   StringFindNoCase(hay, "SPX") >= 0 || StringFindNoCase(hay, "SP5") >= 0);
      if(isSP && found == "")
         found = name;
      if(StringFindNoCase(path, "Ind") >= 0 || StringFindNoCase(desc, "Index") >= 0 || isSP)
        {
         int sz = ArraySize(indexLike);
         ArrayResize(indexLike, sz + 1);
         indexLike[sz] = name + " [" + desc + "] {" + path + "}";
        }
     }
   Print("Index-like symbols on this account (", ArraySize(indexLike), "):");
   for(int i = 0; i < ArraySize(indexLike) && i < 40; i++)
      Print("   ", indexLike[i]);

   if(found != "" && SymbolSelect(found, true))
     {
      g_benchmark = found;
      Print("Benchmark auto-detected: ", found);
      return true;
     }
   return false;
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   if(!ResolveBenchmark())
     {
      Print("ERROR: no S&P 500 benchmark symbol found (tried '", InpBenchmarkSymbol,
            "', US500, SPX500, USA500 ...). Find VCG's S&P 500 index CFD in Market Watch and type its exact name into InpBenchmarkSymbol.");
      return(INIT_FAILED);
     }

   if(InpSingleSymbolMode)
     {
      string sym = (StringLen(InpSingleSymbol) > 0) ? InpSingleSymbol : _Symbol;
      if(!SymbolSelect(sym, true))
        {
         Print("ERROR: single-symbol '", sym, "' not found on this account.");
         return(INIT_FAILED);
        }
      ArrayResize(g_universe, 1);
      g_universe[0] = sym;
      ArrayResize(g_active, 1);
      g_active[0] = sym;
     }
   else
     {
      LogDiscoveredGroups();
      BuildUniverse();
      if(ArraySize(g_universe) < 5)
        {
         Print("ERROR: Universe too small (", ArraySize(g_universe), " symbols matched). ",
               "Adjust InpGroupSubstring using a group path printed above, fill InpManualSymbolList, or use single-symbol mode.");
         return(INIT_FAILED);
        }
     }

   EventSetTimer(60);

   Print("VCG RS EA v1.02 started. Mode=", (InpSingleSymbolMode ? "SINGLE-SYMBOL (" + g_universe[0] + ")" : "MULTI-SYMBOL"),
         " | Benchmark=", g_benchmark,
         " | Order placement=", (TradingEnabled() ? "ON (tester or InpLiveTrading=true)" : "OFF (signal/alert only)"));

   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
void LogDiscoveredGroups()
  {
   string seen[];
   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, false);
      string path = SymbolInfoString(name, SYMBOL_PATH);
      bool found = false;
      for(int j = 0; j < ArraySize(seen); j++)
         if(seen[j] == path)
           {
            found = true;
            break;
           }
      if(!found)
        {
         int sz = ArraySize(seen);
         ArrayResize(seen, sz + 1);
         seen[sz] = path;
        }
     }
   Print("--- Discovered symbol group paths (", ArraySize(seen), ") - pick a substring of one for InpGroupSubstring ---");
   for(int j = 0; j < ArraySize(seen); j++)
      Print("  ", seen[j]);
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
string TrimStr(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

//+------------------------------------------------------------------+
void BuildUniverse()
  {
   ArrayFree(g_universe);

   if(StringLen(InpManualSymbolList) > 0)
     {
      string parts[];
      int n = StringSplit(InpManualSymbolList, ',', parts);
      for(int i = 0; i < n; i++)
        {
         string s = TrimStr(parts[i]);
         if(s == "")
            continue;
         if(SymbolSelect(s, true))
           {
            int sz = ArraySize(g_universe);
            ArrayResize(g_universe, sz + 1);
            g_universe[sz] = s;
           }
         else
            Print("WARNING: manual symbol '", s, "' not found on this account, skipped.");
        }
      return;
     }

   int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      string name = SymbolName(i, false);
      if(name == g_benchmark)
         continue;
      string path  = SymbolInfoString(name, SYMBOL_PATH);
      string descr = SymbolInfoString(name, SYMBOL_DESCRIPTION);
      if(StringLen(InpGroupSubstring) > 0)
        {
         if(StringFindNoCase(path, InpGroupSubstring) < 0 && StringFindNoCase(descr, InpGroupSubstring) < 0)
            continue;
        }
      if(!SymbolSelect(name, true))
         continue;
      int sz = ArraySize(g_universe);
      ArrayResize(g_universe, sz + 1);
      g_universe[sz] = name;
     }
  }

//+------------------------------------------------------------------+
//| Runs from both OnTick (tester / active chart) and OnTimer (idle    |
//| chart). Does real work only once per new D1 bar / new month.       |
//+------------------------------------------------------------------+
void OnTick()
  {
   CheckAndRun();
   ProcessPending();
  }

void OnTimer()
  {
   CheckAndRun();
   ProcessPending();
  }

void CheckAndRun()
  {
   datetime bmBarTime = iTime(g_benchmark, PERIOD_D1, 0);
   if(bmBarTime == 0)
      return;

   bool newDay = (bmBarTime != g_lastDayProcessed);

   bool newMonth = false;
   if(g_lastMonthProcessed == 0)
      newMonth = true;
   else
     {
      MqlDateTime dtCur, dtLast;
      TimeToStruct(bmBarTime, dtCur);
      TimeToStruct(g_lastMonthProcessed, dtLast);
      newMonth = (dtCur.mon != dtLast.mon || dtCur.year != dtLast.year);
     }

   if(newMonth)
     {
      if(!InpSingleSymbolMode)
         RebalanceUniverse();
      g_lastMonthProcessed = bmBarTime;
     }

   if(newDay)
     {
      RunDailySignals();
      g_lastDayProcessed = bmBarTime;
     }
  }

//+------------------------------------------------------------------+
//| Ratio(i,t) = Close(i,t) / Benchmark(t) on COMPLETED D1 bars only   |
//| (start_pos = 1), aligned on the most recent N bars of each.        |
//+------------------------------------------------------------------+
bool BuildRatioSeries(const string sym, const double &bmClose[], double &ratio[])
  {
   double symClose[];
   int need = ArraySize(bmClose);
   int got = CopyClose(sym, PERIOD_D1, 1, need, symClose);
   if(got < 10)
      return false;

   int n = MathMin(got, ArraySize(bmClose));
   ArrayResize(ratio, n);
   int symOffset = got - n;
   int bmOffset  = ArraySize(bmClose) - n;
   for(int i = 0; i < n; i++)
     {
      double b = bmClose[bmOffset + i];
      ratio[i] = (b > 0.0) ? symClose[symOffset + i] / b : 0.0;
     }
   return true;
  }

//+------------------------------------------------------------------+
void ComputeEMA(const double &src[], int period, double &out[])
  {
   int n = ArraySize(src);
   ArrayResize(out, n);
   ArrayInitialize(out, 0.0);
   if(n < period)
      return;

   double sum = 0.0;
   for(int i = 0; i < period; i++)
      sum += src[i];
   out[period - 1] = sum / period;

   double k = 2.0 / (period + 1.0);
   for(int i = period; i < n; i++)
      out[i] = src[i] * k + out[i - 1] * (1.0 - k);
  }

//+------------------------------------------------------------------+
//| Multi-symbol mode only: monthly Top-N relative-strength ranking.   |
//+------------------------------------------------------------------+
void RebalanceUniverse()
  {
   double bmClose[];
   if(CopyClose(g_benchmark, PERIOD_D1, 1, InpHistoryBars, bmClose) < InpRSLookbackDays + 2)
     {
      Print("Not enough benchmark history for monthly rebalance yet.");
      return;
     }

   RSItem items[];
   ArrayResize(items, 0);

   for(int i = 0; i < ArraySize(g_universe); i++)
     {
      string s = g_universe[i];
      double ratio[];
      if(!BuildRatioSeries(s, bmClose, ratio))
         continue;
      int len = ArraySize(ratio);
      if(len < InpRSLookbackDays + 2)
         continue;

      double last = ratio[len - 1];
      double past = ratio[len - 1 - InpRSLookbackDays];
      if(past == 0.0)
         continue;

      int sz = ArraySize(items);
      ArrayResize(items, sz + 1);
      items[sz].sym    = s;
      items[sz].change = (last - past) / past;
     }

   int cnt = ArraySize(items);
   for(int i = 0; i < cnt - 1; i++)
      for(int j = 0; j < cnt - 1 - i; j++)
         if(items[j].change < items[j + 1].change)
           {
            RSItem tmp = items[j];
            items[j]   = items[j + 1];
            items[j + 1] = tmp;
           }

   int topN = MathMin(InpTopN, cnt);
   ArrayResize(g_active, topN);
   for(int i = 0; i < topN; i++)
      g_active[i] = items[i].sym;

   Print("Monthly rebalance: ", cnt, " ranked -> active Top-", topN, " universe:");
   for(int i = 0; i < topN; i++)
      Print("  #", i + 1, " ", g_active[i], "  RS(", InpRSLookbackDays, "d)=",
            DoubleToString(items[i].change * 100.0, 2), "%");
  }

//+------------------------------------------------------------------+
double NormalizeLots(const string s, double lots)
  {
   double minLot = SymbolInfoDouble(s, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(s, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(s, SYMBOL_VOLUME_STEP);
   if(step <= 0)
      step = (minLot > 0 ? minLot : 0.01);

   lots = MathFloor(lots / step) * step;
   if(lots < minLot)
      lots = 0.0;
   if(maxLot > 0 && lots > maxLot)
      lots = maxLot;
   return lots;
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

bool DoBuy(const string symbol, double lots)
  {
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = symbol;
   request.volume       = lots;
   request.type         = ORDER_TYPE_BUY;
   request.price        = SymbolInfoDouble(symbol, SYMBOL_ASK);
   request.deviation    = 20;
   request.magic        = EA_MAGIC;
   request.type_filling = GetFillingMode(symbol);
   request.type_time    = ORDER_TIME_GTC;

   bool sent = OrderSend(request, result);
   g_lastRetcode = (int)result.retcode;
   if(!sent)
     {
      Print("OrderSend BUY failed for ", symbol, " error=", GetLastError(),
            " retcode=", result.retcode, " comment=", result.comment);
      return false;
     }
   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
     {
      Print("BUY not executed for ", symbol, " retcode=", result.retcode, " comment=", result.comment);
      return false;
     }
   return true;
  }

bool DoClose(const string symbol)
  {
   if(!PositionSelect(symbol))
      return false;

   ulong  ticket  = PositionGetInteger(POSITION_TICKET);
   double volume  = PositionGetDouble(POSITION_VOLUME);
   long   posType = PositionGetInteger(POSITION_TYPE);

   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);

   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = symbol;
   request.volume       = volume;
   request.position     = ticket;
   request.deviation    = 20;
   request.magic        = EA_MAGIC;
   request.type_filling = GetFillingMode(symbol);
   request.type_time    = ORDER_TIME_GTC;

   if(posType == POSITION_TYPE_BUY)
     {
      request.type  = ORDER_TYPE_SELL;
      request.price = SymbolInfoDouble(symbol, SYMBOL_BID);
     }
   else
     {
      request.type  = ORDER_TYPE_BUY;
      request.price = SymbolInfoDouble(symbol, SYMBOL_ASK);
     }

   bool sent = OrderSend(request, result);
   g_lastRetcode = (int)result.retcode;
   if(!sent)
     {
      Print("OrderSend CLOSE failed for ", symbol, " error=", GetLastError(),
            " retcode=", result.retcode, " comment=", result.comment);
      return false;
     }
   if(result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED)
     {
      Print("CLOSE not executed for ", symbol, " retcode=", result.retcode, " comment=", result.comment);
      return false;
     }
   return true;
  }

//+------------------------------------------------------------------+
//| Orders are queued on a signal and sent only while the symbol's     |
//| market is open (stock CFDs do not trade at the 00:00 daily open).  |
//+------------------------------------------------------------------+
bool InTradeSession(const string sym)
  {
   if((ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(sym, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
      return false;
   MqlDateTime dt;
   TimeToStruct(TimeCurrent(), dt);
   long now = dt.hour * 3600 + dt.min * 60 + dt.sec;
   datetime from, to;
   bool any = false;
   for(uint i = 0; i < 10; i++)
     {
      if(!SymbolInfoSessionTrade(sym, (ENUM_DAY_OF_WEEK)dt.day_of_week, i, from, to))
         break;
      any = true;
      if(now >= (long)from && now < (long)to)
         return true;
     }
   return !any;
  }

void RemovePending(int idx)
  {
   int n = ArraySize(g_pending);
   for(int j = idx; j < n - 1; j++)
      g_pending[j] = g_pending[j + 1];
   ArrayResize(g_pending, n - 1);
  }

void QueueOrder(const string s, int side)
  {
   for(int i = 0; i < ArraySize(g_pending); i++)
      if(g_pending[i].sym == s && g_pending[i].side == side)
         return;
   int sz = ArraySize(g_pending);
   ArrayResize(g_pending, sz + 1);
   g_pending[sz].sym     = s;
   g_pending[sz].side    = side;
   g_pending[sz].created = TimeCurrent();
   Print("Order queued (", (side > 0 ? "BUY" : "CLOSE"), " ", s, ") - will be sent when the market is open.");
  }

// returns true when finished (placed or permanently skipped); false = try again later
bool ExecuteBuy(const string s)
  {
   if(PositionSelect(s) && (int)PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
      return true;

   int    slots        = InpSingleSymbolMode ? 1 : MathMax(1, InpMaxPositions);
   double equity       = AccountInfoDouble(ACCOUNT_EQUITY);
   double allocPerSlot = equity * (InpRiskEquityPct / 100.0) / slots;
   double price        = SymbolInfoDouble(s, SYMBOL_ASK);
   double contractSize = SymbolInfoDouble(s, SYMBOL_TRADE_CONTRACT_SIZE);
   if(price <= 0.0 || contractSize <= 0.0)
      return false;

   double lots = NormalizeLots(s, allocPerSlot / (price * contractSize));
   if(lots <= 0.0)
     {
      Print("Computed lot size <= 0 for ", s, " (allocation ", DoubleToString(allocPerSlot, 2),
            " too small for min lot), order skipped.");
      return true;
     }

   if(!InpSingleSymbolMode && PositionsTotal() >= InpMaxPositions)
     {
      Print("Max positions (", InpMaxPositions, ") reached, BUY for ", s, " skipped.");
      return true;
     }

   g_lastRetcode = 0;
   DoBuy(s, lots);
   return (g_lastRetcode != TRADE_RETCODE_MARKET_CLOSED);
  }

void ProcessPending()
  {
   for(int i = ArraySize(g_pending) - 1; i >= 0; i--)
     {
      string s    = g_pending[i].sym;
      int    side = g_pending[i].side;

      if(TimeCurrent() - g_pending[i].created > 3 * 86400)
        {
         Print("Queued order for ", s, " expired after 3 days, dropped - the market never opened while the EA was running.",
            (bool)MQLInfoInteger(MQL_TESTER) ? " TESTER: set Modelling to '1 minute OHLC' or 'Every tick' (not 'Open prices only')." : "");
         RemovePending(i);
         continue;
        }
      if(!InTradeSession(s))
         continue;

      bool resolved = true;
      if(side > 0)
         resolved = ExecuteBuy(s);
      else if(PositionSelect(s) && (int)PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
        {
         g_lastRetcode = 0;
         DoClose(s);
         resolved = (g_lastRetcode != TRADE_RETCODE_MARKET_CLOSED);
        }
      if(resolved)
         RemovePending(i);
     }
  }

//+------------------------------------------------------------------+
int OpenSignalLog()
  {
   int fh = FileOpen(InpSignalLogFile, FILE_WRITE | FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(fh == INVALID_HANDLE)
      return INVALID_HANDLE;
   if(FileSize(fh) == 0)
      FileWrite(fh, "datetime", "symbol", "signal", "orders_enabled", "note");
   FileSeek(fh, 0, SEEK_END);
   return fh;
  }

//+------------------------------------------------------------------+
void HandleBuySignal(const string s, int fh)
  {
   string msg = StringFormat("[BUY SIGNAL] %s : ratio EMA(%d) crossed ABOVE EMA(%d) vs %s",
                              s, InpEMAFast, InpEMASlow, g_benchmark);
   Print(msg);
   if(InpSendPushAlerts)
      SendNotification(msg);
   if(fh != INVALID_HANDLE)
      FileWrite(fh, TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), s, "BUY",
                (TradingEnabled() ? "true" : "false"), "");

   if(!TradingEnabled())
     {
      Comment("Signal-only mode: BUY ", s, " logged. Set InpLiveTrading=true yourself to place real orders.");
      return;
     }

   QueueOrder(s, 1);
  }

//+------------------------------------------------------------------+
void HandleSellSignal(const string s, int fh)
  {
   string msg = StringFormat("[EXIT SIGNAL] %s : ratio EMA(%d) crossed BELOW EMA(%d) - close position",
                              s, InpEMAFast, InpEMASlow);
   Print(msg);
   if(InpSendPushAlerts)
      SendNotification(msg);
   if(fh != INVALID_HANDLE)
      FileWrite(fh, TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), s, "EXIT",
                (TradingEnabled() ? "true" : "false"), "");

   if(!TradingEnabled())
     {
      Comment("Signal-only mode: EXIT ", s, " logged. Set InpLiveTrading=true yourself to place real orders.");
      return;
     }

   QueueOrder(s, -1);
  }

//+------------------------------------------------------------------+
void RunDailySignals()
  {
   double bmClose[];
   if(CopyClose(g_benchmark, PERIOD_D1, 1, InpHistoryBars, bmClose) < InpEMASlow + 5)
     {
      Print("Waiting for benchmark history (", g_benchmark, ") - not enough D1 bars yet.");
      return;
     }

   string checkList[];
   ArrayResize(checkList, ArraySize(g_active));
   for(int i = 0; i < ArraySize(g_active); i++)
      checkList[i] = g_active[i];

   for(int p = PositionsTotal() - 1; p >= 0; p--)
     {
      string s = PositionGetSymbol(p);
      if(s == "")
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) != EA_MAGIC)
         continue;
      bool exists = false;
      for(int k = 0; k < ArraySize(checkList); k++)
         if(checkList[k] == s)
           {
            exists = true;
            break;
           }
      if(!exists)
        {
         int sz = ArraySize(checkList);
         ArrayResize(checkList, sz + 1);
         checkList[sz] = s;
        }
     }

   int fh = OpenSignalLog();

   for(int i = 0; i < ArraySize(checkList); i++)
     {
      string s = checkList[i];
      double ratio[];
      if(!BuildRatioSeries(s, bmClose, ratio))
        {
         Print("No D1 history yet for ", s);
         continue;
        }
      int n = ArraySize(ratio);
      if(n < InpEMASlow + 5)
        {
         Print("Not enough D1 bars for ", s, " (", n, ")");
         continue;
        }

      double emaFast[], emaSlow[];
      ComputeEMA(ratio, InpEMAFast, emaFast);
      ComputeEMA(ratio, InpEMASlow, emaSlow);

      double fPrev = emaFast[n - 2];
      double fCurr = emaFast[n - 1];
      double sPrev = emaSlow[n - 2];
      double sCurr = emaSlow[n - 1];

      bool crossUp   = (fPrev <= sPrev) && (fCurr > sCurr);
      bool crossDown = (fPrev >= sPrev) && (fCurr < sCurr);

      bool inActive = false;
      for(int k = 0; k < ArraySize(g_active); k++)
         if(g_active[k] == s)
           {
            inActive = true;
            break;
           }

      bool hasPos = PositionSelect(s) && ((int)PositionGetInteger(POSITION_MAGIC) == EA_MAGIC);

      if(InpSingleSymbolMode)
         Print(s, "/", g_benchmark, " ratio EMA", InpEMAFast, "=", DoubleToString(fCurr, 6),
               " EMA", InpEMASlow, "=", DoubleToString(sCurr, 6),
               (fCurr > sCurr ? " (fast above slow)" : " (fast below slow)"),
               (hasPos ? " | position open" : " | flat"));

      if(crossUp && inActive && !hasPos)
         HandleBuySignal(s, fh);
      else if(crossDown && (hasPos || !TradingEnabled()))   // signal-only mode has no positions, still report exits
         HandleSellSignal(s, fh);
     }

   if(fh != INVALID_HANDLE)
      FileClose(fh);
  }
//+------------------------------------------------------------------+
