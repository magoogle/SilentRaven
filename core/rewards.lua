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
-- BountyMetaCache + Whisper Cache catalog
--
-- Two-tier loader:
--   1) Try `data.caches` -- the cloud-fetched Lua module dropped by
--      Updater.bat from https://looter.d4data.live/d4/silentraven/caches.lua.
--      Pipeline-generated from the master LooteerV3 catalog so it tracks
--      every season's new SNOs without code changes.
--   2) Fallback to the embedded mini-catalog below.  This means a fresh
--      install with no Updater run yet still has correct slot/legendary
--      classification for the most common caches the user will see.
--
-- The cloud schema is the same as the embedded one:
--   [sno] = { slot=string, legendary=bool, name=string,
--             item_type=string?, magic_type=int? }
-- Extra fields (item_type / magic_type) are ignored by the runtime but
-- handy for diagnostics.
--
-- Schema notes for legendary detection:
--   * BountyMetaCache armor/weapons/jewelry: magic_type stays 0 even at
--     Greater tier; only the name prefix distinguishes Greater/Ancestral.
--     Pipeline pre-computes the bool so we don't classify-by-name at run
--     time.
--   * Whisper Cache (Material/Gold/Chaos/etc.): magic_type IS reliable
--     (r>=3 == legendary). Pipeline uses both signals.
-- ---------------------------------------------------------------------------

-- Embedded fallback catalog -- only used when data.caches isn't present.
-- Hand-curated from live S09 dumps + LooteerV3 catalog snippets.
local EMBEDDED_CATALOG = {
    [1087411] = { name = 'Collection of Helms',                 slot = 'helms',      legendary = false },
    [1087549] = { name = 'Collection of Chestplates',           slot = 'chest',      legendary = false },
    [1087551] = { name = 'Collection of Leg Guards',            slot = 'legs',       legendary = false },
    [1087553] = { name = 'Collection of Boots',                 slot = 'boots',      legendary = false },
    [1087555] = { name = 'Collection of Gauntlets',             slot = 'gloves',     legendary = false },
    [1087557] = { name = 'Collection of Two-Handed Weapons',    slot = 'weapons_2h', legendary = false },
    [1087567] = { name = 'Collection of One-handed Weapons',    slot = 'weapons_1h', legendary = false },
    [1087570] = { name = 'Collection of Rings',                 slot = 'rings',      legendary = false },
    [1087572] = { name = 'Collection of Amulets',               slot = 'amulets',    legendary = false },

    [1092131] = { name = 'Greater Collection of Helms',              slot = 'helms',      legendary = true },
    [1092135] = { name = 'Greater Collection of One-handed Weapons', slot = 'weapons_1h', legendary = true },
    [1092140] = { name = 'Greater Collection of Two-Handed Weapons', slot = 'weapons_2h', legendary = true },
    [1092142] = { name = 'Greater Collection of Amulets',            slot = 'amulets',    legendary = true },
    [1092145] = { name = 'Greater Collection of Boots',              slot = 'boots',      legendary = true },
    [1092149] = { name = 'Greater Collection of Chestplates',        slot = 'chest',      legendary = true },
    [1092151] = { name = 'Greater Collection of Gauntlets',          slot = 'gloves',     legendary = true },
    [1092153] = { name = 'Greater Collection of Leg Guards',         slot = 'legs',       legendary = true },
    [1092155] = { name = 'Greater Collection of Rings',              slot = 'rings',      legendary = true },

    [598510]  = { name = 'Collection of Chaos',         slot = 'chaos', legendary = false },
    [1092147] = { name = 'Greater Collection of Chaos', slot = 'chaos', legendary = true },

    -- Whisper Cache Material* family.  Gold stays legendary (high-value
    -- currency the user almost always wants).  Other Material*
    -- entries are crafting-material caches NOT gear -- legendary=false
    -- so they don't outrank actual legendary GEAR caches via the
    -- legendary bonus.
    [2102725] = { name = 'Material Collection of Gold',           slot = 'gold',      legendary = true  },
    [2102987] = { name = 'Material Collection of Gem Fragments',  slot = 'materials', legendary = false },
    [2103070] = { name = 'Material Collection of Salvage',        slot = 'materials', legendary = false },
    [2167180] = { name = 'Material Collection of Keys',           slot = 'materials', legendary = false },
    [2622775] = { name = 'Material Collection of Primordial Dust', slot = 'materials', legendary = false },
}

-- Try to load the cloud-fetched catalog; fall back to embedded.  Wrapped
-- in pcall because require() throws when the file is missing on disk OR
-- malformed.  Both cases should leave us with the embedded catalog and
-- a warning logged.  CATALOG_SOURCE tracks which one we ended up with --
-- exposed via M.catalog_source for the GUI to show "synced from cloud"
-- vs "embedded fallback".
local CACHE_CATALOG    = EMBEDDED_CATALOG
local CATALOG_SOURCE   = 'embedded'
local CATALOG_LOAD_ERR = nil
do
    -- pcall require so a missing-file error doesn't kill module load.
    -- If the cloud module loaded but is empty (table with no keys) we
    -- also stay on embedded -- empty file would silently break picking.
    local ok, mod = pcall(require, 'data.caches')
    if ok and type(mod) == 'table' and next(mod) ~= nil then
        CACHE_CATALOG  = mod
        CATALOG_SOURCE = 'cloud'
    else
        CATALOG_LOAD_ERR = (not ok) and tostring(mod) or 'data.caches missing or empty'
    end
end

M.CACHE_CATALOG    = CACHE_CATALOG
M.CATALOG_SOURCE   = CATALOG_SOURCE
M.CATALOG_LOAD_ERR = CATALOG_LOAD_ERR

-- Allow the GUI/Reload-Catalog button to swap in a freshly-fetched
-- catalog without restarting the script.  package.loaded["data.caches"]
-- is cleared so the next require() reads the new file from disk.
M.reload_catalog = function ()
    package.loaded['data.caches'] = nil
    local ok, mod = pcall(require, 'data.caches')
    if ok and type(mod) == 'table' and next(mod) ~= nil then
        CACHE_CATALOG  = mod
        CATALOG_SOURCE = 'cloud'
        CATALOG_LOAD_ERR = nil
        M.CACHE_CATALOG  = CACHE_CATALOG
        M.CATALOG_SOURCE = 'cloud'
        M.CATALOG_LOAD_ERR = nil
        return true, 'cloud'
    end
    -- Reload failed; keep current catalog state untouched.
    M.CATALOG_LOAD_ERR = (not ok) and tostring(mod) or 'data.caches missing or empty'
    return false, M.CATALOG_LOAD_ERR
end

-- Resolve absolute path to the SilentRaven plugin directory.  Needed
-- because os.execute child processes (cmd.exe) don't reliably inherit
-- the plugin folder as their cwd on this host -- we have to pass an
-- absolute path to Updater.bat or it won't find data/.
--
-- Two strategies, tried in order:
--   1. debug.getinfo(1, "S").source -- always returns this file's own
--      path with a leading '@', regardless of package.path config.
--      Most reliable on QQT-style hosts where package.path may not
--      include every loaded plugin's root.
--   2. package.searchpath('core.rewards', package.path) -- fallback
--      for hosts that don't expose debug.getinfo properly.
--
-- Either way, chop off "core/rewards.lua" to get the plugin root.
local function _plugin_dir()
    local candidates = {}
    if debug and debug.getinfo then
        local info = debug.getinfo(1, 'S')
        if info and info.source and info.source:sub(1, 1) == '@' then
            candidates[#candidates + 1] = info.source:sub(2)
        end
    end
    if package.searchpath then
        local p = package.searchpath('core.rewards', package.path)
        if p then candidates[#candidates + 1] = p end
    end
    for _, p in ipairs(candidates) do
        -- p:find returns the START position of the match, which IS the
        -- position of the leading separator we want to keep -- so
        -- p:sub(1, cut) already includes it.  An earlier off-by-one
        -- (cut + 1) gave "...SilentRaven\c" instead of "...SilentRaven\".
        local cut = p:find('[\\/]core[\\/]rewards%.lua$')
        if cut then
            return p:sub(1, cut)
        end
    end
    return nil
end

-- Last-sync epoch from data/last_sync.lua (written by Updater.bat).
-- Returns nil if never synced.  Always reads from disk fresh -- never
-- caches in package.loaded so the GUI shows the live freshness.
M.last_sync_epoch = function ()
    package.loaded['data.last_sync'] = nil
    local ok, ret = pcall(require, 'data.last_sync')
    if ok and type(ret) == 'number' then return ret end
    return nil
end

-- Human-readable freshness string for the GUI header.
M.last_sync_str = function ()
    local t = M.last_sync_epoch()
    if not t then return 'never synced' end
    local age = (os.time and os.time() or 0) - t
    if age < 0     then return 'sync clock skewed' end
    if age < 60    then return string.format('%ds ago', age) end
    if age < 3600  then return string.format('%.0fm ago', age/60) end
    if age < 86400 then return string.format('%.1fh ago', age/3600) end
    return string.format('%.0fd ago', age/86400)
end

-- File-existence probe (no shelling out).
local function _file_exists(path)
    local fh = io.open(path, 'rb')
    if fh then fh:close(); return true end
    return false
end

-- One-shot: run Updater.bat to fetch caches.lua, then reload it.
-- Returns (ok, source_or_err).  Safe to call ONLY from a user-triggered
-- button click -- never per-frame.  Each cmd.exe spawn is ~50-100ms of
-- hard freeze on Windows; rapid clicks should be debounced upstream.
--
-- The error strings returned are human-readable AND machine-checkable
-- (main.lua's handle_reload_catalog dumps them verbatim on failure).
-- The diagnostic console.print calls used while debugging path
-- resolution are commented out below -- uncomment them if a future
-- failure mode needs the same kind of trace.
M.fetch_and_reload = function ()
    local plug = _plugin_dir()
    if not plug then
        local msg = 'could not resolve plugin dir (debug.getinfo + package.searchpath both failed)'
        -- if console and console.print then
        --     console.print('[SilentRaven] fetch_and_reload: ' .. msg)
        -- end
        return false, msg
    end

    local log_path = plug .. 'data/last_sync_log.txt'
    local bat_path = plug .. 'Updater.bat'

    -- Path-resolution trace -- uncomment when debugging plugin-dir issues.
    -- if console and console.print then
    --     console.print('[SilentRaven] fetch_and_reload: plug=' .. plug)
    --     console.print('[SilentRaven] fetch_and_reload: bat =' .. bat_path)
    -- end

    if not _file_exists(bat_path) then
        local msg = 'Updater.bat not found at ' .. bat_path
        -- if console and console.print then
        --     console.print('[SilentRaven] fetch_and_reload: ' .. msg)
        -- end
        return false, msg
    end

    -- Wipe prior log so its post-spawn existence proves the bat actually
    -- ran (vs being silently blocked by an os.execute sandbox).
    pcall(os.execute, string.format('del /q "%s" >NUL 2>&1', log_path))

    -- The cmd /c "" outer quotes are the canonical Windows trick for
    -- paths with spaces.  oneshot mode does a single sync then exits.
    pcall(os.execute, string.format('cmd /c ""%s" oneshot" >NUL 2>&1', bat_path))

    local log_size = 0
    do
        local fh = io.open(log_path, 'rb')
        if fh then
            fh:seek('end'); log_size = fh:seek() or 0; fh:close()
        end
    end
    if log_size == 0 then
        local msg = 'Updater.bat did not appear to run (no last_sync_log.txt at '
                 .. log_path .. ')'
        -- if console and console.print then
        --     console.print('[SilentRaven] fetch_and_reload: ' .. msg)
        -- end
        return false, msg
    end

    -- Reload the catalog from disk now that Updater.bat has written it.
    return M.reload_catalog()
end

-- Slot ids the user can configure priority for.  Keep in sync with the
-- per-slot sliders in gui.lua.  'other' catches anything we don't
-- recognize from SNO catalog or internal_name parsing -- defensive
-- against future-season caches we haven't catalogued yet.
local KNOWN_SLOTS = {
    'helms', 'chest', 'legs', 'gloves', 'boots',
    'rings', 'amulets',
    'weapons_1h', 'weapons_2h',
    'gold',  'chaos',  'materials',
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
    materials   = 'Materials (gem fragments / keys / etc.)',
    other       = 'Other / Unknown',
}

-- D4Remote.record_loot expects a singular category string per its
-- INTEGRATION.md: "helm", "chest", "ring", "sigil", "material", etc.
-- Map our slot ids onto that vocabulary.  Unknowns fall through to
-- "cache" so D4Remote still groups SilentRaven picks meaningfully.
M.SLOT_TO_D4REMOTE_CATEGORY = {
    helms       = 'helm',
    chest       = 'chest',
    legs        = 'legs',
    gloves      = 'gloves',
    boots       = 'boots',
    rings       = 'ring',
    amulets     = 'amulet',
    weapons_1h  = 'weapon',
    weapons_2h  = 'weapon',
    gold        = 'gold',
    chaos       = 'cache',
    materials   = 'material',
    other       = 'cache',
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
-- Returns (score, slot, legendary, evidence) for traceability.
--
-- A legendary entry always scores at least `legendary_bonus_weight`
-- (when prefer_legendary is on), even if the user set the slot
-- priority to 0 -- the user explicitly asked that legendary cards
-- never be skipped just because the slot wasn't on their priority
-- list.  Score 0 is reserved for "regular card the user marked as
-- skip"; pick_best_index has a fallback for the "all entries score 0"
-- corner case.
M.score_entry = function (entry, settings)
    if type(entry) ~= 'table' then return 0, 'other', false, 'no-entry' end
    local slot = M.extract_slot(entry)
    local legendary, evidence = M.is_legendary(entry)

    if entry.valid == false then
        return 0, slot, legendary, evidence
    end

    local sp = (settings.slot_priorities and settings.slot_priorities[slot]) or 0
    local score = sp
    if legendary and settings.prefer_legendary then
        score = score + (settings.legendary_bonus_weight or 0)
    end
    return score, slot, legendary, evidence
end

-- Pick the highest-scoring entry's index from the enumerate() table.
-- Returns (best_index, best_score, breakdown_table).
--
-- Fallback rule (per user request): if no entry scores above 0 -- i.e.
-- every slot is set to 0 priority AND nothing on offer is legendary --
-- pick the first valid entry rather than returning nil.  The user
-- explicitly asked SilentRaven never refuse to claim a turn-in just
-- because their slot priorities are all zeroed.  The breakdown row for
-- the chosen index gets `fallback=true` so the debug log makes it
-- obvious that's what happened.
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
            fallback      = false,
        }
        if score > best_score then
            best_idx, best_score = k, score
        end
    end

    -- Fallback: nothing scored.  Pick first valid entry.
    if best_score == 0 then
        for i, k in ipairs(keys) do
            local e = entries[k]
            if e and e.valid ~= false then
                if breakdown[i] then breakdown[i].fallback = true end
                return k, 0, breakdown
            end
        end
        -- All entries were valid==false (shouldn't happen but defensive).
        -- Pick the very first key as a last resort.
        if keys[1] then
            if breakdown[1] then breakdown[1].fallback = true end
            return keys[1], 0, breakdown
        end
    end

    return best_idx, best_score, breakdown
end

return M
