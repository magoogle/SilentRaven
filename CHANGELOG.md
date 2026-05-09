# Changelog

All notable changes to SilentRaven will be documented in this file. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

### Added (live-validated against second S09 dump)
- **Catalog now ships 21 BountyMetaCache + Whisper Cache SNOs** with explicit `legendary` flags. Live dump from the user (panel open, count=4) showed:
  - `[1] sno=2102725 BountyMeta_Cache_Gold_Upgraded` → was legendary; now classified as `slot=gold legendary=true (catalog:legendary=true)`
  - `[2] sno=598510  BountyMeta_Cache_Chaos`         → now classified as `slot=chaos legendary=false`
  - `[3] sno=1087557 BountyMeta_Cache_2HWeapons`     → now classified as `slot=weapons_2h` (was already correct via SNO)
  - `[4] sno=1087555 BountyMeta_Cache_Gloves`        → unchanged
- New `gold` and `chaos` slots in `KNOWN_SLOTS` with priority sliders (gold defaults to 7 since it's universally useful; chaos defaults to 5).
- `_Upgraded` added to `LEGENDARY_NAME_TOKENS` for fallback name detection on cache SNOs not yet in the embedded catalog.
- Catalog lookup is now the **first** rung of `is_legendary` — short-circuits with evidence `catalog:legendary=true|false` when the SNO is known. Heuristic field/name probes only fire for unknown SNOs.

### Notes
- The host's live entry table only carries `{sno, internal_name, valid}` — no rarity/quality/tier extras (verified by the empty `extras:` line in the dump). Catalog-by-SNO is the only reliable legendary signal until that changes; embedded mini-catalog is the fallback.

### Added
- **Priority-based reward picking.** New `core/rewards.lua` module: SNO-catalog slot mapping (lifted from LooteerV3 v20260509 — 9 known BountyMetaCache SNOs covering Helms / Chest / Legs / Gloves / Boots / Rings / Amulets / 1H Weapons / 2H Weapons), `internal_name` pattern fallback for unknown caches, multi-field legendary detection (probes `legendary`/`is_legendary`/`is_unique`/`guaranteed_legendary`/`is_ancestral`/`rarity`/`quality`/`tier`/`class`/`rank`/`r` then falls back to name-pattern matching).
- "Auto-pick by priority" GUI toggle plus per-slot priority sliders (0..10 each) and a "Prefer legendary" toggle with adjustable bonus weight (0..100). When auto-pick is on, the FSM scores every live `enumerate()` entry and claims the winner; ties resolve to the lowest index. Falls back to the fixed `Reward card index` when scoring returns no winner (e.g. all slots set to 0).
- "Dump reward options" GUI keybind AND button. Press/click while the reward panel is open to print every `quest_reward.enumerate()` entry to console. Works even when the plugin is disabled (debug aid). The button is the more reliable surface — no key binding required.
- **Enhanced dump output.** Every entry now prints (a) the documented `sno / internal_name / valid` triple, (b) the parsed `slot`, (c) the legendary verdict + the evidence token explaining the decision (`field:rarity=legendary`, `name:ancestral`, etc.), and (d) every extra field on the entry — so any rarity / quality / tier field the host exposes that the API stub doesn't document will surface and we can wire it into `is_legendary`.
- `core/whispers.lua` exposes `M.dump_rewards()` for the same purpose; safe to call any time, gracefully degrades when the host doesn't expose `quest_reward`.

### Changed
- **`Reward card index` is now 1-based, range 1-5.** First push had it 0-based with default 0, but `quest_reward.enumerate()` on this host returns 1-INDEXED keys — verified live S09 with count=4, keys [1..4], cards: `[1] BountyMeta_Cache_Helms`, `[2] BountyMeta_Cache_Legs`, `[3] BountyMeta_Cache_Rings`, `[4] BountyMeta_Cache_Rings`. The 0-based default would have silently failed `pick_and_accept(0)` and looped into FAILED retries.

### Fixed
- Dump-rewards keybind no longer requires the plugin to be enabled — moved ahead of the `settings.enabled` early-return in `main_pulse` so it works as a calibration aid before first enable.

## [0.1] — 2026-05-09

First release. **Untested live** — published for in-game validation.

### Added
- Standalone Tree-of-Whispers turn-in plugin for the QQT Lua host (Diablo 4).
- Auto-fire path: detects 10/10 Grim Favor and claims automatically while the player is in `Skov_Temis` or `Hawe_TreeOfWhispers`.
- Call-driven path: `SilentRavenPlugin` global with Alfred-shaped contract — `trigger_tasks`, `trigger_tasks_with_teleport`, `pause`, `resume`, `cancel`, `get_status`, `is_available`, `check_version`.
- TP-to-town stage when called via `trigger_tasks_with_teleport` (Skov_Temis waypoint SNO `0x1CE51E`).
- Reward selection via `quest_reward.pick_and_accept(reward_index)` (host API). Two-click pixel fallback for hosts without the API, with calibration overlay (`Show calibration overlay` GUI toggle) and four per-mille click sliders.
- Per-zone latch so a finished run (success or failure) doesn't re-fire until the player leaves and re-enters the zone.
- GUI tree branded `magoogle | SilentRaven | v0.1` with master enable, auto-fire toggle, debug logging, manual-trigger keybind, reward card index, and click-fallback calibration.
- Console output via `[SilentRaven]` prefix; debug logging gated by GUI toggle.

### Notes for first live test
- The Skov_Temis waypoint SNO is sourced from `AlfredTheButler/core/town.lua`. Smoke-test once with `teleport_to_waypoint(0x1CE51E)` to confirm.
- The NPC skin patterns in `core/whispers.lua` (`temis_bounty_meta_raven_npc`, etc.) are season-specific. Verify the live skin still matches; the pattern list is generic enough to cover most renaming, but Blizzard occasionally restructures.
- Reward card order (gold / materials / gear) varies by season. Default `Reward card index = 0` picks leftmost; tweak in GUI to taste.
