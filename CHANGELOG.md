# Changelog

All notable changes to SilentRaven will be documented in this file. Format loosely follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [Unreleased]

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
