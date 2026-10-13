//+------------------------------------------------------------------+
//| VCG_Stock_Breakout_EA.mq5
//| VCG Stock Breakout EA (100-day high breakout, 8 US mega-caps)
//|
//| Buys a stock when it closes above its prior 100-day high; exits when it closes below its prior 20-day low. Equal-weight basket: Apple, Microsoft, Nvidia, Amazon, Alphabet, Meta, Tesla, AMD (any not offered by VCG are skipped).
//|
//| BACKTEST EVIDENCE (daily data, 2022-01-01 -> 2026-10-12, trading
//| costs included, NO swap/financing costs, long-only, 100% notional):
//| 8-stock basket: +79.3% total, max drawdown -12.8%, Sharpe 1.11 (buy&hold basket +195.8%, -50.1%). Years: 2022 -2.7%, 2023 +28.4%, 2024 +21.6%, 2025 +10.8%, 2026 YTD +6.5%. Lags buy&hold in a bull market but with about a quarter of the drawdown.
//| Parameters were chosen on 2022-2024 only; 2025-2026 was out-of-sample.
//| Past results do not guarantee future results.
//|
//| Live/demo accounts are SIGNAL-ONLY unless InpLiveTrading = true.
//| In the Strategy Tester orders are always simulated.
//| Tester setup: Timeframe D1, Modelling "1 minute OHLC", Custom dates.
//+------------------------------------------------------------------+
#property copyright "Built for MoraMakhlouf"
#property version   "1.00"
#property description "VCG Stock Breakout EA (100-day high breakout, 8 US mega-caps)"

#define EA_MAGIC 20260933

//================================ INPUTS =============================
input string InpSymbols        = "Apple,Microsoft,Nvidia,Amazon,Alphabet|Google,Meta,Tesla,AMD";   // Comma-separated symbols/keywords. Use | for alternatives, e.g. Alphabet|Google
input double InpTotalAllocPct  = 100.0;     // % of equity (notional) spread equally across the symbols
input int    InpHistoryBars    = 700;     // D1 bars loaded per symbol
input int    InpEntryLen       = 100;     // Buy on close above the prior N-day high
input int    InpExitLen        = 20;      // Exit on close below the prior N-day low
input bool   InpLiveTrading    = false;   // false = signals only on real accounts. true = real orders. (Tester always simulates)
input bool   InpSendPushAlerts = true;    // MT5 mobile push notification on each signal
input string InpSignalLogFile  = "VCG_Stock_Breakout_signals.csv"; // CSV signal log in MQL5\Files

//================================ STATE ===============================
string   g_syms[];
int      g_state[];      // logical position per symbol: 1 = should be long, 0 = flat
int      g_target[];     // latest target (-1 = not computed yet)
datetime g_nextTry[];
datetime g_lastDay = 0;
int      g_lastRetcode = 0;

//+------------------------------------------------------------------+
bool TradingEnabled()
  {
   return InpLiveTrading || (bool)MQLInfoInteger(MQL_TESTER);
  }

int StringFindNoCase(const string haystack, const string needle)
  {
   string h = haystack;
   string n = needle;
   StringToLower(h);
   StringToLower(n);
   return StringFind(h, n);
  }

string TrimStr(string s)
  {
   StringTrimLeft(s);
   StringTrimRight(s);
   return s;
  }

//+------------------------------------------------------------------+
//| Resolve a name/keyword to a real symbol on this account.           |
//+------------------------------------------------------------------+
string ResolveToken(const string token)
  {
   string alts[];
   int na = StringSplit(token, '|', alts);
   for(int a = 0; a < na; a++)
     {
      string kw = TrimStr(alts[a]);
      if(kw == "")
         continue;
      if(SymbolSelect(kw, true))
         return kw;
     }
   int total = SymbolsTotal(false);
   for(int a = 0; a < na; a++)
     {
      string kw = TrimStr(alts[a]);
      if(kw == "")
         continue;
      for(int i = 0; i < total; i++)
        {
         string name = SymbolName(i, false);
         string path = SymbolInfoString(name, SYMBOL_PATH);
         if(StringFindNoCase(path, "Share") < 0)
            continue;
         string desc = SymbolInfoString(name, SYMBOL_DESCRIPTION);
         if(StringFindNoCase(desc, kw) >= 0 || StringFindNoCase(name, kw) >= 0)
            if(SymbolSelect(name, true))
               return name;
        }
     }
   return "";
  }

//+------------------------------------------------------------------+
int OnInit()
  {
   string tokens[];
   int n = (StringLen(InpSymbols) > 0) ? StringSplit(InpSymbols, ',', tokens) : 0;
   for(int i = 0; i < n; i++)
     {
      string t = TrimStr(tokens[i]);
      if(t == "")
         continue;
      string s = ResolveToken(t);
      if(s == "")
        {
         Print("WARNING: '", t, "' not found on this account - skipped.");
         continue;
        }
      bool dup = false;
      for(int k = 0; k < ArraySize(g_syms); k++)
         if(g_syms[k] == s)
            dup = true;
      if(dup)
         continue;
      int sz = ArraySize(g_syms);
      ArrayResize(g_syms, sz + 1);
      g_syms[sz] = s;
     }
   if(ArraySize(g_syms) == 0)
     {
      ArrayResize(g_syms, 1);
      g_syms[0] = _Symbol;
      Print("No symbols resolved from InpSymbols - using the chart symbol ", _Symbol);
     }

   int cnt = ArraySize(g_syms);
   ArrayResize(g_state, cnt);
   ArrayResize(g_target, cnt);
   ArrayResize(g_nextTry, cnt);
   string list = "";
   for(int i = 0; i < cnt; i++)
     {
      g_state[i]   = HasPos(g_syms[i]) ? 1 : 0;
      g_target[i]  = -1;
      g_nextTry[i] = 0;
      list += (i > 0 ? ", " : "") + g_syms[i];
     }

   EventSetTimer(60);
   Print("VCG Stock Breakout EA (100-day high breakout, 8 US mega-caps) started. Symbols (", cnt, "): ", list, " | Order placement=",
         (TradingEnabled() ? "ON (tester or InpLiveTrading=true)" : "OFF (signal only)"));
   return(INIT_SUCCEEDED);
  }

void OnDeinit(const int reason)
  {
   EventKillTimer();
  }

//+------------------------------------------------------------------+
//| Indicator helpers (computed from COMPLETED daily bars)             |
//+------------------------------------------------------------------+
void ComputeEMA(const double &src[], int period, double &out[])
  {
   int n = ArraySize(src);
   ArrayResize(out, n);
   if(n == 0)
      return;
   double a = 2.0 / (period + 1.0);
   out[0] = src[0];
   for(int i = 1; i < n; i++)
      out[i] = a * src[i] + (1.0 - a) * out[i - 1];
  }

void ComputeRSI(const double &c[], int period, double &out[])
  {
   int n = ArraySize(c);
   ArrayResize(out, n);
   ArrayInitialize(out, 50.0);
   if(n < 3)
      return;
   double a = 1.0 / period;
   double d = c[1] - c[0];
   double up = MathMax(d, 0.0);
   double dn = MathMax(-d, 0.0);
   for(int i = 1; i < n; i++)
     {
      d = c[i] - c[i - 1];
      up = up * (1.0 - a) + MathMax(d, 0.0) * a;
      dn = dn * (1.0 - a) + MathMax(-d, 0.0) * a;
      out[i] = (dn == 0.0) ? 100.0 : 100.0 - 100.0 / (1.0 + up / dn);
     }
  }

double AvgAt(const double &c[], int last, int period)
  {
   double s = 0.0;
   for(int k = last - period + 1; k <= last; k++)
      s += c[k];
   return s / period;
  }

//+------------------------------------------------------------------+
//| STRATEGY: returns 1 = want long, 0 = want flat, -1 = no data       |
//| state = current logical position (1/0)                             |
//+------------------------------------------------------------------+
int ComputeTarget(const string sym, const int state)
  {
   double c[], h[], l[];
   if(CopyClose(sym, PERIOD_D1, 1, InpHistoryBars, c) < InpEntryLen + 10 ||
      CopyHigh(sym, PERIOD_D1, 1, InpHistoryBars, h) < InpEntryLen + 10 ||
      CopyLow(sym, PERIOD_D1, 1, InpHistoryBars, l) < InpEntryLen + 10)
      return -1;
   int L = MathMin(ArraySize(c), MathMin(ArraySize(h), ArraySize(l))) - 1;
   if(state == 0)
     {
      double hi = -DBL_MAX;
      for(int k = L - InpEntryLen; k <= L - 1; k++)
         hi = MathMax(hi, h[k]);
      return (c[L] > hi) ? 1 : 0;
     }
   double lo = DBL_MAX;
   for(int k = L - InpExitLen; k <= L - 1; k++)
      lo = MathMin(lo, l[k]);
   return (c[L] < lo) ? 0 : 1;
  }

//+------------------------------------------------------------------+
bool HasPos(const string sym)
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      if(PositionGetSymbol(i) != sym)
         continue;
      if((int)PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
         return true;
     }
   return false;
  }

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

ENUM_ORDER_TYPE_FILLING GetFillingMode(const string symbol)
  {
   int filling = (int)SymbolInfoInteger(symbol, SYMBOL_FILLING_MODE);
   if((filling & SYMBOL_FILLING_FOK) != 0)
      return ORDER_FILLING_FOK;
   if((filling & SYMBOL_FILLING_IOC) != 0)
      return ORDER_FILLING_IOC;
   return ORDER_FILLING_RETURN;
  }

bool SendDeal(const string symbol, const ENUM_ORDER_TYPE type, const double lots, const ulong posTicket)
  {
   MqlTradeRequest request;
   MqlTradeResult  result;
   ZeroMemory(request);
   ZeroMemory(result);
   request.action       = TRADE_ACTION_DEAL;
   request.symbol       = symbol;
   request.volume       = lots;
   request.type         = type;
   request.price        = (type == ORDER_TYPE_BUY) ? SymbolInfoDouble(symbol, SYMBOL_ASK) : SymbolInfoDouble(symbol, SYMBOL_BID);
   request.position     = posTicket;
   request.deviation    = 30;
   request.magic        = EA_MAGIC;
   request.type_filling = GetFillingMode(symbol);
   request.type_time    = ORDER_TIME_GTC;
   bool sent = OrderSend(request, result);
   g_lastRetcode = (int)result.retcode;
   if(!sent || (result.retcode != TRADE_RETCODE_DONE && result.retcode != TRADE_RETCODE_PLACED))
     {
      Print("Order failed for ", symbol, " retcode=", result.retcode, " comment=", result.comment);
      return false;
     }
   return true;
  }

void ExecuteBuy(const string s)
  {
   int    slots        = MathMax(1, ArraySize(g_syms));
   double allocPerSlot = AccountInfoDouble(ACCOUNT_EQUITY) * (InpTotalAllocPct / 100.0) / slots;
   double price        = SymbolInfoDouble(s, SYMBOL_ASK);
   double contractSize = SymbolInfoDouble(s, SYMBOL_TRADE_CONTRACT_SIZE);
   if(price <= 0.0 || contractSize <= 0.0)
      return;
   double lots = NormalizeLots(s, allocPerSlot / (price * contractSize));
   if(lots <= 0.0)
     {
      Print("Allocation ", DoubleToString(allocPerSlot, 2), " too small for the minimum lot on ", s, " - skipped.");
      return;
     }
   if(SendDeal(s, ORDER_TYPE_BUY, lots, 0))
      Print("BUY ", DoubleToString(lots, 2), " ", s, " @", DoubleToString(price, (int)SymbolInfoInteger(s, SYMBOL_DIGITS)));
  }

void ExecuteClose(const string s)
  {
   ulong ticket = 0;
   for(int i = PositionsTotal() - 1; i >= 0 && ticket == 0; i--)
      if(PositionGetSymbol(i) == s && (int)PositionGetInteger(POSITION_MAGIC) == EA_MAGIC)
         ticket = (ulong)PositionGetInteger(POSITION_TICKET);
   if(ticket == 0 || !PositionSelectByTicket(ticket))
      return;
   double volume = PositionGetDouble(POSITION_VOLUME);
   long   type   = PositionGetInteger(POSITION_TYPE);
   if(SendDeal(s, (type == POSITION_TYPE_BUY) ? ORDER_TYPE_SELL : ORDER_TYPE_BUY, volume, ticket))
      Print("CLOSED ", s);
  }

//+------------------------------------------------------------------+
void LogSignal(const string sym, const string what)
  {
   string msg = StringFormat("[%s] %s", what, sym);
   Print(msg);
   if(InpSendPushAlerts)
      SendNotification(msg);
   int fh = FileOpen(InpSignalLogFile, FILE_WRITE | FILE_READ | FILE_CSV | FILE_ANSI, ',');
   if(fh == INVALID_HANDLE)
      return;
   if(FileSize(fh) == 0)
      FileWrite(fh, "datetime", "symbol", "signal", "orders_enabled");
   FileSeek(fh, 0, SEEK_END);
   FileWrite(fh, TimeToString(TimeCurrent(), TIME_DATE | TIME_MINUTES), sym, what, (TradingEnabled() ? "true" : "false"));
   FileClose(fh);
  }

//+------------------------------------------------------------------+
//| Once per new D1 bar: recompute every symbol's target position.     |
//+------------------------------------------------------------------+
void DailyUpdate()
  {
   datetime bar = iTime(g_syms[0], PERIOD_D1, 0);
   if(bar == 0 || bar == g_lastDay)
      return;
   g_lastDay = bar;
   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      int t = ComputeTarget(g_syms[i], g_state[i]);
      if(t < 0)
        {
         Print("Not enough D1 history yet for ", g_syms[i]);
         continue;
        }
      if(t != g_state[i])
        {
         LogSignal(g_syms[i], (t == 1) ? "BUY SIGNAL" : "EXIT SIGNAL");
         g_state[i] = t;
        }
      g_target[i] = t;
     }
  }

//+------------------------------------------------------------------+
//| Every tick / minute: bring real positions in line with targets,    |
//| but only while that symbol's market is open.                       |
//+------------------------------------------------------------------+
void Reconcile()
  {
   if(!TradingEnabled())
      return;
   for(int i = 0; i < ArraySize(g_syms); i++)
     {
      if(g_target[i] < 0 || TimeCurrent() < g_nextTry[i])
         continue;
      string s = g_syms[i];
      bool has = HasPos(s);
      if(g_target[i] == 1 && !has)
        {
         if(!InTradeSession(s))
            continue;
         ExecuteBuy(s);
         g_nextTry[i] = TimeCurrent() + 600;
        }
      else if(g_target[i] == 0 && has)
        {
         if(!InTradeSession(s))
            continue;
         ExecuteClose(s);
         g_nextTry[i] = TimeCurrent() + 600;
        }
     }
  }

void OnTick()
  {
   DailyUpdate();
   Reconcile();
  }

void OnTimer()
  {
   DailyUpdate();
   Reconcile();
  }
//+------------------------------------------------------------------+
