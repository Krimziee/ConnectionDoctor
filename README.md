# Connection Doctor

Watches your connection live and explains in plain words where lag comes from:
your Wi-Fi or cable, your ISP, or the route to the game servers.

**It makes no changes to your PC.** It only measures. Fixes are shown as text for you to do yourself.
No admin rights needed.

## Start it

Double-click **`Connection Doctor.cmd`**. The live monitor starts straight away.

It's also a tab in **Krimz's Toolkit**. There, the live monitor only measures while its tab is selected:
it starts the first time you open the tab, pauses when you switch to another tab, and resumes
(with a fresh 30-second "Measuring...") when you come back. A test that's running carries on in the
background, and the tab shows a small dot until it's done.

## What you see

- **Verdict** at the top. The first one appears after 30 seconds, then it updates every 10 seconds.
  It only changes once a new pattern holds for 20 seconds, so one spike doesn't flip it.
- **Graph** of the last 2 minutes, one line per target. Red ticks at the bottom are lost pings.
  Click a tile to hide or show its line.
- **Tiles** for each target: current ping, normal ping, jitter, loss. Green, amber or red.
- **Wi-Fi strip** (only on Wi-Fi): signal, band, channel, and whether the signal is stable.
- **Events**: spikes and changes in plain sentences, e.g. *"Spike on everything, including your router → the problem is inside your home."*

## What it measures

| Target | How | Why |
|---|---|---|
| Your router | ping, every second | Separates "inside my home" from "outside" |
| Cloudflare, Google, Quad9 | ping, every second | Three different companies, so one having a bad moment isn't blamed on you |
| Frankfurt, London, US East | TCP connection, every 5 s | Distance to game hosting regions (AWS; Steam's relays as backup) |

Internet targets are judged on **stability** (jitter and lost packets), not on the ping number itself.
A steady 70 ms is normal in many countries; jumping ping and lost packets are what make games lag.

## Tests (buttons, optional)

| Button | What it does | Time |
|---|---|---|
| Connection Details | Cable or Wi-Fi details, link speed vs. network card and your plan, adapter errors | instant |
| DNS Test | Your DNS server's speed vs. Cloudflare and Google | ~10 s |
| Route Check | Finds where along the route lost packets start: your home, your ISP, or further out | ~20 s – 1 min |
| Lag Under Load | Downloads a test file (up to 100 MB, thrown away) and watches whether ping jumps (bufferbloat) | ~20 s |

The live monitor keeps running during a test, and the graph shades the test period.
Type your internet plan speed (optional) for Connection Details and Lag Under Load to compare against.

## Changing targets

Edit `targets.psd1`. The code doesn't need to change.

## Files

```
Connection Doctor.cmd   launcher
ConnectionDoctor.ps1    entry point
targets.psd1            what gets measured
modules\Network.ps1     reads adapter, router, DNS, Wi-Fi details
modules\Monitor.ps1     background measuring threads
modules\Judge.ps1       thresholds, verdict, events
modules\Tests.ps1       the four test buttons
modules\Ui.ps1          the page and the window
modules\Page.ps1        the Connection Doctor tab in Krimz's Toolkit
ui\Page.xaml            page layout (shown by the window and the toolkit tab)
ui\MainWindow.xaml      standalone window frame
ui\Theme.xaml           shared look (same as the toolkit)
```
