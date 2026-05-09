-- ---------------------------------------------------------------------------
-- SilentRaven  --  magoogle  --  v0.1
--
-- Standalone Tree-of-Whispers turn-in plugin.  Two trigger paths:
--
--   1) AUTO-FIRE: when settings.enabled and settings.auto_fire are both
--      on AND the player is standing in Skov_Temis or Hawe_TreeOfWhispers
--      with a ready bounty (10/10 Grim Favor), the FSM kicks off without
--      any external prompt.
--
--   2) CALL-DRIVEN: other scripts call into the global SilentRavenPlugin
--      to interrupt themselves and claim a turn-in.  Mirrors Alfred:
--          SilentRavenPlugin.trigger_tasks_with_teleport(caller, callback)
--          SilentRavenPlugin.trigger_tasks(caller, callback)        -- no TP
--          SilentRavenPlugin.get_status()                           -- poll
--          SilentRavenPlugin.pause(caller) / .resume()
--      Callers should poll get_status().running and yield while true.
--
-- The TP target is the Skov_Temis waypoint (SNO 0x1CE51E -- pulled from
-- AlfredTheButler/core/town.lua).  Reward selection is API-only via
-- quest_reward.pick_and_accept(idx) where idx comes from the priority
-- ranker in core/rewards.lua.  No pixel-click fallback: if the host
-- doesn't expose the API, the run fails fast with a clear error.
-- ---------------------------------------------------------------------------

local gui      = require 'gui'
local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local whispers = require 'core.whispers'
local fsm      = require 'core.fsm'
local external = require 'core.external'
local log      = require 'core.log'
local rewards  = require 'core.rewards'
local stats    = require 'core.stats'

-- Auto-fire detection rate.  Quest scan + actor scan are O(n) over the
-- live stream; cheap but not free, and we don't need higher resolution
-- than ~2 Hz for "is a turn-in ready".  See feedback_lua_perf.md.
local READY_CHECK_INTERVAL_S = 0.5

-- Manual-trigger keybind debounce (mirrors Alfred's 1s timeout).
local MANUAL_DEBOUNCE_S      = 1.0
local last_manual_t          = -math.huge
-- local last_dump_t          = -math.huge   -- (re-enable with handle_dump_input)
local last_reload_t          = -math.huge

-- Reload Catalog has its own debounce -- spawning cmd.exe back to back
-- can pile up child processes if the checkbox is rapidly re-armed.
-- 2s is plenty: a one-shot fetch + reload is well under that on success.
local RELOAD_DEBOUNCE_S      = 2.0

-- Edge-trigger memory for the Reload Catalog checkbox.  We only fire
-- on a false->true transition (one fire per click), then auto-clear
-- the box.  Mirrors LooteerV3's reload_catalog_toggle pattern.
local _last_reload_state     = false

-- D4Remote.update_stats throttle.  D4Remote internally writes its
-- state file every 3 seconds, so anything faster than ~1 Hz here is
-- wasted work.  Keep it cheap on the game thread.
local D4REMOTE_REPORT_INTERVAL_S = 1.0
local last_d4remote_report_t     = 0

local function refresh_ready(now)
    if (now - (tracker.last_ready_check_t or 0)) < READY_CHECK_INTERVAL_S then return end
    tracker.last_ready_check_t = now
    tracker.ready = whispers.count_ready_bounties() > 0
end

local function maybe_consume_external_trigger(now)
    if not tracker.external_trigger then return end
    if tracker.paused then return end
    if tracker.running then return end
    -- Honor the per-zone latch only when no TP was requested -- if a
    -- caller explicitly asked us to go, they probably know better than
    -- our autofire latch.
    local cur_zone = whispers.current_zone()
    local with_tp  = tracker.teleport_required
    if (not with_tp) and tracker.last_zone_handled == cur_zone then
        log.info('external trigger ignored: already turned in this visit')
        local cb = tracker.external_callback
        tracker.reset_run()
        if cb then pcall(cb, 'skipped_latched') end
        return
    end
    local reason = with_tp and 'external+tp' or 'external'
    if tracker.external_caller then
        reason = reason .. ':' .. tostring(tracker.external_caller)
    end
    fsm.start(settings, reason, with_tp, tracker.external_callback)
    -- fsm.start consumed the callback; clear the trigger flag
    tracker.external_trigger  = false
    tracker.teleport_required = false
end

local function maybe_autofire(now, cur_zone)
    if not settings.auto_fire then return end
    if tracker.running or tracker.paused then return end
    if not whispers.in_whisper_town() then return end
    if tracker.last_zone_handled == cur_zone then return end
    if not tracker.ready then return end
    -- Don't autofire unless we can actually see the NPC; otherwise we'd
    -- spin in WALK_NPC retries on a freshly-loaded zone with no bounty
    -- NPC at all (e.g. a town variant that doesn't host the Tree).
    if not whispers.find_tree_npc() then return end
    fsm.start(settings, 'auto', false, nil)
end

local function handle_manual_keybind(now)
    if gui.elements.manual_fire_keybind:get_state() ~= 1 then return end
    if (now - last_manual_t) < MANUAL_DEBOUNCE_S then return end
    last_manual_t = now
    gui.elements.manual_fire_keybind:set(false)
    if tracker.running then
        log.info('manual trigger ignored: already running')
        return
    end
    log.info('manual trigger fired')
    fsm.start(settings, 'manual', true, nil)
end

-- Dump reward options handler -- commented out for normal play.  See
-- the corresponding GUI element / renderer comments in gui.lua to
-- re-enable.  Logic kept here verbatim so a one-comment-block flip
-- restores the feature.
-- local function handle_dump_input(now)
--     local keybind_pressed = gui.elements.dump_rewards_keybind:get_state() == 1
--     local button_pressed  = gui.elements.dump_rewards_button:get() == true
--     if not (keybind_pressed or button_pressed) then return end
--     if (now - last_dump_t) < MANUAL_DEBOUNCE_S then return end
--     last_dump_t = now
--     if keybind_pressed then gui.elements.dump_rewards_keybind:set(false) end
--     log.info('--- reward dump (' .. (keybind_pressed and 'keybind' or 'button') .. ') ---')
--     whispers.dump_rewards()
--     log.info('--- end dump ---')
-- end

-- Build a flat key/value status payload for D4Remote.  Values must
-- all be bool/number/string per D4Remote's INTEGRATION.md (no nested
-- tables -- that's why core/stats.lua flattens per-slot counters).
local function build_d4remote_payload()
    local cur_zone = whispers.current_zone() or ''
    local catalog_size = 0
    if rewards.CACHE_CATALOG then
        for _ in pairs(rewards.CACHE_CATALOG) do
            catalog_size = catalog_size + 1
        end
    end

    local status
    if not settings.enabled then
        status = 'Disabled'
    elseif tracker.running then
        status = 'Running: ' .. (tracker.state or 'STARTING')
    elseif tracker.paused then
        status = 'Paused'
    elseif whispers.in_whisper_town() then
        if tracker.ready then
            if tracker.last_zone_handled == cur_zone then
                status = 'Idle in town (latched)'
            else
                status = 'Ready -- bounty queued'
            end
        else
            status = 'Idle in town'
        end
    else
        status = 'Idle (zone=' .. cur_zone .. ')'
    end

    return {
        -- Live state (the `enabled` key drives the dashboard ON/OFF badge)
        enabled              = settings.enabled == true,
        status               = status,
        running              = tracker.running == true,
        state                = tostring(tracker.state or 'IDLE'),
        current_zone         = cur_zone,
        auto_fire            = settings.auto_fire == true,
        prefer_legendary     = settings.prefer_legendary == true,
        legendary_bonus      = settings.legendary_bonus_weight or 0,
        ready                = tracker.ready == true,
        attempts             = tracker.attempts or 0,

        -- Catalog
        catalog_source       = rewards.CATALOG_SOURCE or 'unknown',
        catalog_age          = (rewards.last_sync_str and rewards.last_sync_str()) or 'unknown',
        catalog_entries      = catalog_size,

        -- Cumulative counters
        turnins_total        = stats.turnins_success + stats.turnins_failed,
        turnins_success      = stats.turnins_success,
        turnins_failed       = stats.turnins_failed,
        tp_attempts          = stats.tp_attempts,
        legendary_claimed    = stats.legendary_claimed,
        regular_claimed      = stats.regular_claimed,

        -- Per-slot breakdown (flat keys; D4Remote forbids nested tables)
        helms_claimed        = stats.helms_claimed,
        chest_claimed        = stats.chest_claimed,
        legs_claimed         = stats.legs_claimed,
        gloves_claimed       = stats.gloves_claimed,
        boots_claimed        = stats.boots_claimed,
        rings_claimed        = stats.rings_claimed,
        amulets_claimed      = stats.amulets_claimed,
        weapons_1h_claimed   = stats.weapons_1h_claimed,
        weapons_2h_claimed   = stats.weapons_2h_claimed,
        gold_claimed         = stats.gold_claimed,
        chaos_claimed        = stats.chaos_claimed,
        other_claimed        = stats.other_claimed,

        -- Last claim
        last_pick_name       = stats.last_pick_name,
        last_pick_slot       = stats.last_pick_slot,
        last_pick_legendary  = stats.last_pick_legendary == true,
        last_reason          = stats.last_reason,
        last_result          = stats.last_result,
    }
end

-- Push stats to the D4Remote dashboard.  Throttled to 1 Hz on the
-- game thread; D4Remote itself buffers writes to ~3s on the disk
-- side, so anything faster is wasted work.
local function report_to_d4remote(now)
    if not (D4Remote and D4Remote.update_stats) then return end
    if (now - last_d4remote_report_t) < D4REMOTE_REPORT_INTERVAL_S then return end
    last_d4remote_report_t = now
    pcall(function () D4Remote.update_stats('SilentRaven', build_d4remote_payload()) end)
end

-- Reload Catalog checkbox.  Edge-triggered: fires once on a
-- false->true transition, then auto-clears the box so it visually
-- "disarms" itself.  Debounced + intentionally NOT gated by
-- settings.enabled -- the catalog is needed for proper classification
-- before you'd even consider enabling the plugin.
local function handle_reload_catalog(now)
    local cur = gui.elements.reload_catalog_toggle:get()
    if cur and not _last_reload_state then
        if (now - last_reload_t) < RELOAD_DEBOUNCE_S then
            -- Still in debounce window from a prior click; quietly
            -- disarm the box and ignore.
            pcall(function () gui.elements.reload_catalog_toggle:set(false) end)
            _last_reload_state = false
            return
        end
        last_reload_t = now
        log.info('Reload Catalog: spawning Updater.bat oneshot...')
        local ok, source_or_err = rewards.fetch_and_reload()
        if ok then
            log.info('Reload Catalog: ok (source=' .. tostring(source_or_err) .. ')')
        else
            log.info('Reload Catalog: FAILED (' .. tostring(source_or_err) .. ')')
        end
        pcall(function () gui.elements.reload_catalog_toggle:set(false) end)
    end
    _last_reload_state = gui.elements.reload_catalog_toggle:get()
end

local function main_pulse()
    settings.update(gui)
    local now = (get_time_since_inject and get_time_since_inject()) or 0

    -- Setup input first: reload-catalog is intentionally NOT gated by
    -- settings.enabled so the user can fetch the catalog before ever
    -- enabling the plugin.  (handle_dump_input is commented out --
    -- re-enable alongside the GUI elements when needed.)
    -- handle_dump_input(now)
    handle_reload_catalog(now)

    -- D4Remote dashboard: push stats every pulse (throttled to 1 Hz
    -- inside report_to_d4remote).  Done BEFORE the enabled gate so the
    -- card stays visible (with status="Disabled") even when the user
    -- has the plugin off.
    report_to_d4remote(now)

    if not settings.enabled then
        -- Disabled: drop any in-flight run cleanly so we don't leave
        -- callbacks orphaned across an enable/disable toggle.
        if tracker.running then
            local cb = tracker.external_callback
            log.info('disabled mid-run -- aborting')
            tracker.reset_run()
            if cb then pcall(cb, 'disabled') end
        end
        return
    end

    handle_manual_keybind(now)

    -- If a run is in flight, just tick the FSM.  Don't refresh "ready"
    -- (already running -- no point) and don't start anything new.
    if tracker.running then
        fsm.tick(settings)
        return
    end

    refresh_ready(now)
    local cur_zone = whispers.current_zone()
    maybe_consume_external_trigger(now)
    if not tracker.running then
        maybe_autofire(now, cur_zone)
    end
    if tracker.running then
        fsm.tick(settings)
    end
end

on_update(main_pulse)
on_render_menu(function () gui.render() end)

-- Expose the plugin globally.  PLUGIN_silent_raven matches Alfred's
-- legacy convention; SilentRavenPlugin is the modern name and what
-- callers should prefer.
PLUGIN_silent_raven = external
SilentRavenPlugin   = external

-- Register with D4Remote dashboard if present (best-effort, non-blocking).
if D4Remote and D4Remote.register then
    pcall(function () D4Remote.register('SilentRaven', '0.1') end)
end

log.info('loaded magoogle | SilentRaven | v0.1')
