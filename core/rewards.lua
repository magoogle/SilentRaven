-- core/rewards.lua  --  reward classification + priority-based picking
--
-- Pipeline at claim time:
--   1. quest_reward.enumerate() -> live entry table
--   2. For each entry, extract a normalized slot id
--      (catalog lookup by SNO first, internal_name pattern fallback).
--   3. Detect legendary (best-effort -- probes extra fields on the entry,
--      then falls back to internal_name pattern matching).
--   4. Score by user-configured per-slot priority + legendary bonus.
--   5. Return the winning 1-based index for quest_reward.pick_and_accept.
--
-- All work is one-shot at claim time -- not per-frame.

local M = {}

-- ---------------------------------------------------------------------------
-- BountyMetaCache catalog
--
-- Lifted from LooteerV3/data/items.lua (catalog v20260509, ~10928 entries).
-- Embedded here so SilentRaven runs even when LooteerV3 isn't loaded -- the
-- alternative was an absolute-path dofile or a fragile cross-script require.
--
-- LooteerV3 schema:  [sno] = { n=display_name, g=group, t=type, r=rarity }
-- All entries below have g='cache', t='BountyMetaCache', r=0 -- which means
-- rarity is NOT encoded at the SNO level.  If the host distinguishes a
-- legendary-guaranteed cache from a regular one, that signal must come from
-- a field on the live quest_reward entry, NOT from the SNO.  See
-- M.is_legendary below for how we probe.
-- ---------------------------------------------------------------------------
local CACHE_CATALOG = {
    -- Regular BountyMetaCache (armor/weapons/jewelry).  All r=0 in the
    -- master catalog -- "regular" is the absence of a "Greater " prefix
    -- on the cache, NOT a rarity flag.
    [1087411] = { name = 'Collection of Helms',                 slot = 'helms',      legendary = false },
    [1087549] = { name = 'Collection of Chestplates',           slot = 'chest',      legendary = false },
    [1087551] = { name = 'Collection of Leg Guards',            slot = 'legs',       legendary = false },
    [1087553] = { name = 'Collection of Boots',                 slot = 'boots',      legendary = false },
    [1087555] = { name = 'Collection of Gauntlets',             slot = 'gloves',     legendary = false },
    [1087557] = { name = 'Collection of Two-Handed Weapons',    slot = 'weapons_2h', legendary = false },
    [1087567] = { name = 'Collection of One-handed Weapons',    slot = 'weapons_1h', legendary = false },
    [1087570] = { name = 'Collection of Rings',                 slot = 'rings',      legendary = false },
    [1087572] = { name = 'Collection of Amulets',               slot = 'amulets',    legendary = false },

    -- "Greater" BountyMetaCache.  Same r=0 as regulars in the catalog
    -- so the only legendary signal at this level is the name prefix --
    -- we hard-code legendary=true here so the runtime doesn't have to
    -- re-classify by name on every claim.
    [1092131] = { name = 'Greater Collection of Helms',              slot = 'helms',      legendary = true },
    [1092135] = { name = 'Greater Collection of One-handed Weapons', slot = 'weapons_1h', legendary = true },
    [1092140] = { name = 'Greater Collection of Two-Handed Weapons', slot = 'weapons_2h', legendary = true },
    [1092142] = { name = 'Greater Collection of Amulets',            slot = 'amulets',    legendary = true },
    [1092145] = { name = 'Greater Collection of Boots',              slot = 'boots',      legendary = true },
    [1092149] = { name = 'Greater Collection of Chestplates',        slot = 'chest',      legendary = true },
    [1092151] = { name = 'Greater Collection of Gauntlets',          slot = 'gloves',     legendary = true },
    [1092153] = { name = 'Greater Collection of Leg Guards',         slot = 'legs',       legendary = true },
    [1092155] = { name = 'Greater Collection of Rings',              slot = 'rings',      legendary = true },

    -- Whisper Cache type (Chaos = wildcard random gear, Gold = gold rewards).
    -- Here the catalog DOES carry rarity: r=3 is legendary.
    -- Live-validated SNOs from a S09 dump:
    --   598510  internal_name=BountyMeta_Cache_Chaos         (regular)
    --   2102725 internal_name=BountyMeta_Cache_Gold_Upgraded (legendary; user-confirmed)
    [598510]  = { name = 'Collection of Chaos',         slot = 'chaos', legendary = false },
    [1092147] = { name = 'Greater Collection of Chaos', slot = 'chaos', legendary = true },
    [2102725] = { name = 'Material Collection of Gold', slot = 'gold',  legendary = true },
}

M.CACHE_CATALOG = CACHE_CATALOG

-- Slot ids the user can configure priority for.  Keep in sync with the
-- per-slot sliders in gui.lua.  'other' catches anything we don't
-- recognize from SNO catalog or internal_name parsing -- defensive
-- against future-season caches we haven't catalogued yet.
local KNOWN_SLOTS = {
    'helms', 'chest', 'legs', 'gloves', 'boots',
    'rings', 'amulets',
    'weapons_1h', 'weapons_2h',
    'gold',  'chaos',
    'other',
}
M.KNOWN_SLOTS = KNOWN_SLOTS

-- Display labels for the GUI.  Keep parallel to KNOWN_SLOTS.
M.SLOT_DISPLAY = {
    helms       = 'Helms',
    chest       = 'Chest',
    legs        = 'Legs',
    gloves      = 'Gloves',
    boots       = 'Boots',
    rings       = 'Rings',
    amulets     = 'Amulets',
    weapons_1h  = 'One-Hand Weapons',
    weapons_2h  = 'Two-Hand Weapons',
    gold        = 'Gold (currency cache)',
    chaos       = 'Chaos (wildcard gear)',
    other       = 'Other / Unknown',
}

-- ---------------------------------------------------------------------------
-- Slot extraction
-- ---------------------------------------------------------------------------

-- Internal-name pattern fallback: maps a stripped lowercase token to a
-- slot id.  Order is longest-match-first because some keywords are
-- substrings of others ('legguards' vs 'leg').
local SLOT_PATTERNS = {
    { 'legguards',   'legs' },
    { 'pants',       'legs' },
    { 'helmets',     'helms' },
    { 'helms',       'helms' },
    { 'helm',        'helms' },
    { 'chestplates', 'chest' },
    { 'chests',      'chest' },
    { 'chest',       'chest' },
    { 'torsos',      'chest' },
    { 'gauntlets',   'gloves' },
    { 'gloves',      'gloves' },
    { 'boots',       'boots' },
    { 'feet',        'boots' },
    { 'rings',       'rings' },
    { 'ring',        'rings' },
    { 'amulets',     'amulets' },
    { 'amulet',      'amulets' },
    { 'necks',       'amulets' },
    { 'neck',        'amulets' },
    { 'twohanded',   'weapons_2h' },
    { 'two-handed',  'weapons_2h' },
    { '2handed',     'weapons_2h' },
    { '2hweapons',   'weapons_2h' },     -- internal_name form: BountyMeta_Cache_2HWeapons
    { '2hweapon',    'weapons_2h' },
    { 'onehanded',   'weapons_1h' },
    { 'one-handed',  'weapons_1h' },
    { '1handed',     'weapons_1h' },
    { '1hweapons',   'weapons_1h' },
    { '1hweapon',    'weapons_1h' },
    { 'weapons',     'weapons_1h' },     -- generic weapons -> 1h bucket
    { 'weapon',      'weapons_1h' },
    { 'gold',        'gold' },
    { 'chaos',       'chaos' },
    { 'legs',        'legs' },           -- last so legguards/pants match first
}

-- Internal-name tokens that signal a legendary cache.  Live-validated:
--   'upgraded' on `BountyMeta_Cache_Gold_Upgraded` (sno 2102725)
--   'great'   matches 'Greater Collection of *' family
local LEGENDARY_NAME_TOKENS = {
    'legendary', 'ancestral', 'guaranteed', 'gilded',
    'great', 'sacred', 'unique', 'upgraded',
}

local function strip_for_slot_match(internal_name)
    local s = (internal_name or ''):lower()
    for _, p in ipairs({ 'bountymeta_cache_', 'bounty_cache_', 'cache_' }) do
        if s:sub(1, #p) == p then s = s:sub(#p + 1); break end
    end
    -- Strip trailing rarity tokens.
    for _, tok in ipairs(LEGENDARY_NAME_TOKENS) do
        local suffix = '_' .. tok
        if #s > #suffix and s:sub(-#suffix) == suffix then
            s = s:sub(1, -#suffix - 1); break
        end
        if #s > #tok and s:sub(-#tok) == tok then
            s = s:sub(1, -#tok - 1); break
        end
    end
    return s
end

local function slot_from_internal_name(internal_name)
    if not internal_name or internal_name == '' then return 'other' end
    local stripped = strip_for_slot_match(internal_name)
    if stripped == '' then return 'other' end
    for _, pair in ipairs(SLOT_PATTERNS) do
        if stripped == pair[1] or stripped:find(pair[1], 1, true) then
            return pair[2]
        end
    end
    return 'other'
end

-- Extract a normalized slot id from the live entry.  Tries the SNO
-- catalog first (authoritative), falls back to internal_name parsing,
-- and ultimately returns 'other' if neither path succeeds.
M.extract_slot = function (entry)
    if type(entry) ~= 'table' then return 'other' end
    if type(entry.sno) == 'number' and CACHE_CATALOG[entry.sno] then
        return CACHE_CATALOG[entry.sno].slot
    end
    return slot_from_internal_name(entry.internal_name)
end

-- Display name from catalog if known, else internal_name, else '?'.
-- Used for human-readable log lines in the dump and the FSM debug.
M.display_name = function (entry)
    if type(entry) ~= 'table' then return '?' end
    if type(entry.sno) == 'number' and CACHE_CATALOG[entry.sno] then
        return CACHE_CATALOG[entry.sno].name
    end
    if entry.internal_name and entry.internal_name ~= '' then
        return tostring(entry.internal_name)
    end
    return '?'
end

-- ---------------------------------------------------------------------------
-- Legendary detection
--
-- The LooteerV3 catalog has r=0 for every BountyMetaCache SNO, so rarity
-- isn't carried by the SNO itself.  If the live host distinguishes a
-- legendary cache from a regular one, the signal must come from a field
-- on the entry table that the API stub doesn't document.  We probe a
-- handful of likely names; if none hit, fall back to internal_name
-- pattern matching.
-- ---------------------------------------------------------------------------

-- Returns (bool legendary, string evidence).  `evidence` is a short
-- token explaining the decision -- handy in the dump so the user can
-- confirm the heuristic.
M.is_legendary = function (entry)
    if type(entry) ~= 'table' then return false, 'no-entry' end

    -- 1. SNO catalog -- authoritative, ships hard-coded legendary flag.
    if type(entry.sno) == 'number' and CACHE_CATALOG[entry.sno] then
        local meta = CACHE_CATALOG[entry.sno]
        if meta.legendary == true  then return true,  'catalog:legendary=true'  end
        if meta.legendary == false then return false, 'catalog:legendary=false' end
    end

    -- Boolean fields the host MIGHT expose.
    if entry.legendary == true            then return true, 'field:legendary' end
    if entry.is_legendary == true         then return true, 'field:is_legendary' end
    if entry.is_unique == true            then return true, 'field:is_unique' end
    if entry.guaranteed_legendary == true then return true, 'field:guaranteed_legendary' end
    if entry.is_ancestral == true         then return true, 'field:is_ancestral' end
    if entry.ancestral == true            then return true, 'field:ancestral' end

    -- String / numeric rarity fields.
    for _, key in ipairs({ 'rarity', 'quality', 'tier', 'class', 'rank', 'r' }) do
        local v = entry[key]
        if v ~= nil then
            local lv = tostring(v):lower()
            for _, tok in ipairs(LEGENDARY_NAME_TOKENS) do
                if lv:find(tok, 1, true) then
                    return true, 'field:' .. key .. '=' .. lv
                end
            end
            local nv = tonumber(v)
            if nv and nv >= 5 then
                return true, 'field:' .. key .. '=' .. nv
            end
        end
    end

    -- internal_name pattern fallback.
    local name = tostring(entry.internal_name or ''):lower()
    for _, tok in ipairs(LEGENDARY_NAME_TOKENS) do
        if name:find(tok, 1, true) then
            return true, 'name:' .. tok
        end
    end
    return false, 'none'
end

-- All entry fields outside the documented {sno, internal_name, valid}
-- triple.  Used by the dump to surface anything new the host exposes.
M.extra_fields = function (entry)
    if type(entry) ~= 'table' then return {} end
    local out = {}
    for k, v in pairs(entry) do
        if k ~= 'sno' and k ~= 'internal_name' and k ~= 'valid' then
            out[#out + 1] = tostring(k) .. '=' .. tostring(v)
        end
    end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------
-- Scoring + picking
-- ---------------------------------------------------------------------------

-- Score one entry using the user's settings.  Higher = better.
-- Returns 0 to mean "skip" (slot priority 0 OR entry.valid == false).
-- Returns (score, slot, legendary, evidence) for traceability.
M.score_entry = function (entry, settings)
    if type(entry) ~= 'table' then return 0, 'other', false, 'no-entry' end
    local slot = M.extract_slot(entry)
    local legendary, evidence = M.is_legendary(entry)

    if entry.valid == false then
        return 0, slot, legendary, evidence
    end

    local sp = (settings.slot_priorities and settings.slot_priorities[slot]) or 0
    if sp <= 0 then
        return 0, slot, legendary, evidence
    end

    local score = sp
    if legendary and settings.prefer_legendary then
        score = score + (settings.legendary_bonus_weight or 0)
    end
    return score, slot, legendary, evidence
end

-- Pick the highest-scoring entry's index from the enumerate() table.
-- Returns (best_index, best_score, breakdown_table).  `best_index` is
-- nil if nothing scored above 0 (caller should fall back to the fixed
-- reward_index slider in that case).
--
-- Ties resolve to the lowest index (stable + matches how D4 renders
-- duplicate cards left-to-right).
M.pick_best_index = function (entries, settings)
    if type(entries) ~= 'table' then return nil, 0, {} end
    local breakdown = {}
    local best_idx, best_score = nil, 0

    local keys = {}
    for k in pairs(entries) do keys[#keys + 1] = k end
    table.sort(keys, function (a, b)
        local na, nb = type(a) == 'number', type(b) == 'number'
        if na and nb then return a < b end
        if na ~= nb then return na end
        return tostring(a) < tostring(b)
    end)

    for _, k in ipairs(keys) do
        local e = entries[k]
        local score, slot, legendary, evidence = M.score_entry(e, settings)
        breakdown[#breakdown + 1] = {
            index         = k,
            slot          = slot,
            legendary     = legendary,
            score         = score,
            evidence      = evidence,
            display_name  = M.display_name(e),
            internal_name = (e and e.internal_name) or '?',
        }
        if score > best_score then
            best_idx, best_score = k, score
        end
    end
    return best_idx, best_score, breakdown
end

return M
