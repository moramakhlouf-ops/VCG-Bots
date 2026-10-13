# New VCG bots (researched on 2022 -> Oct 2026 daily data)

All four are long-only, daily-timeframe Expert Advisors. On real/demo accounts they only log
signals unless you set `InpLiveTrading = true` yourself. In the Strategy Tester they place
simulated trades.

## How they were chosen
- 6 strategy families x parameter grids tested on gold, silver, oil, S&P 500, Nasdaq 100 and
  8 US mega-caps (daily data, trading costs included).
- Parameters were picked using **2022-2024 only**. **2025 -> Oct 2026 was never used for
  picking** and every long-only strategy stayed positive there.
- Short-selling versions were tested and **failed**, so every bot is long-only.
- Data source: Yahoo Finance (gold = GC=F futures). VCG's CFD prices will differ slightly.

## Results, 2022-01-01 -> 2026-10-12 (100% notional, costs in, swap NOT in)

| Bot | Total | Max DD | Sharpe | 2022 | 2023 | 2024 | 2025 | 2026 YTD |
|---|---|---|---|---|---|---|---|---|
| Gold Trend (EMA 50/100) | +123% | -19% | 1.06 | +1.6 | +6.2 | +27.5 | +64.4 | -1.3 |
| Index Pullback (RSI-2) | +56% | -10% | 1.08 | -1.9 | +7.7 | +17.8 | +11.2 | +12.5 |
| Stock Breakout (100-day high) | +79% | -13% | 1.11 | -2.7 | +28.4 | +21.6 | +10.8 | +6.5 |
| Stock Pullback (RSI-2) | +51% | -12% | 0.94 | -0.5 | +12.9 | +17.0 | +3.0 | +11.6 |

Reference (buy & hold): gold +130% / -25% DD; 8-stock basket +196% / -50% DD.

## Read this before using real money
- **Not every year is profitable** (see the table), and nothing here guarantees future results.
- **The stock bots earn less than just holding the stocks** in this bull market. Their value is
  a much smaller drawdown (-12% vs -50%), not higher return.
- **Gold Trend made only ~2 trades** in 4.7 years - the result rests on a very small sample.
- Overnight financing (swap) on CFDs is not in the numbers and will reduce returns, mostly on
  gold and the index CFDs held for weeks or months.
- I have compiled these but **not run them in the MT5 Strategy Tester**; confirm there first.

## Test each bot in the Strategy Tester
Settings tab: Expert = the bot; Symbol = XAUUSD (Gold), US500Roll (Index), or Apple (stocks);
Timeframe = Daily; Date = Custom 2022.01.01 -> 2026.10.01; **Modelling = 1 minute OHLC**;
Deposit 7500. Press Start, then read the Backtest tab and the Journal tab.

| File | Symbol it trades |
|---|---|
| VCG_Gold_Trend_EA | XAUUSD |
| VCG_Index_Pullback_EA | US500Roll + UT100Roll |
| VCG_Stock_Breakout_EA | Apple, Microsoft, Nvidia, Amazon, Alphabet, Meta, Tesla, AMD |
| VCG_Stock_Pullback_EA | same 8 stocks |

Symbols VCG does not offer are skipped with a warning in the Journal.
