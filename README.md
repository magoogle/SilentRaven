# SilentRaven

**Author:** magoogle
**Version:** v0.1 (untested — first release for live validation)

A standalone Tree-of-Whispers turn-in plugin for the QQT Lua host (Diablo 4). Auto-claims whisper bounty caches whenever the player is in town with 10/10 Grim Favor, and exposes an Alfred-style global plugin so other scripts can interrupt themselves to do a turn-in.

## What it does

- Detects when the bounty meta-quest objective flips to "Return to the Tree of Whispers..." (10/10 Grim Favor).
- Walks to the nearest Tree / Crow / Bounty Raven NPC in the live actor stream.
- Re-fires `interact_object` on a 1.5 s cadence until the reward panel verifies open.
- Claims via `quest_reward.pick_and_accept(reward_index)` (host API). Falls back to a calibrated two-click pixel sequence if the API isn't available.
- Verifies the bounty quest is gone from the log. Latches per-zone so it doesn't re-fire until you leave and come back.

## Two ways to trigger it

### 1. Auto-fire (default)

Toggle `Enable` and `Auto-fire in town` in the GUI. SilentRaven will claim a ready turn-in any time the player is standing in `Skov_Temis` or `Hawe_TreeOfWhispers` with a bounty ready and the NPC visible. No other configuration needed.

### 2. Call-driven (Alfred-style)

Other scripts can interrupt themselves to do a Whispers run via the global plugin:

```lua
-- In your script's main pulse, before doing your own work:
if SilentRavenPlugin and SilentRavenPlugin.is_available() then
    local s = SilentRavenPlugin.get_status()
    if s.running then
        return    -- yield this pulse; SilentRaven owns input
    end
end

-- When you decide it's time to claim:
if want_whispers_now then
    SilentRavenPlugin.trigger_tasks_with_teleport('my_script', function(result)
        -- result is one of:
        --   'success'         -- bounty quest gone from log
        --   'failed'          -- gave up after MAX_RETRIES
        --   'cancelled'       -- another script called .cancel()
        --   'skipped_latched' -- already turned in this town visit
        --   'disabled'        -- plugin disabled mid-run
    end)
end
```

`trigger_tasks_with_teleport` casts town portal to Skov_Temis (waypoint SNO `0x1CE51E`) before walking to the NPC. Use `trigger_tasks` instead if the player is already in town and you want to skip the TP.

### Plugin API reference

| Function | Effect |
|---|---|
| `SilentRavenPlugin.get_status()` | Returns a status table (see below). |
| `SilentRavenPlugin.is_available()` | `true` when the plugin is loaded and enabled. |
| `SilentRavenPlugin.trigger_tasks(caller, callback)` | Queue a turn-in run starting in town. |
| `SilentRavenPlugin.trigger_tasks_with_teleport(caller, callback)` | Queue a turn-in; TP to Skov_Temis first if not already in town. |
| `SilentRavenPlugin.pause(caller)` | Soft-freeze the FSM (state preserved). |
| `SilentRavenPlugin.resume()` | Resume from `pause`. |
| `SilentRavenPlugin.cancel(caller)` | Abort any pending or in-flight run; sends Escape to close any open panel. Fires the callback with `'cancelled'`. |
| `SilentRavenPlugin.check_version("v0.1")` | Returns `true` when the running plugin is at least the requested version. |

### Status table

```lua
{
    name            = 'silent_raven',
    version         = '0.1',
    author          = 'magoogle',
    enabled         = true|false,         -- master toggle
    running         = true|false,         -- FSM in flight; callers should yield
    ready           = true|false,         -- 10/10 Grim Favor and turn-in is queued
    last_reason     = 'auto'|'external'|'external+tp'|'manual',
    last_result     = 'success'|'failed'|'cancelled'|nil,
    last_result_t   = number,             -- get_time_since_inject() at last finalize
    all_task_done   = true|false,         -- true between runs
    state           = 'TELEPORTING'|'WALK_NPC'|...|nil,
    attempts        = number,             -- 0..MAX_RETRIES (3)
    last_zone_handled  = 'Skov_Temis'|...|nil,
    last_observed_zone = string|nil,
    paused          = true|false,
    paused_by       = string|nil,
}
```

`PLUGIN_silent_raven` is also exposed as a legacy alias matching Alfred's convention. Prefer `SilentRavenPlugin` in new code.

## Installation

1. Drop the `SilentRaven` directory into your QQT scripts folder (the same directory that contains `AlfredTheButler-main`, `Reaper`, etc).
2. Restart the QQT host or reload scripts.
3. Open the QQT menu, find the **`magoogle | SilentRaven | v0.1`** tree, toggle `Enable`.

Console output is the primary observability channel. Turn on `Debug logging` to see FSM transitions while calibrating.

## GUI options

| Option | Purpose |
|---|---|
| **Enable** | Master toggle. Disables all auto-fire and ignores external triggers when off. |
| **Auto-fire in town** | When enabled, claims turn-ins automatically while in `Skov_Temis` / `Hawe_TreeOfWhispers`. Disable to make the plugin strictly call-driven. |
| **Debug logging** | Print FSM transitions to console. |
| **Manual trigger keybind** | Press to fire a turn-in run now (TP-to-Temis included). |
| **Reward card index** | 1-based, matches the `[N]` keys from "Dump reward options". Live S09 returns 4 cards (Helms / Legs / Rings / Rings); count and order vary by season — dump first, then pick. |
| **Use click fallback** | Force the two-click pixel path instead of the `quest_reward` API. Defensive — only enable if the API isn't claiming reliably on your host. |
| **Show calibration overlay** | Render crosshairs at the configured reward + accept click points so you can dial them in without consuming a turn-in. |
| **Reward / Accept X-Y (per-mille)** | Click points for the fallback path, expressed as 0.001 units of screen size (500 = mid-screen). Resolution-independent. |

## State machine

```
nil (idle)
  └── trigger fired (auto / external / manual)
        ├── if not in town and TP requested
        │     └── TELEPORTING ──── waypoint cast on debounce, wait for Skov_Temis
        │           └── (zone == Skov_Temis) → start of attempt
        │
        └── (in town) start of attempt
              ├── reward_panel_open() == true → fire_claim
              ├── NPC in stream + in range → INTERACT_NPC
              └── NPC in stream + too far → WALK_NPC ──→ INTERACT_NPC

INTERACT_NPC
  ├── reward_panel_open() == true → fire_claim
  ├── elapsed >= INTERACT_RETRY_INTERVAL_S → re-fire interact_object
  └── elapsed >= NPC_PANEL_TIMEOUT_S → WAIT_RETRY (or FAILED at max retries)

fire_claim
  ├── quest_reward.pick_and_accept(idx) ok → API_CLAIMING
  └── click fallback → CLICK_CARD ──(pause)──> CLICK_ACCEPT

API_CLAIMING / CLICK_ACCEPT
  ├── is_bounty_quest_present() == false → DONE
  └── timeout (CLAIM_VERIFY_TIMEOUT_S) → WAIT_RETRY (or FAILED)

DONE / FAILED → finalize: latch zone, fire callback, reset
```

Tunables live at the top of `core/fsm.lua`. Per-frame budget is O(1) state checks plus at most one quest scan + actor scan; the auto-fire detection check is throttled to 2 Hz when idle.

## Troubleshooting

**The plugin never auto-fires in town.**
Open `Debug logging`, enter Skov_Temis with 10/10 favor, and watch the console. The autofire gate requires (in order): `enabled`, `auto_fire`, in-town zone, no per-zone latch, `ready` (objective text matches), and a Tree NPC visible in the actor stream. The most common miss is a zone the plugin doesn't recognize as a "whisper town" — currently only `Skov_Temis` and `Hawe_TreeOfWhispers` are listed in `core/whispers.lua`.

**The reward panel opens but no card is clicked.**
The `quest_reward` host API may not be exposed on your QQT build. Enable `Use click fallback`, then enable `Show calibration overlay` and dial the four sliders until the crosshairs sit on the leftmost reward card and the Accept button. The sliders are in per-mille (1000 = full screen), so they're resolution-independent.

**It TPs to Temis but doesn't claim.**
Most likely the bounty NPC isn't where the plugin expects, or its skin name doesn't match the patterns in `TREE_NPC_PATTERNS` (in `core/whispers.lua`). Run with debug logging and watch for the "NPC not yet in stream" message — if it persists for more than a few seconds, the actor isn't in the live ally stream (or its skin name has changed). Capture the live skin via your debug tools and add it to the pattern list.

**Failed runs keep firing the autofire loop.**
Shouldn't happen — the plugin latches the zone on both success *and* failure for exactly this reason. If you see it, check that `tracker.last_zone_handled` is being set (debug log on success, `[SilentRaven] run finished: failed` on failure).

## Roadmap

This is v0.1 — first release, untested live. Likely follow-ups after testing:

- Validate Skov_Temis waypoint SNO (`0x1CE51E`) still works on current season.
- Confirm the right `Reward card index` for the user's preferred slot. **Live S09 enumerate() output:** count=4, all gear caches: `[1] Helms`, `[2] Legs`, `[3] Rings`, `[4] Rings` (the duplicate at index 4 is a host-side quirk, not a SilentRaven bug).
- Verify the `quest_reward.pick_and_accept` API path actually claims (vs. the click fallback being needed).
- Add Hawe_TreeOfWhispers TP target as an option (currently TP-only-to-Temis).
- Optionally honor a "safe-to-interrupt" gate similar to WarMachine's `alfred_bridge.lua` so callers don't have to wrap every trigger in their own gate.

## License

Not specified yet. Contact `magoogle` if you want to use or distribute.
