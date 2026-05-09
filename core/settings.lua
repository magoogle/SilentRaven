-- core/settings.lua  --  settings cache, refreshed once per pulse from gui

local M = {
    plugin_label   = 'silent_raven',
    plugin_version = '0.1',
    plugin_author  = 'magoogle',

    -- Skov_Temis waypoint SNO.  Pulled from AlfredTheButler/core/town.lua.
    teleport_target_sno = 0x1CE51E,

    enabled            = false,
    debug              = false,
    auto_fire          = true,

    -- Reward card index (1-based -- matches quest_reward.enumerate() keys
    -- on this host; live-validated S09 with count=4, keys [1..4]).
    -- Used as the picked index when auto_pick_by_priority is OFF, or as
    -- the fallback when priority pick returns no winner.
    reward_index       = 1,

    -- Priority-based picking.  When on, the FSM scores every live
    -- enumerate() entry by per-slot priority + legendary bonus and
    -- picks the winner.  When off, falls back to reward_index.
    auto_pick_by_priority = false,
    prefer_legendary       = true,
    legendary_bonus_weight = 50,

    -- Per-slot priority weights (0..10; 0 = skip this slot entirely).
    -- Keys must match rewards.KNOWN_SLOTS.  Defaults are middle (5)
    -- so the user has to opt in to specific slots; 'other' starts low
    -- so unrecognized cache types don't accidentally win ties.
    slot_priorities = {
        helms      = 5,
        chest      = 5,
        legs       = 5,
        gloves     = 5,
        boots      = 5,
        rings      = 5,
        amulets    = 5,
        weapons_1h = 5,
        weapons_2h = 5,
        gold       = 7,    -- gold caches default a bit higher; gold is universally useful
        chaos      = 5,
        other      = 1,
    },

    -- Click-fallback path.  Used only if the host doesn't expose
    -- quest_reward.pick_and_accept (older runtime).  Defaults tuned for
    -- 16:9; tweak in GUI if the panel sits elsewhere.
    use_click_fallback = true,
    reward_x_frac      = 0.40,
    reward_y_frac      = 0.55,
    accept_x_frac      = 0.50,
    accept_y_frac      = 0.85,

    show_calibration   = false,
}

-- Refresh from gui.  GUI sliders store fracs as int-permille (0..1000)
-- because slider_int is what's available; we divide here.
M.update = function (gui)
    if not gui or not gui.elements then return end
    local g = gui.elements
    M.enabled            = g.main_toggle:get()
    M.debug              = g.debug_toggle:get()
    M.auto_fire          = g.auto_fire_toggle:get()
    M.reward_index       = g.reward_index_slider:get()
    M.use_click_fallback = g.use_click_fallback_toggle:get()
    M.reward_x_frac      = (g.reward_x_slider:get() or 400) / 1000.0
    M.reward_y_frac      = (g.reward_y_slider:get() or 550) / 1000.0
    M.accept_x_frac      = (g.accept_x_slider:get() or 500) / 1000.0
    M.accept_y_frac      = (g.accept_y_slider:get() or 850) / 1000.0
    M.show_calibration   = g.show_calibration_toggle:get()

    -- Priority pick settings.  Sliders are present unconditionally; the
    -- auto_pick_by_priority toggle gates whether they're used at claim time.
    M.auto_pick_by_priority  = g.auto_pick_toggle:get()
    M.prefer_legendary       = g.prefer_legendary_toggle:get()
    M.legendary_bonus_weight = g.legendary_bonus_slider:get() or 50

    -- Per-slot priority sliders.  Slider names follow the pattern
    -- priority_<slot>_slider; missing element defaults to 5 (neutral).
    if g.priority_helms_slider      then M.slot_priorities.helms      = g.priority_helms_slider:get()      end
    if g.priority_chest_slider      then M.slot_priorities.chest      = g.priority_chest_slider:get()      end
    if g.priority_legs_slider       then M.slot_priorities.legs       = g.priority_legs_slider:get()       end
    if g.priority_gloves_slider     then M.slot_priorities.gloves     = g.priority_gloves_slider:get()     end
    if g.priority_boots_slider      then M.slot_priorities.boots      = g.priority_boots_slider:get()      end
    if g.priority_rings_slider      then M.slot_priorities.rings      = g.priority_rings_slider:get()      end
    if g.priority_amulets_slider    then M.slot_priorities.amulets    = g.priority_amulets_slider:get()    end
    if g.priority_weapons_1h_slider then M.slot_priorities.weapons_1h = g.priority_weapons_1h_slider:get() end
    if g.priority_weapons_2h_slider then M.slot_priorities.weapons_2h = g.priority_weapons_2h_slider:get() end
    if g.priority_gold_slider       then M.slot_priorities.gold       = g.priority_gold_slider:get()       end
    if g.priority_chaos_slider      then M.slot_priorities.chaos      = g.priority_chaos_slider:get()      end
    if g.priority_other_slider      then M.slot_priorities.other      = g.priority_other_slider:get()      end
end

return M
