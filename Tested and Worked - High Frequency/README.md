# Tested and Worked - High Frequency

Both bots compile cleanly (0 errors, 0 warnings) and were run on the VCG MT5 terminal.
Like the other bots, they place orders on demo accounts and in the Strategy Tester only,
unless you set `InpLiveTrading = true`.

| Bot | Trades | Notes |
|---|---|---|
| `VCG_Timer_Orders_EA.mq5` | One order every 2 s (`InpIntervalSec`) | Execution/volume tool on any symbol. Alternate/buy/sell/random/momentum direction, fixed lots, SL/TP in points, closes after 30 s. Limits: 10 open positions, 2000 orders/day, 3% daily loss, max spread. Pays the spread on every order - not a profit strategy. |
| `VCG_Gold_M1_Momentum_EA.mq5` | Checks XAUUSD every 1 min, trades on signal (up to 20/day) | M15 EMA(50) trend + M1 EMA(20) pullback + RSI, ATR stop/target 3:6, 4-hour time stop, 0.5% risk per trade. |

Forward-test on demo before any real money. No strategy guarantees profit.
