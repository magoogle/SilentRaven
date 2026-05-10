-- core/stats.lua  --  in-memory counters + last-pick tracking
--
-- Lives separately from core/tracker.lua because tracker is FSM
-- runtime state (zeroed on reset_run) while these counters need to
-- persist across runs for the duration of the script's life.  Resets
-- only on script reload.
--
-- All values are scalar (bool / number / string) so the table can be
-- handed straight to D4Remote.update_stats which forbids nested
-- tables.  Per-slot counters are flattened to <slot>_claimed keys for
-- the same reason.

local M = {
    -- Cumulative since script load.
    turnins_success     = 0,
    turnins_failed      = 0,
    tp_attempts         = 0,
    legendary_claimed   = 0,
    regular_claimed     = 0,

    -- Per-slot pick counts -- flat keys (no nested table) so this is
    -- D4Remote-friendly and the dashboard can show one row per slot.
    helms_claimed       = 0,
    chest_claimed       = 0,
    legs_claimed        = 0,
    gloves_claimed      = 0,
    boots_claimed       = 0,
    rings_claimed       = 0,
    amulets_claimed     = 0,
    weapons_1h_claimed  = 0,
    weapons_2h_claimed  = 0,
    gold_claimed        = 0,
    chaos_claimed       = 0,
    materials_claimed   = 0,
    other_claimed       = 0,

    -- Most recent claim outcome.
    last_pick_name      = '',
    last_pick_slot      = '',
    last_pick_legendary = false,
    last_pick_t         = 0,

    -- Most recent run outcome (success / failed / cancelled / ...).
    last_reason         = '',
    last_result         = '',
    last_result_t       = 0,
}

-- Bump on successful turn-in.
M.bump_success = function (slot, legendary, name, reason)
    M.turnins_success = M.turnins_success + 1

    if legendary then
        M.legendary_claimed = M.legendary_claimed + 1
    else
        M.regular_claimed   = M.regular_claimed + 1
    end

    -- Per-slot bump.  Flat-key form so D4Remote can show all slots.
    if slot and slot ~= '' then
        local key = tostring(slot) .. '_claimed'
        if M[key] ~= nil then
            M[key] = M[key] + 1
        else
            -- Unknown slot -- bucket under 'other_claimed'.  Defensive
            -- against new-season caches the catalog hasn't classified.
            M.other_claimed = M.other_claimed + 1
        end
    end

    M.last_pick_name      = name or ''
    M.last_pick_slot      = slot or ''
    M.last_pick_legendary = legendary == true
    M.last_pick_t         = (get_time_since_inject and get_time_since_inject()) or 0

    M.last_reason   = reason or ''
    M.last_result   = 'success'
    M.last_result_t = M.last_pick_t
end

-- Bump on failed turn-in.  We don't update last_pick_* on failures --
-- the previous successful pick remains visible in the dashboard,
-- which is more useful than overwriting it with empty fields.
M.bump_failure = function (reason)
    M.turnins_failed = M.turnins_failed + 1
    M.last_reason    = reason or ''
    M.last_result    = 'failed'
    M.last_result_t  = (get_time_since_inject and get_time_since_inject()) or 0
end

-- Bump on every TP cast (debounced cmd in fsm.lua TELEPORTING state).
-- Useful for spotting "TP keeps timing out" patterns in the dashboard.
M.bump_tp = function ()
    M.tp_attempts = M.tp_attempts + 1
end

return M
