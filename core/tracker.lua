-- core/tracker.lua  --  runtime state for the FSM and external API

local M = {
    -- FSM state name; nil means idle / no run in flight.
    state               = nil,
    state_t             = nil,

    -- True between trigger and DONE/FAILED.  Other scripts poll this
    -- via SilentRavenPlugin.get_status().running and yield while true.
    running             = false,

    -- 'auto' (in-town autofire), 'external', 'external+tp'.
    last_reason         = '',

    -- External-trigger queue (set by external.lua, consumed on next tick).
    external_trigger    = false,
    external_caller     = nil,
    external_callback   = nil,
    teleport_required   = false,

    -- Pause state (external.pause / external.resume).
    paused              = false,
    paused_by           = nil,

    -- Per-attempt state.
    attempts            = 0,
    interacts_fired     = 0,
    last_interact_t     = nil,
    interact_npc        = nil,

    -- TP recast debounce stamp.  Separate from last_interact_t so the
    -- two clocks can't stomp each other.
    tp_last_cast_t      = nil,

    -- Per-zone latch -- once a turn-in succeeds in a zone, don't auto-fire
    -- again until the player leaves and re-enters that zone.  Without this
    -- we'd loop forever once the bounty quest wasn't immediately re-issued.
    last_zone_handled   = nil,
    last_observed_zone  = nil,

    -- Cached "is a turn-in ready?".  Refreshed by throttled scan in main.
    ready               = false,
    last_ready_check_t  = 0,

    -- Last terminal result for status display: 'success', 'failed', or nil.
    last_result         = nil,
    last_result_t       = 0,

    -- All-task-done flag in the Alfred sense: true between a finished run
    -- and the next trigger.  Lets callers detect callback-firing from a
    -- one-shot poll if they didn't pass a callback.
    all_task_done       = false,
}

M.reset_run = function ()
    M.state             = nil
    M.state_t           = nil
    M.running           = false
    M.attempts          = 0
    M.interacts_fired   = 0
    M.last_interact_t   = nil
    M.interact_npc      = nil
    M.tp_last_cast_t    = nil
    M.external_trigger  = false
    M.external_caller   = nil
    M.external_callback = nil
    M.teleport_required = false
end

return M
