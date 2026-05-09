-- core/whispers.lua  --  quest detection + NPC find + click helpers
--
-- Adapted from WarMachine/core/whispers.lua.  Standalone here -- no
-- dependency on a `find` module; we inline the actor-stream scan.
--
-- Live-validated S09 transitions on the Bounty_Meta_Quest:
--   "Collect Grim Favor (N/10)"   -- accumulating; not a turn-in
--   "Return to the Tree of Whispers or find a Crow of the Tree in town"
--                                 -- ready, panel closed
--   "Choose your reward"          -- panel open mid-selection
--   (quest disappears from log)   -- successfully turned in

local M = {}

-- Town zones that ship the bounty NPC.  Used by autofire gate; TP target
-- (Skov_Temis) is the season's primary, but we'll claim from any of these
-- if the player happens to be there.
local TOWN_ZONES = {
    ['Skov_Temis']          = true,
    ['Hawe_TreeOfWhispers'] = true,
}

-- Bounty NPC skin patterns.  `temis_bounty_meta_raven_npc` is the live
-- match in Skov_Temis; the rest are defensive against future-season skins
-- and the legacy Hawezar Tree.
local TREE_NPC_PATTERNS = {
    'temis_bounty_meta_raven_npc',
    'bounty_meta_raven',
    'bounty_meta_crow',
    'bounty_meta',
    'treeofwhispers',
    'tree_of_whispers',
    'crow_of_the_tree',
}

local BOUNTY_QUEST_NAMES = {
    'Bounty_Meta_Quest',
    'Bounty_Meta_',
    'Bounty_Tree_',
}

local TURN_IN_OBJECTIVE_HINTS = {
    'tree of whispers',
    'crow of the tree',
    'choose your reward',
    'choose a reward',
    'select your reward',
}

M.current_zone = function ()
    if not get_current_world then return nil end
    local w = get_current_world()
    if not w or not w.get_current_zone_name then return nil end
    return w:get_current_zone_name()
end

M.in_whisper_town = function ()
    local z = M.current_zone()
    return z ~= nil and TOWN_ZONES[z] == true
end

local function quest_name_matches(name)
    if not name or name == '' then return false end
    for _, want in ipairs(BOUNTY_QUEST_NAMES) do
        if name:sub(1, #want) == want then return true end
    end
    return false
end

-- 1 if a turn-in is ready right now, 0 otherwise.  D4 only ever queues a
-- single whispers turn-in at a time.  Detected via objective text on the
-- bounty meta-quest -- the "Collect Grim Favor" objective flips to
-- "Return to the Tree..." when 10/10 favor is reached.
M.count_ready_bounties = function ()
    if not get_quests then return 0 end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return 0 end
    for _, q in pairs(quests) do
        local n = q.get_name and q:get_name() or ''
        if quest_name_matches(n) then
            local objs_ok, objs = pcall(function () return q:get_objectives() end)
            if objs_ok and objs then
                for _, o in ipairs(objs) do
                    local text = (o.text or ''):lower()
                    for _, hint in ipairs(TURN_IN_OBJECTIVE_HINTS) do
                        if text:find(hint, 1, true) then return 1 end
                    end
                end
            end
        end
    end
    return 0
end

-- True while the bounty meta-quest is in the log, regardless of state.
-- Used as the canonical "did the turn-in succeed?" probe -- the quest
-- vanishes from the log entirely on a successful claim.
M.is_bounty_quest_present = function ()
    if not get_quests then return false end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return false end
    for _, q in pairs(quests) do
        if quest_name_matches(q.get_name and q:get_name() or '') then
            return true
        end
    end
    return false
end

-- Closest interactable Tree/Raven/Crow NPC in the live ally stream.
-- Returns (actor, dist_sq) or (nil, math.huge).  Returns nil before the
-- actor stream has populated post-zone-change -- caller should retry.
M.find_tree_npc = function ()
    if not actors_manager or not actors_manager.get_ally_actors then
        return nil, math.huge
    end
    local lp = get_local_player and get_local_player() or nil
    if not lp then return nil, math.huge end
    local pp = lp.get_position and lp:get_position() or nil
    if not pp then return nil, math.huge end
    local px, py = pp:x(), pp:y()

    local best, best_d2 = nil, math.huge
    for _, a in pairs(actors_manager:get_ally_actors()) do
        local sn = a.get_skin_name and a:get_skin_name() or nil
        if sn then
            local sl = sn:lower()
            local matched = false
            for i = 1, #TREE_NPC_PATTERNS do
                if sl:find(TREE_NPC_PATTERNS[i], 1, true) then matched = true; break end
            end
            if matched and a.is_interactable and a:is_interactable() then
                local p = a.get_position and a:get_position() or nil
                if p then
                    local dx, dy = p:x() - px, p:y() - py
                    local d2 = dx*dx + dy*dy
                    if d2 < best_d2 then
                        best, best_d2 = a, d2
                    end
                end
            end
        end
    end
    return best, best_d2
end

-- Squared 2D distance from local player to an actor.  Returns math.huge
-- if anything's missing.
M.player_dist_sq = function (actor)
    if not actor then return math.huge end
    local lp = get_local_player and get_local_player() or nil
    if not lp then return math.huge end
    local pp = lp.get_position and lp:get_position() or nil
    if not pp then return math.huge end
    local p = actor.get_position and actor:get_position() or nil
    if not p then return math.huge end
    local dx, dy = p:x() - pp:x(), p:y() - pp:y()
    return dx*dx + dy*dy
end

M.send_escape = function ()
    if utility and utility.send_key_press then
        pcall(utility.send_key_press, 0x1B)
    end
end

-- ---------------------------------------------------------------------------
-- Skov_Temis Raven NPC navigation
--
-- Live-validated coordinates from the user (2026-05-09):
--   TP arrival   : ~(2579.58, -482.19, 31.50)
--   Intermediate : ~(2597.24, -488.08, 30.52)  -- avoids a wall on the
--                                                 direct path to the NPC
--   Raven NPC    : ~(2596.38, -495.79, 30.52)
--
-- The intermediate is needed because the NPC actor doesn't appear in
-- the live ally stream until the player is within ~20-25 yards.  After
-- TP arrival we're still 16+ yards away, so find_tree_npc() returns
-- nil and the FSM has nothing to walk toward.  Walking blindly to the
-- intermediate point closes the gap; once the NPC pops into stream the
-- normal "walk to actor + interact" path takes over.
--
-- The intermediate is randomized within INTERMEDIATE_RANDOMIZE_RADIUS
-- yards so repeated runs don't path through the exact same point.
-- ---------------------------------------------------------------------------
M.RAVEN_NPC_POSITION = { x = 2596.38, y = -495.79, z = 30.52 }
M.RAVEN_INTERMEDIATE = { x = 2597.24, y = -488.08, z = 30.52 }

M.INTERMEDIATE_RANDOMIZE_RADIUS = 2.0    -- yards (uniform jitter)
M.INTERMEDIATE_ARRIVAL_RADIUS   = 3.5    -- "close enough" to advance

-- Per-zone hard-coded NPC + intermediate coords.  Used by WALK_NPC's
-- static fallback (when the actor isn't in stream yet) AND by
-- maybe_autofire as the gate for "is it safe to fire here without
-- seeing the actor first?".
--
-- Currently only Skov_Temis is mapped.  Hawe_TreeOfWhispers is in
-- TOWN_ZONES but lacks coords -- autofire there will require the
-- actor to already be in stream.
M.ZONE_COORDS = {
    ['Skov_Temis'] = {
        npc_pos      = M.RAVEN_NPC_POSITION,
        intermediate = M.RAVEN_INTERMEDIATE,
    },
}

-- True when we have hard-coded NPC coords for the given zone.
M.has_known_coords = function (zone)
    return M.ZONE_COORDS[zone or ''] ~= nil
end

-- Coords for the zone the player is currently in, or nil.
M.current_zone_coords = function ()
    return M.ZONE_COORDS[M.current_zone() or '']
end

-- Pick a randomized point within INTERMEDIATE_RANDOMIZE_RADIUS yards
-- of the canonical intermediate.  Z stays exact (terrain is flat in
-- this corridor).  Call once per attempt and reuse the result.
M.choose_intermediate = function ()
    local r  = M.INTERMEDIATE_RANDOMIZE_RADIUS
    local dx = (math.random() * 2 - 1) * r
    local dy = (math.random() * 2 - 1) * r
    return {
        x = M.RAVEN_INTERMEDIATE.x + dx,
        y = M.RAVEN_INTERMEDIATE.y + dy,
        z = M.RAVEN_INTERMEDIATE.z,
    }
end

-- Walk toward a static {x, y, z} position via pathfinder.  Best-effort
-- (silent no-op if the host doesn't expose pathfinder + vec3).
M.move_to_pos = function (pos)
    if not pos or not pathfinder then return end
    if not vec3 or not vec3.new then return end
    local p = vec3:new(pos.x, pos.y, pos.z)
    if pathfinder.move_to_cpathfinder then
        pcall(pathfinder.move_to_cpathfinder, p)
    elseif pathfinder.request_move then
        pcall(pathfinder.request_move, p)
    end
end

-- 2D Euclidean distance from local player to a {x, y, z} position.
-- Returns math.huge on any failure (no player, no position).
M.player_dist_to_pos = function (pos)
    if not pos then return math.huge end
    local lp = get_local_player and get_local_player() or nil
    if not lp or not lp.get_position then return math.huge end
    local pp = lp:get_position()
    if not pp then return math.huge end
    local dx, dy = pos.x - pp:x(), pos.y - pp:y()
    return math.sqrt(dx*dx + dy*dy)
end

-- True when the host exposes the proper quest_reward API.  Checked once
-- per call so a host upgrade mid-run takes effect on the next attempt.
M.has_quest_reward_api = function ()
    return quest_reward ~= nil
        and type(quest_reward.is_open) == 'function'
        and type(quest_reward.pick_and_accept) == 'function'
end

-- Diagnostic: dump every entry from quest_reward.enumerate() to console.
-- Triggered by the "Dump reward options" GUI keybind when the panel is
-- open -- useful for confirming the right Reward card index when D4
-- ships 3-5 choices that vary by season.
--
-- Output shape (one line per entry):
--   [SilentRaven/dump]  [<index>] sno=<hex>(<dec>) name=<internal_name> valid=<bool> [<-- SELECTED>]
--
-- Always safe to call: gracefully degrades when the host doesn't expose
-- quest_reward / individual sub-functions.  Not on a hot path -- only
-- fires on user keybind, never per-frame.
M.dump_rewards = function ()
    if not console or not console.print then return end
    local PFX = '[SilentRaven/dump] '

    if not quest_reward then
        console.print(PFX .. 'quest_reward API not exposed by this host')
        return
    end

    local open = false
    if type(quest_reward.is_open) == 'function' then
        local ok, ret = pcall(quest_reward.is_open)
        if ok then open = (ret == true) end
    end
    console.print(PFX .. 'panel open: ' .. tostring(open))

    local sel = -1
    if type(quest_reward.selected_index) == 'function' then
        local ok, ret = pcall(quest_reward.selected_index)
        if ok and type(ret) == 'number' then sel = ret end
    end
    console.print(PFX .. 'selected index: ' .. tostring(sel))

    if type(quest_reward.enumerate) ~= 'function' then
        console.print(PFX .. 'enumerate() not exposed; cannot list entries')
        return
    end
    local ok, entries = pcall(quest_reward.enumerate)
    if not ok or not entries then
        console.print(PFX .. 'enumerate() returned nothing')
        return
    end

    -- Sort keys so output is stable across calls.  Numeric keys first,
    -- then strings (defensive -- the API stub says number keys, but real
    -- hosts have surprised us before).
    local keys = {}
    for k, _ in pairs(entries) do keys[#keys + 1] = k end
    table.sort(keys, function (a, b)
        local na, nb = type(a) == 'number', type(b) == 'number'
        if na and nb then return a < b end
        if na ~= nb then return na end
        return tostring(a) < tostring(b)
    end)

    console.print(PFX .. 'enumerate() count: ' .. #keys)

    -- Lazy require so this still works if rewards.lua fails to load
    -- for any reason -- the basic field dump must always be available.
    local rewards_ok, rewards = pcall(require, 'core.rewards')

    for _, k in ipairs(keys) do
        local e = entries[k] or {}
        local sno_str = '?'
        if type(e.sno) == 'number' then
            sno_str = string.format('0x%X(%d)', e.sno, e.sno)
        elseif e.sno ~= nil then
            sno_str = tostring(e.sno)
        end
        local marker = (k == sel) and ' <-- SELECTED' or ''
        console.print(string.format('%s  [%s] sno=%s name=%s valid=%s%s',
            PFX, tostring(k), sno_str,
            tostring(e.internal_name or '?'),
            tostring(e.valid),
            marker))

        -- Slot + legendary verdict from the rewards classifier.  Gives
        -- the user immediate feedback on whether catalog/heuristic
        -- parsing is finding the right thing.
        if rewards_ok and rewards then
            local slot      = rewards.extract_slot(e)
            local legendary, evidence = rewards.is_legendary(e)
            local display   = rewards.display_name(e)
            console.print(string.format('%s        -> display="%s" slot=%s legendary=%s (%s)',
                PFX, display, slot, tostring(legendary), evidence))
        end

        -- Every field outside {sno, internal_name, valid}.  This is
        -- where we'll see any rarity / legendary / quality field the
        -- host exposes that the API stub didn't document.  If a field
        -- shows up here that we should be using for legendary
        -- detection, add it to rewards.is_legendary.
        local extras = {}
        for fk, fv in pairs(e) do
            if fk ~= 'sno' and fk ~= 'internal_name' and fk ~= 'valid' then
                extras[#extras + 1] = tostring(fk) .. '=' .. tostring(fv)
            end
        end
        if #extras > 0 then
            table.sort(extras)
            console.print(PFX .. '        extras: ' .. table.concat(extras, ', '))
        end
    end
end

-- True when the reward panel is on screen.  Uses quest_reward.is_open
-- when available; falls back to objective-text matching on older hosts.
M.reward_panel_open = function ()
    if M.has_quest_reward_api() then
        local ok, ret = pcall(quest_reward.is_open)
        if ok then return ret == true end
    end
    -- Fallback: objective text says "Choose your reward" once the panel
    -- has opened at least once this turn-in (sticky -- doesn't unset on
    -- close, so unreliable for retries; the API path is preferred).
    if not get_quests then return false end
    local ok, quests = pcall(get_quests)
    if not ok or not quests then return false end
    for _, q in pairs(quests) do
        if quest_name_matches(q.get_name and q:get_name() or '') then
            local objs_ok, objs = pcall(function () return q:get_objectives() end)
            if objs_ok and objs then
                for _, o in ipairs(objs) do
                    local text = (o.text or ''):lower()
                    if text:find('choose your reward', 1, true)
                        or text:find('choose a reward', 1, true)
                        or text:find('select your reward', 1, true)
                    then return true end
                end
            end
        end
    end
    return false
end

return M
