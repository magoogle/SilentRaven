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
-- AlfredTheButler/core/town.lua).  The reward selection prefers the
-- host's quest_reward.pick_and_accept API; falls back to fractional
-- pixel clicks calibrated via GUI sliders.
-- ---------------------------------------------------------------------------

local gui      = require 'gui'
local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local whispers = require 'core.whispers'
local fsm      = require 'core.fsm'
local external = require 'core.external'
local log      = require 'core.log'

-- Auto-fire detection rate.  Quest scan + actor scan are O(n) over the
-- live stream; cheap but not free, and we don't need higher resolution
-- than ~2 Hz for "is a turn-in ready".  See feedback_lua_perf.md.
local READY_CHECK_INTERVAL_S = 0.5

-- Manual-trigger keybind debounce (mirrors Alfred's 1s timeout).
local MANUAL_DEBOUNCE_S      = 1.0
local last_manual_t          = -math.huge
local last_dump_t            = -math.huge

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

-- Fires on either the keybind or the GUI button.  Intentionally NOT
-- gated by settings.enabled -- this is a debug aid; the user should be
-- able to dump reward options before they ever enable the plugin to
-- pick the right Reward card index.
local function handle_dump_input(now)
    local keybind_pressed = gui.elements.dump_rewards_keybind:get_state() == 1
    local button_pressed  = gui.elements.dump_rewards_button:get() == true
    if not (keybind_pressed or button_pressed) then return end
    if (now - last_dump_t) < MANUAL_DEBOUNCE_S then return end
    last_dump_t = now
    if keybind_pressed then gui.elements.dump_rewards_keybind:set(false) end
    log.info('--- reward dump (' .. (keybind_pressed and 'keybind' or 'button') .. ') ---')
    whispers.dump_rewards()
    log.info('--- end dump ---')
end

local function main_pulse()
    settings.update(gui)
    local now = (get_time_since_inject and get_time_since_inject()) or 0

    -- Debug input first: dump-rewards is intentionally NOT gated by
    -- settings.enabled so the user can use it for calibration before
    -- ever enabling the plugin.
    handle_dump_input(now)

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

local function draw_calibration()
    if not graphics or not graphics.line then return end
    if not get_screen_width or not get_screen_height then return end
    local sw, sh = get_screen_width(), get_screen_height()
    local pts = {
        { x = sw * settings.reward_x_frac, y = sh * settings.reward_y_frac, label = 'reward' },
        { x = sw * settings.accept_x_frac, y = sh * settings.accept_y_frac, label = 'accept' },
    }
    local color = (color_yellow and color_yellow(220)) or nil
    if not color then return end
    for i = 1, #pts do
        local p = pts[i]
        local x, y = math.floor(p.x), math.floor(p.y)
        graphics.line(vec2:new(x - 12, y), vec2:new(x + 12, y), color, 2)
        graphics.line(vec2:new(x, y - 12), vec2:new(x, y + 12), color, 2)
        if graphics.text_2d then
            graphics.text_2d(p.label, vec2:new(x + 14, y - 8), 14, color)
        end
    end
end

local function render_pulse()
    if not settings.enabled then return end
    if settings.show_calibration then
        draw_calibration()
    end
end

on_update(main_pulse)
on_render_menu(function () gui.render() end)
on_render(render_pulse)

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
