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
    reward_index       = 1,

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
end

return M
