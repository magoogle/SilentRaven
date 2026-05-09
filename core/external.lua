-- core/external.lua  --  public API exposed via SilentRavenPlugin global.
--
-- Mirrors AlfredTheButlerPlugin's contract so callers can use the same
-- pattern (poll get_status; trigger_tasks_with_teleport(caller, callback);
-- yield while running).

local log      = require 'core.log'
local settings = require 'core.settings'
local tracker  = require 'core.tracker'
local whispers = require 'core.whispers'

local external = {}

external.get_status = function ()
    return {
        name            = settings.plugin_label,
        version         = settings.plugin_version,
        author          = settings.plugin_author,
        enabled         = settings.enabled,
        running         = tracker.running,
        ready           = tracker.ready,
        last_reason     = tracker.last_reason,
        last_result     = tracker.last_result,
        last_result_t   = tracker.last_result_t,
        all_task_done   = tracker.all_task_done,
        state           = tracker.state,
        attempts        = tracker.attempts,
        last_zone_handled  = tracker.last_zone_handled,
        last_observed_zone = tracker.last_observed_zone,
        paused          = tracker.paused,
        paused_by       = tracker.paused_by,
    }
end

-- Plugin enable check.  Same shape as Alfred's; useful for callers that
-- want to know "is this plugin even installed and turned on?" before
-- deciding to wait on it.
external.is_available = function ()
    return settings.enabled == true
end

external.pause = function (caller)
    tracker.paused    = true
    tracker.paused_by = caller
    log.info('paused by ' .. tostring(caller))
end

external.resume = function ()
    tracker.paused    = false
    tracker.paused_by = nil
    log.info('resumed')
end

-- Queue a turn-in.  Assumes the player is already in a whisper town; main
-- will only consume the trigger when in_whisper_town() (or when teleport
-- is requested, in which case we TP first).
external.trigger_tasks = function (caller, callback)
    tracker.external_trigger    = true
    tracker.external_caller     = caller
    tracker.external_callback   = callback
    tracker.teleport_required   = false
    log.info('trigger_tasks queued by ' .. tostring(caller))
end

-- Queue a turn-in WITH teleport-to-Skov_Temis as the first stage if the
-- player isn't already in a whisper town.  This is the Alfred-style entry
-- point other scripts call when they want to interrupt themselves to do
-- a Whispers turn-in.
external.trigger_tasks_with_teleport = function (caller, callback)
    tracker.external_trigger    = true
    tracker.external_caller     = caller
    tracker.external_callback   = callback
    tracker.teleport_required   = true
    log.info('trigger_tasks_with_teleport queued by ' .. tostring(caller))
end

-- Cancel any pending external trigger and any in-flight run.  Safe to
-- call mid-run.  Sends Escape to close any open reward panel AND
-- aborts any in-flight pathfinder movement so the bot actually stops.
external.cancel = function (caller)
    if tracker.running or tracker.external_trigger then
        local cb = tracker.external_callback
        log.info('cancelled by ' .. tostring(caller))
        whispers.send_escape()
        whispers.stop_movement()
        tracker.reset_run()
        if cb then pcall(cb, 'cancelled') end
    end
end

-- Semver-ish "is the running plugin at least this version?" check, mirrors
-- AlfredTheButlerPlugin.check_version so callers can guard new APIs.
external.check_version = function (input)
    if type(input) ~= 'string' then return false end
    input = input:gsub('^v', '')
    local cur, want = {}, {}
    for part in (settings.plugin_version):gmatch('%d+') do
        local n = tonumber(part); if not n then return false end
        cur[#cur + 1] = n
    end
    for part in input:gmatch('%d+') do
        local n = tonumber(part); if not n then return false end
        want[#want + 1] = n
    end
    if #want == 0 then return false end
    -- Right-pad cur with zeros so comparisons line up across 0.1 vs 1.0.0.
    for i = 1, #want do
        local a = cur[i] or 0
        local b = want[i]
        if a > b then return true end
        if a < b then return false end
    end
    return true
end

return external
