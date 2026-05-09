# Changelog

All notable changes to SilentRaven will be documented in this file. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1] — 2026-05-09

First public release. Live-validated on Skov_Temis (D4 S09).

### Added
- **Standalone Tree-of-Whispers turn-in plugin** for the QQT Lua host (Diablo 4). Two trigger paths:
  - **Auto-fire** when the player is in `Skov_Temis` or `Hawe_TreeOfWhispers` with 10/10 Grim Favor and the master toggle is on.
  - **Call-driven** via the `SilentRavenPlugin` global (Alfred-shaped contract): `trigger_tasks(caller, callback)`, `trigger_tasks_with_teleport(caller, callback)`, `pause`/`resume`, `cancel`, `get_status`, `is_available`, `check_version`. Mirrors `AlfredTheButlerPlugin` so other scripts can interrupt themselves to claim a turn-in.
- **TP-to-Skov_Temis** waypoint SNO `0x1CE51E` (lifted from `AlfredTheButler/core/town.lua`) when `trigger_tasks_with_teleport` is called from out of town.
- **Static-coord pathing in Skov_Temis.** After TP arrival the bounty Raven NPC is ~16 yards away and out of the live ally stream's range. SilentRaven walks blindly via a randomized intermediate waypoint at `(2597.24, -488.08, 30.52)` then to the NPC at `(2596.38, -495.79, 30.52)` — bringing the actor into stream so the normal interact + claim flow runs. Per-attempt randomization (±2y) avoids same-spot pathing.
- **Priority-based reward picking** (`core/rewards.lua`):
  - 12 slot ids: `helms`, `chest`, `legs`, `gloves`, `boots`, `rings`, `amulets`, `weapons_1h`, `weapons_2h`, `gold`, `chaos`, `other`. Each gets a 0–10 GUI slider, all default 5.
  - `Prefer legendary` toggle + `Legendary bonus weight` slider (default 50). Legendary cards score `slot_priority + bonus_weight` so they beat any non-legendary at the same slot priority. Legendary still wins even when its slot is set to 0.
  - First-valid fallback: if every entry scores 0 (all slots set to 0 AND nothing legendary on offer), the picker grabs the first valid entry rather than refusing to claim.
- **Cloud-synced cache catalog** (`Updater.bat` + `https://looter.d4data.live/d4/silentraven/caches.lua`):
  - Three-tier loader: cloud-synced `data/caches.lua` → embedded fallback (21 entries) → `internal_name` pattern parsing as last resort.
  - Server pipeline (`silentraven_export.py` running in `looter-d4share` container) regenerates the catalog daily from the master LooteerV3 catalog. Currently 75 entries spanning regular + Greater + Ancestral tiers + Whisper Cache material variants. 33 (44%) flagged legendary.
  - GUI header shows the catalog source (`cloud` vs `embedded fallback`) and last-sync age.
  - **Reload Catalog (cloud)** GUI checkbox: tick fires `Updater.bat oneshot`, reloads `data.caches` in-process, then auto-clears the box. Debounced 2s.
- **D4Remote dashboard integration** (`update_stats` + `record_loot`):
  - `core/stats.lua` keeps cumulative counters (`turnins_success`, `turnins_failed`, `tp_attempts`, `legendary_claimed`, `regular_claimed`, per-slot `<slot>_claimed`, last-pick details). Resets on script reload, same pattern as Alfred / GoFish.
  - `report_to_d4remote()` pushes a flat ~30-key payload (live state + catalog freshness + cumulative counters + per-slot breakdown + last-pick details) every 1 Hz. Reporting runs even when the plugin is disabled so the dashboard card stays visible with `status="Disabled"`.
  - `D4Remote.record_loot(category, rarity)` fires once per successful claim. SilentRaven slots translate to D4Remote's singular vocab via `SLOT_TO_D4REMOTE_CATEGORY` (`rings → ring`, `weapons_1h/2h → weapon`, etc.). Rarity is `5 (Legendary)` for legendary picks, `4 (Rare)` otherwise.
- **`SilentRavenPlugin` + `PLUGIN_silent_raven`** globals — the Alfred-style entry points for caller scripts.
- **Per-zone success/failure latch** so a finished run doesn't busy-loop the autofire gate; cleared on zone change.
- **Console output** prefixed `[SilentRaven]`. Debug logging GUI toggle gates the per-state-transition tracing in the FSM.

### Performance / safety
- **API-only reward selection.** Uses `quest_reward.pick_and_accept(idx)` exclusively. No pixel-click fallback — if the host doesn't expose the API, the run fails fast with a clear error rather than chasing screen coordinates.
- **`pathfinder.request_move` for movement** (the per-frame friendly variant matching WarMachine's nav). `pathfinder.clear_stored_path()` is called on disable / cancel / FSM finalize so the bot actually stops instead of drifting to its last requested goal.
- **All hot-path work is O(1) per frame.** The auto-fire ready-check (quest scan + actor scan) is throttled to 2 Hz when idle. D4Remote reporting is throttled to 1 Hz. `os.execute` is only invoked from the user-triggered `Reload Catalog` checkbox.
- **`quest_reward.enumerate()` 1-indexing** confirmed live (the API stub doesn't specify); `pick_and_accept(0)` would silently fail.

### Server side
- New private repo [magoogle/looter-d4share](https://github.com/magoogle/looter-d4share) holds the FastAPI service that backs `https://looter.d4data.live`. The SilentRaven additions (`silentraven_export.py`, the patches to `pipeline.py` and `api.py`) are committed there alongside the existing Alfred / LooteerV3 publishing surfaces.
- New endpoint `GET /d4/silentraven/{filename}` mirrors the `/d4/alfred/{filename}` pattern — path-traversal-guarded `FileResponse`, `text/plain` for Lua source.

### Known limitations
- Static-coord pathing currently only covers `Skov_Temis`. In `Hawe_TreeOfWhispers` the bot will only autofire if the NPC is already in the live actor stream.
- Counters are in-memory; a script reload zeroes them.
- The `Dump reward options` keybind + button were commented out for normal play after the new-season classification was confirmed working — re-enable in `gui.lua` + `main.lua` (three call-sites, all marked) when investigating future-season SNOs.
