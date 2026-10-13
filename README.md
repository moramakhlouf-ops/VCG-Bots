# VCG Mid-Cap Relative-Strength EA

An MQL5 Expert Advisor adapting the methodology from `SP400-MidCapStrategy-Report-USEK (1).pdf`
(stock/S&P 500 ratio → EMA(20)/EMA(50) crossover on a monthly Top-N relative-strength universe),
scoped automatically to whatever share CFDs **your own VCG Markets MT5 account** actually exposes.

**v1.01: standalone build.** No `#include`s at all — order placement uses raw
`OrderSend()`/`MqlTradeRequest` instead of the `Trade.mqh` library, and the strategy logic now
runs from both `OnTick()` and `OnTimer()` (so it behaves correctly in the Strategy Tester and on
a live/idle chart alike), guarded so it still only does work once per new daily bar / new month.

## What it does

1. On startup, scans every symbol your account can see and keeps the ones whose symbol
   path/description contains `InpGroupSubstring` (default `"Share"`) — or, if you fill in
   `InpManualSymbolList`, uses that fixed list instead. This is what scopes the bot to
   "stocks available at VCG Markets" without hardcoding a ticker list that could go stale.
2. Once a month, ranks that universe by 126-trading-day change in `Close(stock) / Close(benchmark)`
   and keeps the top `InpTopN` as the active universe (report used top-60 of 345; VCG's Shares
   list is far smaller, so the default is `InpTopN = 20` — tune this once you see your real
   universe size in the log).
3. Every day, computes EMA(20)/EMA(50) on the ratio series for the active universe (plus any
   symbol you're currently holding, so exits still fire if a name rotates out of the Top-N):
   - EMA(20) crosses **above** EMA(50) → BUY signal
   - EMA(20) crosses **below** EMA(50) → EXIT signal
4. Every signal is printed to the Experts log, optionally pushed to your phone
   (`InpSendPushAlerts`), and appended to a CSV (`InpSignalLogFile`, in `MQL5\Files`).

## Signal-only by default — read this before changing anything

`InpLiveTrading = false` by default. In that mode the EA **never calls `OrderSend`/`CTrade`** —
it only logs and alerts, so you can review signals and place trades yourself in MT5.

If you set `InpLiveTrading = true`, the EA will size positions with an equal-weight formula
(`equity × InpRiskEquityPct% / InpMaxPositions`) and send real market orders via `CTrade` —
**on whatever account the EA is attached to.** I'm not able to run or test that mode for you;
if you enable it, do it on a demo account first, understand the code, and accept the risk
yourself. I won't place trades and didn't wire this to auto-enable.

## Two things the report itself flags that you should know before trusting this

- **The ML filter in the report doesn't actually help.** Its Random Forest layer scored
  AUC-ROC 0.4768 — *below* the 0.5 "random guess" baseline — and its own table shows
  ML-confirmed signals won 52.7% of the time vs. 55.8% for the signals it *rejected*. That's
  the filter removing better trades than it keeps, the opposite of what it's supposed to do,
  even though the report's prose calls it "genuine predictive value." Because of this, and
  because a real Random Forest isn't practical to run natively inside MQL5, **this EA
  implements only the EMA/RS crossover core (the part with the actual backtested edge,
  Sharpe 0.73), not the ML layer.** If you still want it despite the numbers above, the
  realistic path is a hybrid: retrain the model in Python on a schedule, export its signal
  scores to a file, and have the EA read that file — say the word and I'll build that piece.
- **The backtested edge is specific to S&P 400 *mid-caps*, not large-caps.** The report
  explicitly chose mid-caps for their "higher return dispersion" (page 3). VCG's Shares list
  is headlined by mega-caps (Tesla, Apple, Alphabet, Microsoft, Amazon in the popular list) —
  there's no backtest evidence this edge transfers to that universe. Treat this as an
  unvalidated hypothesis on VCG's instrument list until you've run it through MT5's
  Strategy Tester on your actual symbols and a multi-year history.

## Setup

1. Open **MetaEditor** from your MT5 terminal → File → New → Expert Advisor → paste this file's
   content into `VCG_MidCap_RS_EA.mq5` (or copy the file directly into
   `MQL5/Experts/`) → Compile. I can't compile/run MT5 here myself — if you hit compiler
   errors, paste them back to me and I'll fix the code.
2. In Market Watch, find VCG's S&P 500 index CFD (commonly `US500`, `SPX500`, or `USA500`) and
   set `InpBenchmarkSymbol` to the exact name.
3. Attach the EA to any chart (the symbol/timeframe of that chart doesn't matter — the EA scans
   its own universe). On first run it prints every distinct symbol group path it found in the
   Experts log — use one of those strings as `InpGroupSubstring` if `"Share"` doesn't match.
4. Leave `InpLiveTrading = false`, enable AutoTrading, and let it run for at least one full
   month so you see a real rebalance + signals in the log/CSV before deciding whether to trust it.
5. Backtest it in Strategy Tester (with real tick data if available) against your actual VCG
   symbol list to see whether the edge holds before ever setting `InpLiveTrading = true`.

## Key inputs

| Input | Default | Meaning |
|---|---|---|
| `InpBenchmarkSymbol` | `US500` | Benchmark for the ratio series |
| `InpGroupSubstring` | `Share` | Filters Market Watch to build the universe |
| `InpManualSymbolList` | *(empty)* | Comma-separated override list |
| `InpTopN` | `20` | Monthly active-universe size |
| `InpRSLookbackDays` | `126` | RS ranking lookback (report default) |
| `InpEMAFast` / `InpEMASlow` | `20` / `50` | Crossover periods |
| `InpLiveTrading` | `false` | Master switch for real order placement |
| `InpMaxPositions` | `20` | Equal-weight sizing denominator / position cap |
| `InpRiskEquityPct` | `100.0` | % of equity spread across `InpMaxPositions` slots |
