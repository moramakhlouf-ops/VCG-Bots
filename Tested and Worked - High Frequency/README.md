# Tested and Worked - High Frequency

Both bots compile cleanly (0 errors, 0 warnings) and were run on the VCG MT5 terminal.
Like the other bots, they place orders on demo accounts and in the Strategy Tester only,
unless you set `InpLiveTrading = true`.

| Bot | Trades | Notes |
|---|---|---|
| `VCG_Timer_Orders_EA.mq5` | One order every 2 s (`InpIntervalSec`) | Execution/volume tool on any symbol. Alternate/buy/sell/random/momentum direction, fixed lots, SL/TP in points, closes after 30 s. Limits: 10 open positions, 2000 orders/day, 3% daily loss, max spread. Pays the spread on every order - not a profit strategy. |
| `VCG_Gold_M1_Momentum_EA.mq5` | Checks XAUUSD every 1 min, trades on signal (up to 20/day) | M15 EMA(50) trend + M1 EMA(20) pullback + RSI, ATR stop/target 3:6, 4-hour time stop, 0.5% risk per trade. |

## Backtest results (MT5 Strategy Tester, VCG XAUUSD, every tick based on real ticks, $10,000 start, 1:100)

| | Gold M1 Momentum (default inputs) | Timer Orders (default inputs) |
|---|---|---|
| Period | 2026-07-01 -> 2026-10-19 | 2026-10-01 -> 2026-10-19 |
| Total trades | 1,166 | 9,610 |
| Win rate | 33.9% (longs 34.6%, shorts 33.2%) | 20.8% (longs 19.4%, shorts 22.2%) |
| Net profit | **-$574.79 (-5.7%)** | **-$3,063.39 (-30.6%)** |
| Gross profit / gross loss | $34,886.41 / -$35,461.20 | $730.81 / -$3,794.20 |
| Profit factor | 0.98 | 0.19 |
| Avg result per trade | -$0.49 | -$0.32 |
| Max equity drawdown | $2,409.52 (23.4%) | $3,063.66 (30.6%) |
| Sharpe ratio | -0.67 | -5.00 |

Neither bot is profitable with default inputs. The Timer bot's loss is mostly the spread paid on
~700 orders per day. It is meant for testing execution and volume, not for profit.

## Gold M1 research (VCG XAUUSD M1 bars, Jan 2025 -> Oct 2026, spread included)
- About 480 M1 setups tested (pullback, breakout, RSI, Bollinger fade); parameters picked on 2025, checked on 2026.
- Best robust result was roughly break-even: profit factor ~0.99 (2025) / ~1.01 (2026), win rate ~34%, before commission.
- A tighter-stop version (1.5/2.5 ATR, 90-min time stop) lost -$4,104 (-41%) on Jul-Oct 2026:
  1,273 trades, 46.0% win rate, profit factor 0.81, max drawdown 42.6%.
- Forward-test on demo before any real money. No strategy guarantees profit.
