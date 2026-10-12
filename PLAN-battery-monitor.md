# Battery guard for always-on laptop servers

> **Status: Implemented** in `lib/battery-monitor.sh` (2026-10-12). Kept as historical context for why the checks exist and why they are opt-in.

## Context

`t480-server` (the Home Assistant host) is a ThinkPad running 24/7 on AC in a
closet with two batteries (internal BAT0 + external BAT1). Until 2026-10-12 both
sat at 100% around the clock, the main driver of Li-ion wear and swelling. The
house rides out grid outages on whole-home batteries, so the laptop packs only
need to bridge a circuit-breaker blip. The dotfiles now cap charging at 65/70%
(`battery-charge-limit.service`, bootstrap step 14).

A charge cap is the kind of thing that fails silently. The EC can drop its
thresholds, the boot unit might not run, or a pack might stop charging. Nobody
looks at a closet laptop's battery, so a monitor has to.

## Design

Three independent checks per pack, all opt-in (empty = off). With all three off
the check does not sample, so bambam and everyday laptops are untouched:

- **low** (`BATTERY_LOW_PCT`, t480: 60). Below 60 the pack is either running the
  machine (AC gone — breaker trip or outage) or not charging back up despite AC
  (charge cap/EC fault, failing pack). The message says which, from the Mains
  supply's `online` flag.
- **high** (`BATTERY_HIGH_PCT`, t480: 75). The cap is not holding. It must stay
  off until the packs have actually been drained below it, or it fires at once.
- **threshold** (`BATTERY_EXPECT_END_THRESHOLD`, t480: 70). The charge-stop
  setting itself drifted. This is the leading indicator: it fires the moment the
  cap is lost, where *high* only fires after the pack has charged past 75%.

Alerts go through `send_alert` like the other monitors, so on t480 they reach
Healthchecks via hc-bridge. Cooldown 30 min per pack+check.

## Rejected

- **Combined capacity across packs.** ThinkPads drain the external pack first,
  so a combined figure hides the one that matters. Per-pack is also simpler.
- **Enabled by default on any machine with a battery.** A laptop that is
  actually used on battery would alert every time it dropped below 60%.
