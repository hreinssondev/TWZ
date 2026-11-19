# TWZ

A fast macOS day-trading front end for Interactive Brokers. It talks to IB Gateway (or TWS) over
the TWS API socket directly, with no IB libraries, and puts charts, scanners, hotkeys and order
management in one window built for quick entries and exits.

> **Use at your own risk.** TWZ sends real orders to your IB account. It is not affiliated with
> Interactive Brokers, comes with no warranty (see [LICENSE](LICENSE)), and isn't financial advice.
> Try it on a paper account first: it connects to the paper gateway port (4002) by default.

## Features

- **Chart grid** from 2×2 up to 8×4 that follows the top gainers in rank order, or a list you load
  into it. Any chart can be given a stock by hand: it keeps it, and the list flows on through the other
  charts, until the top bar's Reset hands it back. ⌘⇧ and a color's letter outlines the selected
  chart's stock in that color on every chart, one stock per color, kept while it's off the charts (⌘⇧⌫
  takes it off).
- **Candlestick charts** drawn with one SwiftUI Canvas: trackpad and mouse pan / zoom, 1m to daily,
  pre-market, after hours and overnight shading, VWAP and SMA 9 / 21, volume, tick-by-tick trades on
  the selected chart.
- **Trading from the chart**: ⌥-click places the selected hotkey's order (or a fixed NOK amount) at
  the clicked price, ⌃-click a stop loss or take profit, and order lines show their fill as it
  happens. Double-click an order line to cancel it.
- **Hotkeys**: a grid of configurable buttons (buy, sell, close half / all, cancel, flatten) priced
  off the bid, ask, mid, last or market, each with an optional keyboard shortcut. ⌘⌫ cancels the
  symbol's orders and closes the position at market.
- **What-if trades**: ⌥⇧1–4 buys (⌃⌥⇧1–4 shorts) $1,000 / $2,000 / $3,000 / 85% of the buying power
  of the selected chart's stock, simulated and never sent to IB. It shows like a position, marked SIM,
  with its P/L and IB's commission estimate, and ⌃-click gives it a simulated stop loss or take profit.
- **Scanner lists**: gainers, losers, after-hours gainers and most active by dollar volume, with
  each stock's 5-minute change. One click charts a stock; the load button fills the grid from a list.
- **Orders, fills and positions** side by side or stacked, with today's round trips and their P/L.
- **Forex**: the lists' Forex option shows the main currency pairs on IBKR's IDEALPRO (majors,
  crosses and the NOK / SEK pairs), ranked by % change; a chart takes a pair typed as EUR.USD, EURUSD
  or EUR/USD. Pairs chart as bid/ask midpoints around the clock and trade like stocks from hotkeys,
  ⌥ / ⌃-click and ⌘⌫, sized in units of the first currency (hotkey offsets count a cent as a pip).
  Orders go as forex CFDs, leveraged the way IBKR's European accounts trade currencies, or as
  IDEALPRO spot (Settings › Trading).
- **Short selling info**: shortable status and shares to lend, borrow fees, and the SEC Rule 201
  short sale restriction (from Nasdaq's daily list and IB's prices), with SSR-aware order pricing.
- **Charts window**: a second grid of the top 18 gainers (or any size you set).
- **Appearance**: candle and line colors, line styles, presets and saved window layouts.
- **Confetti** over every screen when a LIVE trade opens (Settings › Trading).

Account values and order amounts are shown in your account's base currency; the NOK amounts in
the order entry box and ⌥-click sizing assume a NOK base currency (converted at the live USD/NOK
rate).

## Requirements

- macOS 27 or later.
- IB Gateway or TWS with the API enabled (Configure › Settings › API: *Enable ActiveX and Socket
  Clients*), and market data subscriptions for the stocks you trade. Forex quotes are free; trading
  pairs needs the CFD trading permission (or Forex, for spot orders).

## Building

1. Open `TWZ.xcodeproj` in Xcode.
2. Under the TWZ target's *Signing & Capabilities*, pick your own team.
3. Run. In Settings › Connection, set the gateway's host, port (4002 paper / 4001 live for IB
   Gateway, 7497 / 7496 for TWS) and a client ID, then Connect.

## License

[MIT](LICENSE)
