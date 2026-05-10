-- core/settings.lua  --  settings cache, refreshed once per pulse from gui

local M = {
    plugin_label   = 'silent_raven',
    plugin_version = '0.1.3',
    plugin_author  = 'magoogle',

    -- Skov_Temis waypoint SNO.  Pulled from AlfredTheButler/core/town.lua.
    teleport_target_sno = 0x1CE51E,

    enabled            = false,
    debug              = false,
    auto_fire          = true,

    -- Reward picking.  Always priority-based -- the fixed-index slider
    -- and pixel-click fallback paths were removed in favor of one
    -- canonical mode: rank by per-slot priority + legendary bonus,
    -- claim via quest_reward.pick_and_accept(idx).  pick_best_index has
    -- a "first valid entry" fallback so we never refuse to claim when
    -- entries exist.
    prefer_legendary       = true,
    legendary_bonus_weight = 50,

    -- Per-slot priority weights (0..10).  All slots default to 5 so
    -- everything is on the table by default; lower a slot to skip it.
    -- Legendary cards still beat any non-legendary regardless of slot
    -- priority (per the user's "we pick the legendary or better one"
    -- rule -- see core/rewards.lua score_entry).
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
        gold       = 5,
        chaos      = 5,
        -- Materials (gem fragments / keys / salvage / primordial dust)
        -- default lower than gear -- they're crafting-material caches,
        -- not equipment.  User can raise if they're farming materials.
        materials  = 3,
        other      = 5,
    },
}

M.update = function (gui)
    if not gui or not gui.elements then return end
    local g = gui.elements
    M.enabled            = g.main_toggle:get()
    M.debug              = g.debug_toggle:get()
    M.auto_fire          = g.auto_fire_toggle:get()

    M.prefer_legendary       = g.prefer_legendary_toggle:get()
    M.legendary_bonus_weight = g.legendary_bonus_slider:get() or 50

    -- Per-slot priority sliders.  Missing element keeps default (5).
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
    if g.priority_materials_slider  then M.slot_priorities.materials  = g.priority_materials_slider:get() end
    if g.priority_other_slider      then M.slot_priorities.other      = g.priority_other_slider:get()      end
end

return M
