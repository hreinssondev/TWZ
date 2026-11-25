# TWZ

A fast macOS day-trading front end for Interactive Brokers. It talks to IB Gateway (or TWS) over
the TWS API socket directly, with no IB libraries, and puts charts, scanners, hotkeys and order
management in one window built for quick entries and exits.

> **Use at your own risk.** TWZ sends real orders to your IB account. It is not affiliated with
> Interactive Brokers, comes with no warranty (see [LICENSE](LICENSE)), and isn't financial advice.
> Try it on a paper account first: it connects to the paper gateway port (4002) by default.

## Features

- **Chart grid** from 2×2 up to 8×4 that follows the top gainers in rank order, or a list you load
  into it. Any chart can be given a stock by hand: it keeps it, the stock it showed leaves the grid so
  no other chart moves, and the list flows on through the other charts, until the top bar's Reset
  hands it back (Reset, or ⌘R / ⇧R / ⌥R / ⌃R / ⌘⇧R, keeps the list loaded). ⌥⇧ and a color's letter outlines the selected
  chart's stock in that color on every chart, one stock per color, kept while it's off the charts (⌥⇧⌫
  takes it off).
- **Candlestick charts** drawn with one SwiftUI Canvas: trackpad and mouse pan / zoom (older bars load
  as you scroll back), 1m to daily, pre-market, after hours and overnight shading, VWAP and SMA 9 / 21,
  volume, tick-by-tick trades on the selected chart. ⌥1–6 or ⌃1–6 (one modifier alone) switches every chart (1m, 5m, 15m, 30m, 1h, D),
  keeping each chart's view: the same time on screen, only the candles change (or, with that off in
  Settings › Appearance, each timeframe going back to its own zoom and place).
- **Chart views**: each stock keeps where its view was left (per timeframe, and per list in the
  grid), across list switches and relaunches, until Reset or a right-click on the chart. ⇧-, ⌘-, ⌥- or ⌃-swipe
  (any of them, together too) zooms every chart from the swiped one's zoom, the top bar's Zoom slider
  following (⌃⌥-swipe squeezes or
  stretches one chart's price axis); ´ goes back to the grid shown before (its list and timeframe) and again comes back; ⌥0 or ⇧A gives every chart the selected one's zoom,
  place and price scale. ⇧-clicking 1–5 in the top bar saves every chart's zoom and place on every
  timeframe as a view set, and clicking one puts them back;
  with Settings › Appearance's "Top bar numbers are scales" on, ⇧-click saves the selected chart's view
  as a scale instead, and picking one gives it to every chart (and those loading another stock). The bars
  a chart showed, on every timeframe, stay in memory and on disk (two days after last shown), so coming
  back to them, also after a relaunch or zoomed far out, shows at once.
- **Trading from the chart**: ⌃-click places a stop loss or take profit, and order lines show their
  fill as it happens. Double-click an order line to cancel it.
- **Trend lines**: ⌘⇧-click a chart for a horizontal line at that price, kept per stock on every timeframe
  and chart; double-click it to remove it. Color, style, width and price box in Settings › Appearance.
- **$ / % switch** (⌘⇧M, or the order pad's $ and %): the order numbers are dollars, $1,000 a step (1–9 are
  $1,000–$9,000), or a percent of the buying power IB's margin allows in the stock, 20% a step (1–4 are 20%, 40%,
  60%, 80%; 5–9 send nothing). The top bar's KEYS badge shows it: KEYS $ or KEYS %.
- **Order pad and hotkeys**: the order pad's buttons pick an order: $ or %, the price or order type (mid, bid,
  ask, last, across the spread, market or IBKR MIDPRICE) and 1–9. Beside it, configurable hotkey buttons
  (buying, selling, closing, cancelling), each with an optional keyboard shortcut; clicking one selects it in
  place of the pad's order. ⌘⇧↩ sends the selected hotkey, or buys the pad's order; ⌥⌘⇧↩ sells the pad's order
  short; ⌘⌫ cancels the symbol's orders and closes the position at market.
- **KEYS ON and SIM** (⌘ and the Globe (fn) key switch): with KEYS ON every order shortcut (order keys, hotkeys'
  own, ⌘⇧↩, ⌥⌘⇧↩, ⌘⌫) goes to IB; in SIM, as at launch, the same shortcuts trade what-if positions instead,
  never sent to IB, filled at once at the order's price (a limit at its reference ± offset, MIDPRICE at the
  mid, market at the ask or bid); ⌘⌫ closes the what-if trade. At launch it's KEYS ON instead when a live
  position is open. Either way the charts and Positions show the real positions and orders and the what-if
  trades together, the real positions on top and a row's space above the what-if trades. The top bar reads KEYS $ / KEYS % in orange, or SIM $ / SIM % dimmed.
- **Order keys** (Settings › Order Keys): keyboard shortcuts that send an order without a button, listed by
  shortcut, added, edited or deleted there, beside the hotkey buttons' shortcuts and the fixed ones. By default
  ⌘1–9 buys and ⌥⌘1–9 sells short that many steps of the $ / % switch (⌘3: $3,000 or 60%; the buy and sell
  modifier keys can be changed there: click, hold them, press ↩), all limit at the mid, no offset, outside
  regular hours too. Once per press, for real with KEYS ON, as what-if trades in SIM. A hotkey button given an
  order key's shortcut overrides that order key while it has it; deleted, or its shortcut changed, the order
  key works again.
- **What-if trades**: ⌃⌥⇧1–4 shorts $1,000 / $2,000 / $3,000 / 85% of the buying power
  of the selected chart's stock, simulated and never sent to IB; on the chart, an arrow, green for a long
  and red for a short, ringed in pink, points at each of its fills. It shows like a position, its symbol in pink,
  with its P/L and IB's commission estimate, and ⌃-click gives it a simulated stop loss or take profit.
- **Scanner lists**: gainers, losers, after-hours gainers and most active by dollar volume, with
  each stock's 5-minute change. One click charts a stock; the load button fills the grid from a list.
- **Orders, fills and positions** side by side or stacked, with today's round trips and their P/L.
  Positions lists the real positions and the what-if trades together. Double-clicking a position, order or round trip selects its stock's
  chart; with none on screen, the grid goes back to where it last showed the stock (its list, as ⌘⇧
  and the list's letter loads it, and its cell) instead of replacing a chart you're looking at; one it
  never showed goes to the list that has it now (the grid's own first), and a forex pair always to Forex.
- **Forex**: the lists' Forex option shows the main currency pairs on IBKR's IDEALPRO (majors,
  crosses and the NOK / SEK pairs), ranked by % change; a chart takes a pair typed as EUR.USD, EURUSD
  or EUR/USD. Pairs chart as bid/ask midpoints around the clock and trade like stocks from hotkeys,
  ⌥ / ⌃-click and ⌘⌫, sized in units of the first currency (hotkey offsets count a cent as a pip).
  Orders go as forex CFDs, leveraged the way IBKR's European accounts trade currencies, or as
  IDEALPRO spot (Settings › Trading).
- **Short selling info**: shortable status and shares to lend, borrow fees, and the SEC Rule 201
  short sale restriction (from Nasdaq's daily list and IB's prices), with SSR-aware order pricing.
- **Menu bar P/L**: the open positions' P/L in NOK as a bare number, green or red; with no position
  open, the what-if trades'. A click brings TWZ to the front.
- **Charts window**: a second grid of the top 18 gainers (or any size you set).
- **Appearance**: candle and line colors, line styles, presets and saved window layouts.
- **Confetti** over every screen when a LIVE trade opens (Settings › Trading).

Account values and order amounts are shown in your account's base currency; the NOK amounts shown
assume a NOK base currency (converted at the live USD/NOK rate).

## Requirements

- macOS 27 or later.
- IB Gateway or TWS with the API enabled (Configure › Settings › API: *Enable ActiveX and Socket
  Clients*), and market data subscriptions for the stocks you trade. Forex quotes are free; trading
  pairs needs the CFD trading permission (or Forex, for spot orders).

## Building

1. Open `TWZ.xcodeproj` in Xcode.
2. Under the TWZ target's *Signing & Capabilities*, pick your own team.
3. Run. In Settings › Connection, set the gateway's host, port (4002 paper / 4001 live for IB
   Gateway, 7497 / 7496 for TWS) and a client ID, then Connect. After the Mac sleeps, TWZ reconnects
   on its own a few seconds after waking (trying again every 10 s for two minutes if the gateway isn't back).
   Settings › Connection › Keep the Mac awake (on by default) stops idle sleep while TWZ runs, so the
   gateway stays reachable from elsewhere.

## License

[MIT](LICENSE)
