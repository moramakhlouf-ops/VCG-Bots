//+------------------------------------------------------------------+
//| VCG_Timer_Orders_EA.mq5                                           |
//| Opens a market order every N seconds (default 2) on a timer.      |
//|                                                                    |
//| Logic (evaluated on a millisecond timer, not on ticks):            |
//|  ENTRY : every InpIntervalSec seconds open one market order        |
//|          Direction: alternate / buy only / sell only / random /    |
//|          momentum (follow the price move since the last order)     |
//|  EXITS : fixed SL/TP in points + close after InpHoldSec seconds    |
//|  SIZING: fixed lot InpLots                                         |
//|  SAFETY: max open positions, max orders per day, daily loss        |
//|          limit, max spread                                         |
//|                                                                    |
//| Places orders on DEMO accounts and in the Strategy Tester.         |
//| On REAL accounts it is signal-only unless InpLiveTrading = true.   |
//| Opening an order every 2 seconds pays the spread ~1800 times per   |
//| hour - this is an execution/load tool, not a profitable strategy.  |
//+------------------------------------------------------------------+
#property copyright "Built for MoraMakhlouf"
#property version   "1.00"
#property description "Opens a market order every N seconds (default 2) with SL/TP, hold-time exit and safety limits."

#define EA_MAGIC 20261020

enum ENUM_DIRECTION_MODE
  {
   DIR_ALTERNATE = 0, // Alternate buy / sell
   DIR_BUY_ONLY  = 1, // Buy only
   DIR_SELL_ONLY = 2, // Sell only
   DIR_RANDOM    = 3, // Random
   DIR_MOMENTUM  = 4  // Follow price move since last order
  };

//================================ INPUTS =============================
input string              InpSymbol        = "";            // Symbol (empty = chart symbol)
input int                 InpIntervalSec   = 2;             // Seconds between orders
input ENUM_DIRECTION_MODE InpDirection     = DIR_ALTERNATE; // Order direction
input double              InpLots          = 0.01;          // Lot size per order

input int    InpSLPoints      = 300;    // Stop loss in points (0 = none)
input int    InpTPPoints      = 300;    // Take profit in points (0 = none)
input int    InpHoldSec       = 30;     // Close each position after this many seconds (0 = off)

input int    InpMaxPositions  = 10;     // Max simultaneous positions from this EA (skip new orders above this)
input int    InpMaxOrdersDay  = 2000;   // Max new orders per day (0 = unlimited)
input double InpDailyLossPct  = 3.0;    // Stop opening orders for the day after this % loss (0 = off)
input int    InpMaxSpreadPts  = 60;     // Skip an order if spread (points) is above this. 0 = no limit

input bool   InpLiveTrading   = false;  // REAL accounts only: true = place real orders. Demo + tester always trade.

//================================ STATE ===============================
string   g_sym = "";
datetime g_day = 0;
double   g_dayStartEquity = 0.0;
int      g_ordersToday = 0;
bool     g_nextBuy = true;
double   g_lastPrice = 0.0;
bool     g_haltedToday = false;

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
int OnInit()
  {
   g_sym = (InpSymbol == "") ? _Symbol : InpSymbol;
   if(!SymbolSelect(g_sym, true))
     {
      Print("ERROR: symbol '", g_sym, "' not found. Type the exact VCG symbol name into InpSymbol.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(InpIntervalSec < 1 || InpLots <= 0)
     {
      Print("ERROR: InpIntervalSec must be >= 1 and InpLots > 0.");
      return INIT_PARAMETERS_INCORRECT;
     }
   if(!EventSetMillisecondTimer(InpIntervalSec * 1000))
     {
      Print("ERROR: could not start timer.");
      return INIT_FAILED;
     }
   MathSrand((uint)GetTickCount());
   g_lastPrice = SymbolInfoDouble(g_sym, SYMBOL_BID);
   Print("VCG Timer Orders EA on ", g_sym, ": one order every ", InpIntervalSec, "s, ",
         DoubleToString(InpLots, 2), " lots. Trading ", (TradingEnabled() ? "ENABLED" : "DISABLED (signal-only, real account)"));
   return INIT_SUCCEEDED;
  }

//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
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
double NormalizeLots(double lots)
  {
   double minLot = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MIN);
   double maxLot = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_MAX);
   double step   = SymbolInfoDouble(g_sym, SYMBOL_VOLUME_STEP);
   if(step > 0)
      lots = MathFloor(lots / step + 1e-9) * step;
   if(lots < minLot)
      lots = minLot;
   if(lots > maxLot)
      lots = maxLot;
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

   double sl = 0.0, tp = 0.0;
   if(InpSLPoints > 0)
     {
      double d = MathMax(InpSLPoints * point, minDist + 10 * point);
      sl = NormalizeDouble(isBuy ? entry - d : entry + d, digits);
     }
   if(InpTPPoints > 0)
     {
      double d = MathMax(InpTPPoints * point, minDist + 10 * point);
      tp = NormalizeDouble(isBuy ? entry + d : entry - d, digits);
     }

   MqlTradeRequest req;
   ZeroMemory(req);
   req.action       = TRADE_ACTION_DEAL;
   req.symbol       = g_sym;
   req.volume       = NormalizeLots(InpLots);
   req.type         = isBuy ? ORDER_TYPE_BUY : ORDER_TYPE_SELL;
   req.price        = entry;
   req.sl           = sl;
   req.tp           = tp;
   req.deviation    = 30;
   req.magic        = EA_MAGIC;
   req.comment      = "VCG Timer Orders";
   req.type_filling = GetFillingMode(g_sym);
   req.type_time    = ORDER_TIME_GTC;
   if(!SendRequest(req, isBuy ? "BUY" : "SELL"))
      return false;

   g_ordersToday++;
   Print((isBuy ? "BUY " : "SELL "), DoubleToString(req.volume, 2), " ", g_sym, " @", DoubleToString(entry, digits),
         " SL=", DoubleToString(sl, digits), " TP=", DoubleToString(tp, digits), " (#", g_ordersToday, " today)");
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
//| Time stop: close EA positions older than InpHoldSec seconds.       |
//+------------------------------------------------------------------+
void ManagePositions()
  {
   if(InpHoldSec <= 0)
      return;
   datetime now = TimeCurrent();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      ulong ticket = PositionGetTicket(i);
      if(ticket == 0)
         continue;
      if(PositionGetString(POSITION_SYMBOL) != g_sym || (int)PositionGetInteger(POSITION_MAGIC) != EA_MAGIC)
         continue;
      datetime opened = (datetime)PositionGetInteger(POSITION_TIME);
      if(now - opened >= InpHoldSec)
         ClosePosition(ticket, "time stop " + IntegerToString(InpHoldSec) + "s");
     }
  }

//+------------------------------------------------------------------+
//| Reset daily counters at the start of each server day.              |
//+------------------------------------------------------------------+
void UpdateDay()
  {
   MqlDateTime t;
   TimeToStruct(TimeCurrent(), t);
   t.hour = 0;
   t.min  = 0;
   t.sec  = 0;
   datetime today = StructToTime(t);
   if(today != g_day)
     {
      g_day            = today;
      g_dayStartEquity = AccountInfoDouble(ACCOUNT_EQUITY);
      g_ordersToday    = 0;
      g_haltedToday    = false;
     }
  }

//+------------------------------------------------------------------+
bool PickDirection(bool &isBuy)
  {
   double bid = SymbolInfoDouble(g_sym, SYMBOL_BID);
   switch(InpDirection)
     {
      case DIR_BUY_ONLY:
         isBuy = true;
         break;
      case DIR_SELL_ONLY:
         isBuy = false;
         break;
      case DIR_RANDOM:
         isBuy = (MathRand() % 2 == 0);
         break;
      case DIR_MOMENTUM:
         if(g_lastPrice <= 0 || bid == g_lastPrice)
           {
            g_lastPrice = bid;
            return false; // no move since last check - skip this interval
           }
         isBuy = (bid > g_lastPrice);
         break;
      default:
         isBuy = g_nextBuy;
         g_nextBuy = !g_nextBuy;
     }
   g_lastPrice = bid;
   return true;
  }

//+------------------------------------------------------------------+
void OnTimer()
  {
   UpdateDay();
   ManagePositions();

   if(!TradingEnabled())
      return;
   if(!(bool)SymbolInfoInteger(g_sym, SYMBOL_TRADE_MODE) || !TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      return;
   if(g_haltedToday)
      return;

   if(InpDailyLossPct > 0 && g_dayStartEquity > 0 &&
      AccountInfoDouble(ACCOUNT_EQUITY) <= g_dayStartEquity * (1.0 - InpDailyLossPct / 100.0))
     {
      g_haltedToday = true;
      Print("Daily loss limit of ", DoubleToString(InpDailyLossPct, 1), "% hit - no new orders until tomorrow.");
      return;
     }
   if(InpMaxOrdersDay > 0 && g_ordersToday >= InpMaxOrdersDay)
      return;
   if(CountPositions() >= InpMaxPositions)
      return;
   if(InpMaxSpreadPts > 0 && SymbolInfoInteger(g_sym, SYMBOL_SPREAD) > InpMaxSpreadPts)
      return;

   bool isBuy;
   if(PickDirection(isBuy))
      OpenTrade(isBuy);
  }

//+------------------------------------------------------------------+
void OnTick()
  {
   // all work is done in OnTimer so orders go out on a fixed clock, not on ticks
  }
//+------------------------------------------------------------------+
