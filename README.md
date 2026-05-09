# SilentRaven

**Author:** magoogle
**Version:** v0.1 (untested — first release for live validation)

A standalone Tree-of-Whispers turn-in plugin for the QQT Lua host (Diablo 4). Auto-claims whisper bounty caches whenever the player is in town with 10/10 Grim Favor, and exposes an Alfred-style global plugin so other scripts can interrupt themselves to do a turn-in.

## What it does

- Detects when the bounty meta-quest objective flips to "Return to the Tree of Whispers..." (10/10 Grim Favor).
- Walks to the nearest Tree / Crow / Bounty Raven NPC in the live actor stream.
- Re-fires `interact_object` on a 1.5 s cadence until the reward panel verifies open.
- Claims via `quest_reward.pick_and_accept(idx)` (host API). The index comes from the priority ranker — see "Priority pick" below. No pixel-click fallback: if the API isn't exposed by the host, the run fails fast with a clear error.
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
3. Open the QQT menu, find the **`SilentRaven v0.1 by magoogle`** tree.
4. (Optional but recommended) Click **Reload Catalog (cloud)** to pull the latest cache classifications from `https://looter.d4data.live/d4/silentraven/caches.lua`. The repo ships a pre-built `data/caches.lua` so this works out of the box, but a season patch can add new SNOs the shipped file doesn't know about.
5. Toggle **Enable**.

Console output is the primary observability channel. Turn on `Debug logging` to see FSM transitions while calibrating.

## Cache catalog

SilentRaven classifies every offered turn-in card by **slot** (helms, rings, gold, ...) and **legendary** flag. The classifier looks up the entry's SNO in a catalog that has three sources, in order of preference:

1. **Cloud-synced** (`data/caches.lua`) — pulled from `https://looter.d4data.live/d4/silentraven/caches.lua` by `Updater.bat`. The looter pipeline regenerates this file daily from the master LooteerV3 item catalog (currently 75 entries spanning regular + Greater + Ancestral tiers + Whisper Cache material variants). This is the recommended path.
2. **Embedded fallback** (`core/rewards.lua` `EMBEDDED_CATALOG`) — 21 entries covering the most common BountyMetaCache + Whisper Cache families. Used when `data/caches.lua` is missing or malformed. Means the plugin still classifies correctly day-one without ever talking to the cloud.
3. **internal_name pattern parsing** (last resort, for SNOs no source has yet) — strips known prefixes/suffixes and looks for slot keywords and legendary tokens (`legendary`, `ancestral`, `guaranteed`, `upgraded`, ...).

The GUI header shows which source loaded and the last cloud-sync age. **Reload Catalog (cloud)** runs `Updater.bat` synchronously (a brief ~50–200ms cmd.exe spawn freeze) then re-loads the file; safe as a one-shot user action, debounced to 2s to prevent rapid-click pile-up.

`Updater.bat` also supports `loop` mode (`Updater.bat loop` from a shell) for a 15-minute background sync if you want the catalog to track new-season SNOs without ever touching the GUI.

## GUI options

| Option | Purpose |
|---|---|
| **Enable** | Master toggle. Disables all auto-fire and ignores external triggers when off. |
| **Auto-fire in town** | When enabled, claims turn-ins automatically while in `Skov_Temis` / `Hawe_TreeOfWhispers`. Disable to make the plugin strictly call-driven. |
| **Debug logging** | Print FSM transitions to console. |
| **Manual trigger keybind** | Press to fire a turn-in run now (TP-to-Temis included). |
| **Prefer legendary** | When ON, legendary-detected cards get the bonus weight added so they outrank same-slot non-legendary entries. Detection comes from the cloud catalog (Greater / Ancestral / Material variants flagged legendary) with internal_name pattern matching as fallback. |
| **Legendary bonus weight (0-100)** | Score boost added to legendary cards. High (e.g. 100) makes any legendary outrank any non-legendary regardless of slot. Low (e.g. 5) only breaks ties. |
| **Slot priorities (Helms / Chest / Legs / ...)** | 0–10 weight per slot. All default 5. Lower a slot to deprioritize it; raise to prefer it. If every slot is set to 0 AND no legendaries are on offer, `pick_best_index` falls back to the first valid entry rather than refusing to claim. |

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
  ├── quest_reward API missing      → fail_or_retry
  ├── pick_best_index returns nil   → fail_or_retry
  ├── quest_reward.pick_and_accept(idx) ok → API_CLAIMING
  └── pick_and_accept returned false → fail_or_retry

API_CLAIMING
  ├── is_bounty_quest_present() == false → DONE
  └── timeout (CLAIM_VERIFY_TIMEOUT_S) → WAIT_RETRY (or FAILED)

DONE / FAILED → finalize: latch zone, fire callback, reset
```

Tunables live at the top of `core/fsm.lua`. Per-frame budget is O(1) state checks plus at most one quest scan + actor scan; the auto-fire detection check is throttled to 2 Hz when idle.

## Troubleshooting

**The plugin never auto-fires in town.**
Open `Debug logging`, enter Skov_Temis with 10/10 favor, and watch the console. The autofire gate requires (in order): `enabled`, `auto_fire`, in-town zone, no per-zone latch, `ready` (objective text matches), and a Tree NPC visible in the actor stream. The most common miss is a zone the plugin doesn't recognize as a "whisper town" — currently only `Skov_Temis` and `Hawe_TreeOfWhispers` are listed in `core/whispers.lua`.

**The reward panel opens but no card is claimed.**
The `quest_reward` host API isn't exposed by your QQT build. With debug logging on you'll see `pick_index: quest_reward.enumerate unavailable on this host` followed by retries failing. SilentRaven no longer ships a pixel-click fallback — the only path is the API. Update your QQT build to one that exposes `quest_reward.{is_open,enumerate,pick_and_accept}` (see `#api/quest_reward.lua` in the source tree).

**It TPs to Temis but doesn't claim.**
Most likely the bounty NPC isn't where the plugin expects, or its skin name doesn't match the patterns in `TREE_NPC_PATTERNS` (in `core/whispers.lua`). Run with debug logging and watch for the "NPC not yet in stream" message — if it persists for more than a few seconds, the actor isn't in the live ally stream (or its skin name has changed). Capture the live skin via your debug tools and add it to the pattern list.

**Failed runs keep firing the autofire loop.**
Shouldn't happen — the plugin latches the zone on both success *and* failure for exactly this reason. If you see it, check that `tracker.last_zone_handled` is being set (debug log on success, `[SilentRaven] run finished: failed` on failure).

## Roadmap

This is v0.1 — first release, untested live. Likely follow-ups after testing:

- Validate Skov_Temis waypoint SNO (`0x1CE51E`) still works on current season.
- Verify the `quest_reward.pick_and_accept` API path actually claims live.
- Add Hawe_TreeOfWhispers TP target as an option (currently TP-only-to-Temis).
- Optionally honor a "safe-to-interrupt" gate similar to WarMachine's `alfred_bridge.lua` so callers don't have to wrap every trigger in their own gate.

## License

Not specified yet. Contact `magoogle` if you want to use or distribute.
