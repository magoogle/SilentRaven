# Changelog

All notable changes to SilentRaven will be documented in this file. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.2] — 2026-05-09

The actual fix for the two bugs that v0.1.1 misdiagnosed.

### Fixed
- **Off-by-one in `pick_and_accept` / `select`.** A user-supplied screenshot of the live reward UI proved that both `Material Collection of Keys` and `Greater Collection of Two-Handed Weapons` are colored **orange (legendary)** in D4 — meaning the original "non-legendary was selected" complaint was about the picker getting the wrong card *visually*, not a wrong rarity classification. Both reports had `pick_and_accept(3)` ostensibly succeed but the user got the entry at `enumerate()[4]`. Conclusion: on this host, **`enumerate()` keys are 1-indexed but `pick_and_accept(N)` and `select(N)` are 0-indexed.** Two related host functions, two different conventions, neither documented in the API stub. SilentRaven now subtracts 1 before calling `select` / `pick_and_accept` and verifies post-`select` by reading `selected_index()` and comparing the SNO at the selected position to the SNO we intended.

### Changed (revert from v0.1.1)
- **Material Collection of *** caches restored to `legendary=true`. The v0.1.1 reclassification was based on a wrong diagnosis — those caches genuinely show as legendary (orange) in D4's UI. The `slot=materials` separation introduced in v0.1.1 is kept (so users can still independently weight materials vs gear via the slider), but rarity now matches D4's display tier.

## [0.1.1] — 2026-05-09

Bugfix release based on two live user reports:

### Fixed
- **`Material Collection of *` caches no longer treated as legendary gear.** A user with `legendary_bonus_weight=100` reported the picker grabbed `Material Collection of Gem Fragments` over a regular `Collection of Helms`. Root cause: the LooteerV3 catalog has these at `magic_type=3` (legendary *cache rarity tier*), which the classifier read as "drops legendary gear" — they're crafting-material caches. New `materials` slot covers Gem Fragments / Salvage / Keys / Primordial Dust with `legendary=false` so they don't trigger the legendary bonus. `Material Collection of Gold` stays at `slot=gold legendary=true` (gold is genuinely high-value). Added a `Materials` priority slider in the GUI defaulting to 3 (lower than the gear default of 5). Server-side fix in `silentraven_export.py` regenerated `caches.lua` with the new classification (4 entries flipped); client fallback catalog mirrors it.
- **Two-step claim with verification telemetry.** Another user reported the bot called `pick_and_accept(3)` ("Greater Two-Handed Weapons") but actually got Gauntlets (the entry at index 4). Couldn't conclusively prove host indexing mismatch from the log alone, so `fire_claim` now uses the granular `select(idx)` → `selected_index()` → `accept()` path when the host exposes it. Logs a `WARNING:` line if `selected_index()` doesn't match the requested index, and a separate warning if the SNO at the post-select position doesn't match the SNO we intended. This will give us ground truth on the next occurrence. Falls back to single-call `pick_and_accept` when the granular API isn't available.

### Added
- New `materials` slot covering 4 Whisper Cache Material entries (Gem Fragments / Salvage / Keys / Primordial Dust). Maps to `material` in the D4Remote loot category vocabulary; `materials_claimed` counter exposed in the dashboard payload.

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
