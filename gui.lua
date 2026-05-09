-- gui.lua  --  user-facing settings tree + version label

local plugin_label   = 'silent_raven'
local plugin_version = '0.1'
local plugin_author  = 'magoogle'

-- Lazy-required so a malformed core/rewards.lua doesn't kill the GUI
-- module load -- the catalog status line is best-effort.
local rewards_ok, rewards = pcall(require, 'core.rewards')

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
    reload_catalog_button      = button:new(get_hash(plugin_label .. '_reload_catalog_button')),

    -- Priority pick (the only pick mode -- fixed-index slider and
    -- pixel-click fallback were removed).
    priority_tree              = tree_node:new(1),
    prefer_legendary_toggle    = cb(true,  'prefer_legendary'),
    legendary_bonus_slider     = si(0, 100, 50, 'legendary_bonus'),

    -- Per-slot priority sliders (0 = skip, 10 = max).  Slot ids match
    -- core/rewards.lua KNOWN_SLOTS.  All default 5 -- pure neutral
    -- baseline; legendary cards still beat non-legendary at the same
    -- priority via the legendary_bonus_weight (default 50).
    priority_helms_slider      = si(0, 10, 5, 'pri_helms'),
    priority_chest_slider      = si(0, 10, 5, 'pri_chest'),
    priority_legs_slider       = si(0, 10, 5, 'pri_legs'),
    priority_gloves_slider     = si(0, 10, 5, 'pri_gloves'),
    priority_boots_slider      = si(0, 10, 5, 'pri_boots'),
    priority_rings_slider      = si(0, 10, 5, 'pri_rings'),
    priority_amulets_slider    = si(0, 10, 5, 'pri_amulets'),
    priority_weapons_1h_slider = si(0, 10, 5, 'pri_weapons_1h'),
    priority_weapons_2h_slider = si(0, 10, 5, 'pri_weapons_2h'),
    priority_gold_slider       = si(0, 10, 5, 'pri_gold'),
    priority_chaos_slider      = si(0, 10, 5, 'pri_chaos'),
    priority_other_slider      = si(0, 10, 5, 'pri_other'),
}

gui.plugin_label   = plugin_label
gui.plugin_version = plugin_version
gui.plugin_author  = plugin_author

function gui.render()
    if not gui.elements.main_tree:push('SilentRaven v' .. plugin_version .. ' by ' .. plugin_author) then
        return
    end

    -- Catalog freshness header.  Best-effort: if rewards failed to load
    -- (compile error, missing module) we just skip.
    if rewards_ok and rewards then
        local src = rewards.CATALOG_SOURCE or 'unknown'
        local age = rewards.last_sync_str and rewards.last_sync_str() or 'unknown'
        if src == 'cloud' then
            render_menu_header(string.format('Catalog: cloud (synced %s)', age))
        else
            render_menu_header(
                'Catalog: embedded fallback (run Reload Catalog below to fetch from cloud)')
        end
    end

    gui.elements.main_toggle:render('Enable',
        'Master enable for SilentRaven.  Auto-fires whisper turn-ins when in town and exposes SilentRavenPlugin to other scripts.')

    gui.elements.auto_fire_toggle:render('Auto-fire in town',
        'When enabled, SilentRaven claims any ready whisper bounty whenever the player is in Skov_Temis or Hawe_TreeOfWhispers.  Disable to make this script strictly call-driven.')

    gui.elements.debug_toggle:render('Debug logging',
        'Print FSM transitions to console.  Useful while diagnosing failed runs.')

    gui.elements.manual_fire_keybind:render('Manual trigger keybind',
        'Press to fire a turn-in run now (TP-to-Temis included).  Equivalent to calling SilentRavenPlugin.trigger_tasks_with_teleport(...).')

    gui.elements.dump_rewards_keybind:render('Dump reward options (keybind)',
        'Bind a key, then press it with the reward panel open to print every quest_reward entry to console. Works even when the plugin is disabled.')
    gui.elements.dump_rewards_button:render('Dump reward options',
        'One-click alternative to the keybind. Click this with the reward panel open to print every quest_reward entry (index, sno, internal_name, valid, currently-selected) to console -- handy for verifying slot/legendary classification on new-season SNOs.', 0)

    gui.elements.reload_catalog_button:render('Reload Catalog (cloud)',
        'Run Updater.bat to fetch the latest cache catalog from looter.d4data.live, then reload it into memory. Use after a season patch to pick up new SNOs without editing code. Brief (~50-200ms) freeze while cmd.exe spawns; safe as a one-shot user action.', 0)

    if gui.elements.priority_tree:push('Priority pick') then
        render_menu_header('Per-slot priority weights. All default 5 (neutral). Lower a slot to deprioritize it; raise to prefer it. Legendary cards still beat non-legendary at the same priority via the bonus weight below.')
        gui.elements.prefer_legendary_toggle:render('Prefer legendary',
            'When ON, legendary-detected cards get the bonus weight added so they outrank same-slot non-legendary entries. Detection comes from the cloud catalog (Greater / Ancestral / Material variants flagged legendary) with internal_name pattern matching as fallback.')
        gui.elements.legendary_bonus_slider:render('Legendary bonus weight (0-100)',
            'Score boost added to legendary cards when Prefer legendary is ON. Set high (e.g. 100) to make any legendary outrank any non-legendary regardless of slot. Set low (e.g. 5) to only break ties.')
        render_menu_header('Slot priorities (0..10):')
        gui.elements.priority_helms_slider     :render('Helms',             'Priority weight for Collection of Helms (sno 1087411 / Greater 1092131 / Ancestral 2156394).')
        gui.elements.priority_chest_slider     :render('Chest',             'Priority weight for Collection of Chestplates (sno 1087549 / Greater 1092149 / Ancestral 2156390).')
        gui.elements.priority_legs_slider      :render('Legs',              'Priority weight for Collection of Leg Guards (sno 1087551 / Greater 1092153 / Ancestral 2156396).')
        gui.elements.priority_gloves_slider    :render('Gloves',            'Priority weight for Collection of Gauntlets (sno 1087555 / Greater 1092151 / Ancestral 2156392).')
        gui.elements.priority_boots_slider     :render('Boots',             'Priority weight for Collection of Boots (sno 1087553 / Greater 1092145 / Ancestral 2156386).')
        gui.elements.priority_rings_slider     :render('Rings',             'Priority weight for Collection of Rings (sno 1087570 / Greater 1092155 / Ancestral 2156398).')
        gui.elements.priority_amulets_slider   :render('Amulets',           'Priority weight for Collection of Amulets (sno 1087572 / Greater 1092142 / Ancestral 2156382).')
        gui.elements.priority_weapons_1h_slider:render('One-Hand Weapons',  'Priority weight for Collection of One-handed Weapons (sno 1087567 / Greater 1092135 / Ancestral 2156377).')
        gui.elements.priority_weapons_2h_slider:render('Two-Hand Weapons',  'Priority weight for Collection of Two-Handed Weapons (sno 1087557 / Greater 1092140 / Ancestral 2156380).')
        gui.elements.priority_gold_slider      :render('Gold (currency)',   'Priority weight for the gold cache (Material Collection of Gold, sno 2102725 -- always legendary).')
        gui.elements.priority_chaos_slider     :render('Chaos (wildcard)',  'Priority weight for random-gear Chaos caches (sno 598510 / Greater 1092147 / Ancestral 2156388).')
        gui.elements.priority_other_slider     :render('Other / Unknown',   'Priority weight for any cache that doesn\'t match a known slot (defensive against future-season caches).')
        gui.elements.priority_tree:pop()
    end

    gui.elements.main_tree:pop()
end

return gui
