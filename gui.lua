-- gui.lua  --  user-facing settings tree + version label

local plugin_label   = 'silent_raven'
local plugin_version = '0.1'
local plugin_author  = 'magoogle'

local gui = {}

local function cb(default, key)
    return checkbox:new(default, get_hash(plugin_label .. '_' .. key))
end

local function si(min_v, max_v, default, key)
    return slider_int:new(min_v, max_v, default, get_hash(plugin_label .. '_' .. key))
end

gui.elements = {
    main_tree                  = tree_node:new(0),

    main_toggle                = cb(false, 'main_toggle'),
    auto_fire_toggle           = cb(true,  'auto_fire'),
    debug_toggle               = cb(false, 'debug'),

    manual_fire_keybind        = keybind:new(0x0A, true, get_hash(plugin_label .. '_manual_fire')),
    dump_rewards_keybind       = keybind:new(0x0A, true, get_hash(plugin_label .. '_dump_rewards')),
    dump_rewards_button        = button:new(get_hash(plugin_label .. '_dump_rewards_button')),

    reward_tree                = tree_node:new(1),
    -- quest_reward.enumerate() on this host returns 1-INDEXED keys
    -- (live-validated S09: count=4, keys [1..4]).  Slider matches the
    -- live indexing so the GUI value passes straight to
    -- quest_reward.pick_and_accept(idx) without translation.  Range 1-5
    -- covers the observed 3-5 card spread.
    reward_index_slider        = si(1, 5, 1, 'reward_index'),

    fallback_tree              = tree_node:new(1),
    use_click_fallback_toggle  = cb(false, 'use_click_fallback'),
    -- Fracs stored as int-permille (0..1000) since slider_int is what's
    -- available; settings.update divides by 1000.0 to get the 0..1 frac.
    reward_x_slider            = si(0, 1000, 400, 'reward_x'),
    reward_y_slider            = si(0, 1000, 550, 'reward_y'),
    accept_x_slider            = si(0, 1000, 500, 'accept_x'),
    accept_y_slider            = si(0, 1000, 850, 'accept_y'),
    show_calibration_toggle    = cb(false, 'show_calibration'),
}

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version
gui.plugin_author  = plugin_author

function gui.render()
    if not gui.elements.main_tree:push('SilentRaven v' .. plugin_version .. ' by ' .. plugin_author) then
        return
    end

    gui.elements.main_toggle:render('Enable',
        'Master enable for SilentRaven.  Auto-fires whisper turn-ins when in town and exposes SilentRavenPlugin to other scripts.')

    gui.elements.auto_fire_toggle:render('Auto-fire in town',
        'When enabled, SilentRaven claims any ready whisper bounty whenever the player is in Skov_Temis or Hawe_TreeOfWhispers.  Disable to make this script strictly call-driven.')

    gui.elements.debug_toggle:render('Debug logging',
        'Print FSM transitions to console.  Useful while calibrating click points or diagnosing failed runs.')

    gui.elements.manual_fire_keybind:render('Manual trigger keybind',
        'Press to fire a turn-in run now (TP-to-Temis included).  Equivalent to calling SilentRavenPlugin.trigger_tasks_with_teleport(...).')

    gui.elements.dump_rewards_keybind:render('Dump reward options (keybind)',
        'Bind a key, then press it with the reward panel open to print every quest_reward entry to console. Works even when the plugin is disabled.')
    gui.elements.dump_rewards_button:render('Dump reward options',
        'One-click alternative to the keybind. Click this with the reward panel open to print every quest_reward entry (index, sno, internal_name, valid, currently-selected) to console. D4 ships 3-5 choices depending on season -- use the dump output to set Reward card index correctly.', 0)

    if gui.elements.reward_tree:push('Reward selection') then
        gui.elements.reward_index_slider:render('Reward card index',
            'Which reward card to claim. Indices are 1-based and match the [N] keys printed by Dump reward options. Live S09 shows 4 cards (Helms / Legs / Rings / Rings); count and order vary by season.')
        gui.elements.reward_tree:pop()
    end

    if gui.elements.fallback_tree:push('Click-fallback (advanced)') then
        render_menu_header('SilentRaven uses quest_reward.pick_and_accept by default.  Enable click fallback only if your QQT host doesn\'t expose that API or the API isn\'t claiming reliably.')
        gui.elements.use_click_fallback_toggle:render('Use click fallback',
            'Force the two-click pixel path instead of the quest_reward API.')
        gui.elements.show_calibration_toggle:render('Show calibration overlay',
            'Render crosshairs at the configured reward + accept click points so you can dial them in without consuming a turn-in.')
        render_menu_header('Click points (in 0.001 units of screen size; 500 = mid-screen).')
        gui.elements.reward_x_slider:render('Reward X (per-mille)',
            'Horizontal position of the reward card click, scaled across screen width.')
        gui.elements.reward_y_slider:render('Reward Y (per-mille)',
            'Vertical position of the reward card click, scaled across screen height.')
        gui.elements.accept_x_slider:render('Accept X (per-mille)',
            'Horizontal position of the Accept-button click.')
        gui.elements.accept_y_slider:render('Accept Y (per-mille)',
            'Vertical position of the Accept-button click.')
        gui.elements.fallback_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui
