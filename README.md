# VCG Bots

MQL5 Expert Advisors (EAs) for MetaTrader 5 on VCG Markets. Every bot is a single standalone
`.mq5` file with no `#include`s: copy it into `MQL5/Experts/`, compile it in MetaEditor, and
attach it to a chart.

## Repository layout

| Folder | What's inside |
|---|---|
| `Tested and Worked - High Frequency/` | Bots that trade many times per day (every 2 seconds / every minute). Compiled and run on the VCG MT5 terminal. |
| `Tested - Lower Frequency - Needs Adjustments/` | Daily, H1 and M5 bots. Tested, but they trade less often and still need tuning. |

## High-frequency bots

| Bot | Symbol | How often | Logic |
|---|---|---|---|
| `VCG_Timer_Orders_EA` | Chart symbol (or `InpSymbol`) | One order every 2 s (`InpIntervalSec`) | Opens a market order on a fixed timer. Direction: alternate, buy only, sell only, random, or follow the last price move. Fixed lots, SL/TP in points, closes each position after 30 s. Execution/volume tool, not a profit strategy: it pays the spread on every order. |
| `VCG_Gold_M1_Momentum_EA` | XAUUSD | Checks every 1 min, up to 20 trades/day | M15 EMA(50) trend + M1 EMA(20) pullback bounce + RSI(14). ATR stop/target 3:6, 4-hour time stop, 0.5% risk per trade. Experimental. |

## Lower-frequency bots

| Bot | Symbol(s) | Timeframe | Logic |
|---|---|---|---|
| `VCG_Gold_EA` | XAUUSD | H1 | EMA(200) trend + EMA(20/50) alignment, ADX filter, RSI pullback entry, ATR stop/target and trail. Long + short. |
| `VCG_Gold_Scalper_EA` | XAUUSD | M5 | EMA(50) trend + fast RSI(5) pullback, ATR stop/target, breakeven, time stop. Long + short. |
| `VCG_Gold_Trend_EA` | XAUUSD | D1 | Holds gold while EMA(50) > EMA(100); exits when it falls below. Long only. |
| `VCG_Index_Pullback_EA` | US500Roll + UT100Roll | D1 | Buys dips: RSI(2) < 15 above the 200-day average; exits when RSI(2) > 80. Long only. |
| `VCG_Stock_Breakout_EA` | Apple, Microsoft, NVIDIA, Amazon, Alphabet, Tesla, AMD | D1 | Buys a close above the prior 100-day high; exits on a close below the prior 20-day low. Long only, equal weight. |
| `VCG_Stock_Pullback_EA` | Same stocks | D1 | Buys dips: RSI(2) < 15 above the 200-day average; exits when RSI(2) > 70. Long only, equal weight. |
| `VCG_Apple_RS_EA` | Apple vs S&P 500 | D1 | Relative-strength ratio (Apple / S&P 500), EMA(20)/EMA(50) crossover. |
| `VCG_MidCap_RS_EA` | One stock, or every share CFD on the account | D1 | Same relative-strength crossover. Multi-symbol mode ranks shares monthly by 126-day relative strength and trades the top `InpTopN`. |

The stock bots list Meta in their default symbol list, but VCG does not offer Meta, so it is
skipped with a warning in the Journal. The relative-strength bots implement only the EMA
crossover from the original S&P 400 mid-cap report, not its machine-learning filter, and that
report's edge was measured on mid-caps, not the mega-caps VCG offers.

## Safety: when bots place real orders

| Bot | Strategy Tester | Demo account | Real account |
|---|---|---|---|
| Timer Orders, Gold M1 Momentum, Gold Scalper | Trades | Trades | Signal only unless `InpLiveTrading = true` |
| All other bots | Trades | Signal only unless `InpLiveTrading = true` | Signal only unless `InpLiveTrading = true` |

"Signal only" means the bot logs signals in the Experts tab but sends no orders. Algo Trading
must be switched on in the MT5 toolbar for any bot to trade.

Built-in limits (inputs on each bot): max open positions, max trades per day, daily loss
limit, max spread, and trading hours on the intraday bots; risk-based lot sizing capped at 90%
of free margin.

## Install

1. Copy the `.mq5` file into your terminal's `MQL5/Experts/` folder
   (MT5: File -> Open Data Folder).
2. Open it in MetaEditor and press Compile (F7).
3. In MT5, drag the EA from the Navigator onto a chart, tick **Allow Algo Trading**, and check
   the inputs. The chart's symbol only matters for `VCG_Timer_Orders_EA` (when `InpSymbol` is empty)
   and single-symbol `VCG_MidCap_RS_EA`.

## Test in the Strategy Tester first

| Bot type | Timeframe | Modelling |
|---|---|---|
| Timer Orders, Gold M1 Momentum | M1 or M5 | Every tick based on real ticks |
| Gold Scalper, Gold EA | M5 / H1 | Every tick based on real ticks |
| Daily bots | D1 | 1 minute OHLC |

Pick Custom dates, set the deposit, press Start, then read the Backtest and Journal tabs.
Spread, commission and overnight swap all matter, most of all for the high-frequency bots.
Forward-test on a demo account before using real money. No strategy guarantees profit.

VCG symbol names: `XAUUSD`, `US500Roll`, `UT100Roll`, `Apple`, `Microsoft`, `NVIDIA`, `Amazon`,
`Alphabet`, `Tesla`, `AMD`.
