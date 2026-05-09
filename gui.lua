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

    -- ---- Priority pick (auto-select by slot + legendary preference) ----
    auto_pick_toggle           = cb(false, 'auto_pick'),
    priority_tree              = tree_node:new(1),
    prefer_legendary_toggle    = cb(true,  'prefer_legendary'),
    legendary_bonus_slider     = si(0, 100, 50, 'legendary_bonus'),

    -- Per-slot priority sliders (0 = skip, 10 = max).  Slot ids match
    -- core/rewards.lua KNOWN_SLOTS.
    priority_helms_slider      = si(0, 10, 5, 'pri_helms'),
    priority_chest_slider      = si(0, 10, 5, 'pri_chest'),
    priority_legs_slider       = si(0, 10, 5, 'pri_legs'),
    priority_gloves_slider     = si(0, 10, 5, 'pri_gloves'),
    priority_boots_slider      = si(0, 10, 5, 'pri_boots'),
    priority_rings_slider      = si(0, 10, 5, 'pri_rings'),
    priority_amulets_slider    = si(0, 10, 5, 'pri_amulets'),
    priority_weapons_1h_slider = si(0, 10, 5, 'pri_weapons_1h'),
    priority_weapons_2h_slider = si(0, 10, 5, 'pri_weapons_2h'),
    priority_gold_slider       = si(0, 10, 7, 'pri_gold'),
    priority_chaos_slider      = si(0, 10, 5, 'pri_chaos'),
    priority_other_slider      = si(0, 10, 1, 'pri_other'),

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
        gui.elements.auto_pick_toggle:render('Auto-pick by priority',
            'When ON, SilentRaven scores every live enumerate() entry by per-slot priority + legendary bonus and claims the winner. When OFF, claims the fixed Reward card index below.')
        gui.elements.reward_index_slider:render('Reward card index (fixed-pick mode)',
            '1-based index used when Auto-pick is OFF. Matches the [N] keys printed by Dump reward options. Ignored when Auto-pick is ON.')
        gui.elements.reward_tree:pop()
    end

    if gui.elements.priority_tree:push('Priority pick (auto-pick mode)') then
        render_menu_header('Per-slot priority weights. 0 = skip this slot entirely; higher values win ties. Use Dump reward options to see what your live cards parse as, then weight accordingly.')
        gui.elements.prefer_legendary_toggle:render('Prefer legendary',
            'When ON, legendary-detected cards get the bonus weight added. Detection probes extra fields on the live entry (rarity / quality / etc.) then falls back to internal_name pattern matching ("legendary", "ancestral", "guaranteed").')
        gui.elements.legendary_bonus_slider:render('Legendary bonus weight (0-100)',
            'Score boost added to legendary cards when Prefer legendary is ON. Set high (e.g. 100) to make any legendary outrank any non-legendary regardless of slot. Set low (e.g. 5) to only break ties.')
        render_menu_header('Slot priorities (0..10):')
        gui.elements.priority_helms_slider     :render('Helms',             'Priority weight for Collection of Helms (sno 1087411).')
        gui.elements.priority_chest_slider     :render('Chest',             'Priority weight for Collection of Chestplates (sno 1087549).')
        gui.elements.priority_legs_slider      :render('Legs',              'Priority weight for Collection of Leg Guards (sno 1087551).')
        gui.elements.priority_gloves_slider    :render('Gloves',            'Priority weight for Collection of Gauntlets (sno 1087555).')
        gui.elements.priority_boots_slider     :render('Boots',             'Priority weight for Collection of Boots (sno 1087553).')
        gui.elements.priority_rings_slider     :render('Rings',             'Priority weight for Collection of Rings (sno 1087570).')
        gui.elements.priority_amulets_slider   :render('Amulets',           'Priority weight for Collection of Amulets (sno 1087572).')
        gui.elements.priority_weapons_1h_slider:render('One-Hand Weapons',  'Priority weight for Collection of One-handed Weapons (sno 1087567 / Greater 1092135).')
        gui.elements.priority_weapons_2h_slider:render('Two-Hand Weapons',  'Priority weight for Collection of Two-Handed Weapons (sno 1087557 / Greater 1092140).')
        gui.elements.priority_gold_slider      :render('Gold (currency)',   'Priority weight for the gold cache (Material Collection of Gold, sno 2102725 -- legendary). Defaults to 7 because gold is universally useful.')
        gui.elements.priority_chaos_slider     :render('Chaos (wildcard)',  'Priority weight for the random-gear Chaos cache (sno 598510 / Greater 1092147).')
        gui.elements.priority_other_slider     :render('Other / Unknown',   'Priority weight for any cache that doesn\'t match a known slot (defensive against future-season caches).')
        gui.elements.priority_tree:pop()
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
